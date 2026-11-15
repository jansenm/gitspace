defmodule Gitspace.Repos do
  @moduledoc "Registered repositories and their bare mirrors."

  import Ecto.Query

  alias Gitspace.{Config, Error, Git, Layout, Repo}
  alias Gitspace.Git.Mirror
  alias Gitspace.Index.Checkout
  alias Gitspace.Index.Repository

  @type result :: {:ok, Repository.t()} | {:error, Error.t()}

  @spec add(Config.t(), String.t(), keyword()) :: {:ok, Repository.t()} | {:error, Error.t()}
  def add(%Config{} = config, url, opts \\ []) do
    url = String.trim(url)

    with :ok <- validate_url(url),
         {:ok, slug} <- choose_slug(url, opts),
         {:ok, repo, upgrade?} <- prepare(config, url, slug, opts) do
      create_or_upgrade(config, repo, url, slug, upgrade?, opts)
    end
  end

  @spec list(Config.t()) :: [map()]
  def list(%Config{} = _config) do
    counts =
      from(c in Checkout,
        group_by: c.repository_id,
        select: {c.repository_id, count(c.id)}
      )
      |> Repo.all()
      |> Map.new()

    from(r in Repository, order_by: [asc: r.slug])
    |> Repo.all()
    |> Enum.map(fn repo ->
      %{repo: repo, checkouts: Map.get(counts, repo.id, 0)}
    end)
  end

  @spec get(Config.t(), String.t()) :: {:ok, Repository.t()} | {:error, Error.t()}
  def get(_config, selector) do
    repo =
      Repo.get_by(Repository, slug: selector) ||
        case Ecto.UUID.cast(selector) do
          {:ok, _} -> Repo.get(Repository, selector)
          :error -> nil
        end

    case repo do
      nil -> {:error, Error.new(:not_found, "repository not found: #{selector}")}
      repo -> {:ok, repo}
    end
  end

  @spec get!(Config.t(), String.t()) :: Repository.t()
  def get!(config, selector) do
    case get(config, selector) do
      {:ok, repo} -> repo
      {:error, error} -> raise error
    end
  end

  @spec find_by_remote(String.t()) :: Repository.t() | nil
  def find_by_remote(url) do
    Repo.get_by(Repository, remote_key: Layout.normalize_remote(url))
  end

  @doc """
  Registers bare mirrors found under the data directory.

  This is what makes a reindex survive deletion of the index: mirrors are
  discoverable from the filesystem, workspaces from markers.
  """
  @spec discover(Config.t()) :: %{discovered: non_neg_integer(), issues: [map()]}
  def discover(%Config{} = config) do
    dir = Config.repos_dir(config)

    results =
      case File.ls(dir) do
        {:ok, entries} ->
          entries
          |> Enum.filter(&String.ends_with?(&1, ".git"))
          |> Enum.map(&Path.join(dir, &1))
          |> Enum.filter(&bare_repo?/1)
          |> Enum.map(&discover_one/1)

        {:error, _} ->
          []
      end

    %{
      discovered: Enum.count(results, &match?({:ok, _}, &1)),
      issues: for({:error, issue} <- results, do: issue)
    }
  end

  @spec fetch(Config.t(), Repository.t()) :: {:ok, Repository.t()} | {:error, Error.t()}
  def fetch(%Config{} = _config, %Repository{} = repo) do
    cond do
      is_nil(repo.bare_path) ->
        {:error,
         Error.new(:refused, "#{repo.slug} has no mirror",
           hint: "it is an external repository; register the remote with `gitspace repo add`"
         )}

      not File.dir?(repo.bare_path) ->
        {:error,
         Error.new(:not_found, "mirror for #{repo.slug} is missing at #{repo.bare_path}",
           hint: "run `gitspace repo add <url> --name #{repo.slug}` again"
         )}

      true ->
        do_fetch(repo)
    end
  end

  @spec fetch_selector(Config.t(), String.t() | :all) ::
          {:ok, [Repository.t()]} | {:error, Error.t()}
  def fetch_selector(config, :all) do
    repos = Repo.all(Repository)

    results =
      Enum.map(repos, fn repo ->
        case fetch(config, repo) do
          {:ok, repo} -> {:ok, repo}
          {:error, error} -> {:error, repo.slug, error}
        end
      end)

    ok = for {:ok, repo} <- results, do: repo
    errors = for {:error, slug, error} <- results, do: {slug, error}

    if errors == [] do
      {:ok, ok}
    else
      {:partial, ok, errors}
    end
  end

  def fetch_selector(config, selector) do
    with {:ok, repo} <- get(config, selector),
         {:ok, repo} <- fetch(config, repo) do
      {:ok, [repo]}
    end
  end

  @spec remove(Config.t(), String.t(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def remove(%Config{} = config, selector, opts \\ []) do
    with {:ok, repo} <- get(config, selector) do
      cond do
        repo.state == "external" ->
          {:error,
           Error.new(:refused, "#{repo.slug} is an external repository",
             hint: "use `gitspace unlink <path>` for its checkouts"
           )}

        true ->
          count = Repo.aggregate(from(c in Checkout, where: c.repository_id == ^repo.id), :count)

          cond do
            count > 0 and !opts[:force] ->
              {:error,
               Error.new(
                 :refused,
                 "#{repo.slug} is used by #{count} checkout(s)",
                 hint:
                   "re-run with --force to remove the mirror and unindex those checkouts; directories are not deleted",
                 details: %{checkouts: count}
               )}

            true ->
              bare = repo.bare_path
              {:ok, _} = Repo.delete(repo)
              if bare && File.dir?(bare), do: File.rm_rf!(bare)

              {:ok,
               %{
                 repository: repo.slug,
                 removed_checkouts: count,
                 mirror_removed: bare,
                 checkouts_kept: count
               }}
          end
      end
    end
  end

  @doc "Imports the mirror's worktrees into the index and marks vanished ones missing."
  @spec sync(Config.t(), Repository.t()) :: {:ok, map()} | {:error, Error.t()}
  def sync(%Config{} = config, %Repository{} = repo) do
    if is_nil(repo.bare_path) or not File.dir?(repo.bare_path) do
      {:error, Error.new(:not_found, "mirror for #{repo.slug} is unavailable")}
    else
      Gitspace.Checkouts.sync_repo(config, repo)
    end
  end

  defp prepare(config, url, slug, _opts) do
    bare = Path.join(Config.repos_dir(config), slug <> ".git")
    key = Layout.normalize_remote(url)

    case find_existing(slug, key, bare) do
      nil ->
        {:ok, %Repository{slug: slug, remote_url: url, remote_key: key, bare_path: bare}, false}

      %Repository{state: "external", bare_path: nil} = existing
      when existing.remote_key == key ->
        {:ok, %{existing | remote_url: url, bare_path: bare}, true}

      existing ->
        suggestions = suggested_names(url, existing.slug)

        {:error,
         Error.new(:conflict, "repository name '#{existing.slug}' is already in use",
           hint: suggestion_hint(suggestions),
           details: %{
             slug: existing.slug,
             existing_remote: existing.remote_url,
             new_remote: url,
             suggested_names: suggestions
           }
         )}
    end
  end

  @doc false
  def suggested_names(url, existing_slug \\ nil) do
    key = Layout.normalize_remote(url)
    segments = String.split(key, "/", trim: true)

    candidates =
      if String.starts_with?(key, "/") do
        local_name_candidates(segments)
      else
        remote_name_candidates(segments)
      end

    candidates
    |> Enum.map(&slugify_parts/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.reject(&(&1 == existing_slug))
    |> Enum.uniq()
    |> Enum.take(3)
  end

  defp remote_name_candidates([host | rest]) do
    repo = List.last(rest) || host
    owner = rest |> Enum.drop(-1) |> Enum.join("-")

    if owner == "" do
      [[repo], [host, repo]]
    else
      [[owner, repo], [host, owner, repo]]
    end
  end

  defp remote_name_candidates([]), do: []

  defp local_name_candidates(segments) do
    repo = List.last(segments)
    parent = Enum.at(segments, -2)
    grandparent = Enum.at(segments, -3)

    [
      [parent, repo],
      [grandparent, parent, repo]
    ]
  end

  defp slugify_parts(parts) do
    parts = Enum.reject(parts, &(&1 in [nil, ""]))

    case Layout.work_slug(Enum.join(parts, "-")) do
      {:ok, slug} -> slug
      {:error, _} -> nil
    end
  end

  defp suggestion_hint([]), do: "choose another name with --name"

  defp suggestion_hint([one]) do
    "choose a unique name, e.g. `--name #{one}`"
  end

  defp suggestion_hint([first, second | _]) do
    "choose a unique name, e.g. `--name #{first}` or `--name #{second}`"
  end

  defp create_or_upgrade(config, repo, url, _slug, upgrade?, opts) do
    bare = repo.bare_path

    cond do
      File.exists?(bare) ->
        {:error,
         Error.new(:conflict, "path already exists: #{bare}",
           hint: "remove it or choose another name with --name"
         )}

      true ->
        File.mkdir_p!(Path.dirname(bare))

        with {:ok, _} <- safe_mirror(bare, url, no_fetch: true),
             {:ok, saved} <- save_repo(repo, upgrade?) do
          if opts[:no_fetch] do
            {:ok, saved}
          else
            case fetch(config, saved) do
              {:ok, fetched} ->
                {:ok, fetched}

              {:error, %Error{} = error} ->
                {:error,
                 %{
                   error
                   | details: Map.merge(error.details, %{repo: saved.slug, registered: true})
                 }}
            end
          end
        else
          {:error, %Error{} = error} ->
            _ = File.rm_rf(bare)
            {:error, error}
        end
    end
  end

  defp save_repo(repo, true) do
    repo
    |> Ecto.Changeset.change(%{
      state: "managed",
      bare_path: repo.bare_path,
      remote_url: repo.remote_url
    })
    |> Repo.update()
    |> case do
      {:ok, repo} -> {:ok, repo}
      {:error, changeset} -> {:error, changeset_error(changeset)}
    end
  end

  defp save_repo(repo, false) do
    %Repository{}
    |> Repository.changeset(%{
      slug: repo.slug,
      remote_url: repo.remote_url,
      remote_key: repo.remote_key,
      bare_path: repo.bare_path,
      state: "managed"
    })
    |> Repo.insert()
    |> case do
      {:ok, repo} -> {:ok, repo}
      {:error, changeset} -> {:error, changeset_error(changeset)}
    end
  end

  defp do_fetch(repo) do
    Mirror.fetch!(repo.bare_path, timeout: 300_000)

    default_branch = Mirror.default_branch(repo.bare_path) || repo.default_branch

    updated =
      repo
      |> Ecto.Changeset.change(%{
        last_fetched_at: DateTime.utc_now(),
        last_fetch_error: nil,
        default_branch: default_branch
      })
      |> Repo.update!()

    invalidate_statuses(repo.id)
    {:ok, updated}
  rescue
    error in Git.Error ->
      message = Exception.message(error)

      repo
      |> Ecto.Changeset.change(%{last_fetch_error: message})
      |> Repo.update!()

      {:error,
       Error.new(:error, "fetch failed for #{repo.slug}: #{message}",
         hint: "check the remote and credentials; the mirror is unchanged"
       )}
  end

  defp invalidate_statuses(repository_id) do
    from(c in Checkout, where: c.repository_id == ^repository_id)
    |> Repo.update_all(set: [last_status_at: nil])
  end

  defp safe_mirror(bare, url, opts) do
    {:ok, Mirror.init!(bare, url, opts)}
  rescue
    error in Git.Error ->
      {:error,
       Error.new(:error, "cannot create mirror: #{Exception.message(error)}",
         hint: "check the URL and that the remote is reachable"
       )}
  end

  defp choose_slug(url, opts) do
    cond do
      name = opts[:name] ->
        case Layout.repo_slug(name) do
          {:ok, slug} ->
            {:ok, slug}

          {:error, reason} ->
            {:error, Error.new(:usage, "invalid repository name #{inspect(name)}: #{reason}")}
        end

      true ->
        case Layout.repo_slug_from_url(url) do
          {:ok, slug} ->
            {:ok, slug}

          {:error, _} ->
            {:error,
             Error.new(:usage, "cannot derive a repository name from #{url}", hint: "use --name")}
        end
    end
  end

  defp find_existing(slug, key, bare) do
    Repo.get_by(Repository, remote_key: key) ||
      Repo.get_by(Repository, slug: slug) ||
      Repo.get_by(Repository, bare_path: bare)
  end

  defp discover_one(bare) do
    slug = bare |> Path.basename() |> String.replace_suffix(".git", "")

    remote =
      case Git.run(["remote", "get-url", "origin"], cd: bare) do
        {:ok, %{stdout: out}} -> out |> String.trim() |> nil_if_empty()
        {:error, _} -> nil
      end

    remote_url = remote || bare
    key = Layout.normalize_remote(remote_url)
    default_branch = Mirror.default_branch(bare)

    existing =
      Repo.get_by(Repository, bare_path: bare) ||
        Repo.get_by(Repository, slug: slug) ||
        Repo.get_by(Repository, remote_key: key)

    cond do
      existing ->
        existing
        |> Ecto.Changeset.change(%{
          bare_path: bare,
          state: "managed",
          remote_url: remote_url,
          remote_key: key,
          default_branch: existing.default_branch || default_branch
        })
        |> Repo.update()
        |> case do
          {:ok, repo} -> {:ok, repo}
          {:error, changeset} -> {:error, changeset_error(changeset)}
        end

      true ->
        %Repository{}
        |> Repository.changeset(%{
          slug: slug,
          remote_url: remote_url,
          remote_key: key,
          bare_path: bare,
          state: "managed",
          default_branch: default_branch
        })
        |> Repo.insert()
        |> case do
          {:ok, repo} -> {:ok, repo}
          {:error, changeset} -> {:error, changeset_error(changeset)}
        end
    end
  end

  defp bare_repo?(path) do
    File.dir?(Path.join(path, "objects")) and
      File.regular?(Path.join(path, "HEAD")) and
      File.dir?(Path.join(path, "refs"))
  end

  defp nil_if_empty(""), do: nil
  defp nil_if_empty(value), do: value

  defp validate_url(""), do: {:error, Error.new(:usage, "repository URL is required")}
  defp validate_url(_), do: :ok

  defp changeset_error(changeset) do
    Error.new(:conflict, "cannot save repository",
      details: %{errors: Ecto.Changeset.traverse_errors(changeset, fn {msg, _} -> msg end)}
    )
  end
end
