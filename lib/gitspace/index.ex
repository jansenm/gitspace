defmodule Gitspace.Index do
  @moduledoc """
  Owns the SQLite index lifecycle.

  The CLI starts the repo on demand; there is no daemon. Migrations run on every
  start (a no-op when current). The index is disposable: `doctor --reindex`
  rebuilds it from git and the workspace markers.
  """

  alias Gitspace.{Checkouts, Config, Projects, Repo, Repos, Workspaces}
  alias Gitspace.Index.{Checkout, Repository}

  @spec ensure_started(Config.t(), keyword()) :: :ok
  def ensure_started(%Config{} = config, opts \\ []) do
    db_path = Config.db_path(config)
    File.mkdir_p!(Path.dirname(db_path))

    start_repo(db_path, opts)
    configure_connection()
    migrate()
    :ok
  end

  @spec started?() :: boolean()
  def started?, do: is_pid(Process.whereis(Repo))

  @spec stop() :: :ok
  def stop do
    if started?() do
      try do
        Repo.stop()
      catch
        :exit, _ -> :ok
      end
    end

    :ok
  end

  @spec migrate() :: :ok
  def migrate do
    unless migrated?() do
      Ecto.Migrator.run(Repo, migrations_path(), :up, all: true, log: false)
    end

    :ok
  end

  @doc "Rebuilds the cache from git and the workspace markers."
  @spec reindex(Config.t()) :: {:ok, map()}
  def reindex(%Config{} = config) do
    ensure_started(config)
    discovered = Repos.discover(config)

    repo_results =
      Repo.all(Repository)
      |> Enum.map(fn repo ->
        cond do
          is_nil(repo.bare_path) ->
            {:external, repo.slug}

          not File.dir?(repo.bare_path) ->
            {:missing_mirror, repo.slug}

          true ->
            case Repos.sync(config, repo) do
              {:ok, summary} -> {:ok, summary}
              {:error, error} -> {:error, repo.slug, error}
            end
        end
      end)

    {:ok, workspace_result} = Workspaces.reindex(config)
    missing = mark_missing_checkouts()

    imported =
      repo_results
      |> Enum.flat_map(fn
        {:ok, summary} -> [summary]
        _ -> []
      end)
      |> Enum.map(& &1.imported)
      |> Enum.sum()

    issues =
      discovered.issues ++
        Enum.flat_map(repo_results, fn
          {:error, slug, error} -> [%{kind: :repository, repo: slug, reason: error.message}]
          {:missing_mirror, slug} -> [%{kind: :missing_mirror, repo: slug}]
          _ -> []
        end)

    {:ok,
     %{
       projects: length(Projects.list(config)),
       repositories: length(repo_results),
       discovered_repositories: discovered.discovered,
       imported_checkouts: imported,
       missing_checkouts: missing,
       workspaces: workspace_result.workspaces,
       workspace_members: workspace_result.members,
       issues: issues ++ workspace_result.issues,
       orphaned_workspaces: workspace_result.orphaned
     }}
  end

  @spec migrations_path() :: Path.t()
  def migrations_path do
    Application.app_dir(:gitspace, "priv/repo/migrations")
  end

  defp start_repo(db_path, opts) do
    case Process.whereis(Repo) do
      nil ->
        {:ok, _pid} =
          Repo.start_link(
            database: db_path,
            pool_size: Keyword.get(opts, :pool_size, 1),
            log: false,
            stacktrace: false
          )

        :ok

      _pid ->
        :ok
    end
  end

  defp migrated? do
    applied =
      Ecto.Adapters.SQL.query!(Repo, "SELECT version FROM schema_migrations", [])
      |> Map.fetch!(:rows)
      |> List.flatten()
      |> Enum.map(&to_string/1)
      |> MapSet.new()

    expected =
      migrations_path()
      |> Path.join("*.exs")
      |> Path.wildcard()
      |> Enum.map(fn file ->
        file
        |> Path.basename()
        |> String.split("_")
        |> hd()
      end)
      |> MapSet.new()

    MapSet.subset?(expected, applied)
  rescue
    _ -> false
  end

  defp configure_connection do
    Ecto.Adapters.SQL.query!(Repo, "PRAGMA journal_mode=WAL", [])
    Ecto.Adapters.SQL.query!(Repo, "PRAGMA foreign_keys=ON", [])
    Ecto.Adapters.SQL.query!(Repo, "PRAGMA busy_timeout=5000", [])
    :ok
  end

  defp mark_missing_checkouts do
    Repo.all(Checkout)
    |> Enum.reduce(0, fn checkout, count ->
      if File.dir?(checkout.path) or checkout.state == "missing" do
        count
      else
        _ = Checkouts.mark_missing(checkout, "missing")
        count + 1
      end
    end)
  end
end
