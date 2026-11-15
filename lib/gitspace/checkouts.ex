defmodule Gitspace.Checkouts do
  @moduledoc "Indexed checkouts: import, refresh, sync from mirrors, and query."

  import Ecto.Query

  alias Gitspace.{Config, Error, Git, Repo}
  alias Gitspace.Git.{Refs, Status, Worktree}
  alias Gitspace.Index.{Checkout, Repository}

  @spec import(Config.t(), Repository.t(), Path.t(), keyword()) ::
          {:ok, Checkout.t(), boolean()} | {:error, Error.t()}
  def import(%Config{} = _config, %Repository{} = repo, path, opts \\ []) do
    path = Path.expand(path)

    with {:ok, root, status} <- read_status(path) do
      attrs = %{
        repository_id: repo.id,
        path: root,
        kind: opts[:kind] || infer_kind(root),
        source: opts[:source] || "managed",
        state: "ok",
        branch: status.branch,
        head_sha: status.head,
        detached: status.detached,
        dirty: status.dirty,
        ahead: status.ahead || 0,
        behind: status.behind || 0,
        untracked: status.untracked,
        unpushed: Refs.unpushed(root, status),
        last_status_at: DateTime.utc_now(),
        last_seen_at: DateTime.utc_now(),
        created_by: opts[:created_by]
      }

      upsert(attrs)
    end
  end

  @spec refresh(Config.t(), Checkout.t()) :: {:ok, Checkout.t()} | {:error, Error.t()}
  def refresh(%Config{} = _config, %Checkout{} = checkout) do
    now = DateTime.utc_now()

    if File.dir?(checkout.path) do
      case read_status(checkout.path) do
        {:ok, root, status} ->
          attrs = %{
            path: root,
            state: "ok",
            branch: status.branch,
            head_sha: status.head,
            detached: status.detached,
            dirty: status.dirty,
            ahead: status.ahead || 0,
            behind: status.behind || 0,
            untracked: status.untracked,
            unpushed: Refs.unpushed(root, status),
            last_status_at: now,
            last_seen_at: now
          }

          checkout
          |> Ecto.Changeset.change(attrs)
          |> Repo.update()
          |> case do
            {:ok, checkout} -> {:ok, checkout}
            {:error, changeset} -> {:error, changeset_error(changeset)}
          end

        {:error, _error} ->
          {:ok, mark_missing(checkout, "broken")}
      end
    else
      {:ok, mark_missing(checkout, "missing")}
    end
  end

  @spec refresh_many(Config.t(), [Checkout.t()]) :: [Checkout.t()]
  def refresh_many(config, checkouts) do
    Enum.map(checkouts, fn checkout ->
      case refresh(config, checkout) do
        {:ok, checkout} -> checkout
        {:error, _} -> checkout
      end
    end)
  end

  @doc "Imports every worktree of a mirror and marks vanished managed checkouts missing."
  @spec sync_repo(Config.t(), Repository.t()) :: {:ok, map()} | {:error, Error.t()}
  def sync_repo(%Config{} = config, %Repository{} = repo) do
    case Worktree.list(repo.bare_path) do
      {:ok, worktrees} ->
        entries = Enum.reject(worktrees, & &1.bare)
        paths = MapSet.new(entries, &Path.expand(&1.path))

        {imported, missing_entries, issues} =
          Enum.reduce(entries, {0, 0, []}, fn entry, {count, missing, issues} ->
            if File.dir?(entry.path) do
              case import(config, repo, entry.path, kind: "worktree", source: "managed") do
                {:ok, _checkout, _created} -> {count + 1, missing, issues}
                {:error, error} -> {count, missing, [error | issues]}
              end
            else
              _ = upsert(missing_attrs(repo, entry))
              {count, missing + 1, issues}
            end
          end)

        missing =
          missing_entries +
            (from(c in Checkout,
               where: c.repository_id == ^repo.id,
               where: c.source == "managed",
               where: c.path not in ^MapSet.to_list(paths)
             )
             |> Repo.update_all(set: [state: "missing", last_status_at: nil])
             |> elem(0))

        {:ok,
         %{
           repository: repo.slug,
           worktrees: length(entries),
           imported: imported,
           missing: missing,
           issues: Enum.reverse(issues)
         }}

      {:error, result} ->
        {:error, Error.new(:error, "cannot list worktrees for #{repo.slug}: #{result.stderr}")}
    end
  end

  @spec list(Config.t(), keyword()) :: [Checkout.t()]
  def list(%Config{} = _config, filters \\ []) do
    query =
      from(c in Checkout,
        preload: [:repository],
        order_by: [asc: c.path]
      )

    query
    |> filter_repo(filters[:repo])
    |> filter_workspace_label(filters[:workspace], filters[:label])
    |> filter_state(filters[:state])
    |> filter_kind(filters[:kind])
    |> filter_source(filters[:source])
    |> Repo.all()
  end

  @spec get_by_path(Path.t()) :: {:ok, Checkout.t()} | {:error, Error.t()}
  def get_by_path(path) do
    path = Path.expand(path)

    case Repo.get_by(Checkout, path: path) do
      nil ->
        {:error,
         Error.new(:not_found, "checkout not indexed: #{path}",
           hint: "run `gitspace link #{path}`"
         )}

      checkout ->
        {:ok, checkout}
    end
  end

  @spec fresh?(Checkout.t(), pos_integer()) :: boolean()
  def fresh?(%Checkout{last_status_at: nil}, _max_age), do: false

  def fresh?(%Checkout{last_status_at: at}, max_age) do
    DateTime.diff(DateTime.utc_now(), at, :second) <= max_age
  end

  @spec risk(Checkout.t()) :: %{at_risk: boolean(), reasons: [String.t()], unknown: boolean()}
  def risk(%Checkout{} = checkout) do
    reasons =
      []
      |> add_reason(checkout.state == "missing", "directory missing")
      |> add_reason(checkout.state == "broken", "git metadata broken")
      |> add_reason((checkout.unpushed || 0) > 0, "#{checkout.unpushed || 0} unpushed")
      |> add_reason((checkout.dirty || 0) > 0, "#{checkout.dirty} dirty")
      |> add_reason((checkout.untracked || 0) > 0, "#{checkout.untracked} untracked")
      |> add_reason((checkout.behind || 0) > 0, "#{checkout.behind} behind")

    %{
      at_risk: reasons != [],
      reasons: Enum.reverse(reasons),
      unknown: is_nil(checkout.last_status_at)
    }
  end

  @doc "Indexes a checkout row even when its directory is gone (workspace recovery)."
  @spec ensure_missing(Repository.t(), Path.t(), map()) ::
          {:ok, Checkout.t()} | {:error, Error.t()}
  def ensure_missing(%Repository{} = repo, path, attrs \\ %{}) do
    path = Path.expand(path)

    attrs =
      Map.merge(
        %{
          repository_id: repo.id,
          path: path,
          kind: "worktree",
          source: "managed",
          state: "missing",
          last_seen_at: DateTime.utc_now()
        },
        attrs
      )

    case upsert(attrs) do
      {:ok, checkout, _created} -> {:ok, checkout}
      {:error, error} -> {:error, error}
    end
  end

  @spec mark_missing(Checkout.t(), String.t()) :: Checkout.t()
  def mark_missing(%Checkout{} = checkout, state) do
    checkout
    |> Ecto.Changeset.change(%{
      state: state,
      dirty: nil,
      ahead: nil,
      behind: nil,
      untracked: nil,
      unpushed: nil,
      last_status_at: nil,
      last_seen_at: DateTime.utc_now()
    })
    |> Repo.update!()
  end

  defp upsert(attrs) do
    case Repo.get_by(Checkout, path: attrs.path) do
      nil ->
        %Checkout{}
        |> Checkout.changeset(attrs)
        |> Repo.insert()
        |> case do
          {:ok, checkout} -> {:ok, checkout, true}
          {:error, changeset} -> {:error, changeset_error(changeset)}
        end

      existing ->
        existing
        |> Checkout.changeset(attrs)
        |> Repo.update()
        |> case do
          {:ok, checkout} -> {:ok, checkout, false}
          {:error, changeset} -> {:error, changeset_error(changeset)}
        end
    end
  end

  defp missing_attrs(repo, entry) do
    %{
      repository_id: repo.id,
      path: Path.expand(entry.path),
      kind: "worktree",
      source: "managed",
      state: "missing",
      branch: branch_name(entry.branch),
      head_sha: entry.head,
      detached: is_nil(entry.branch),
      last_seen_at: DateTime.utc_now()
    }
  end

  defp branch_name(nil), do: nil
  defp branch_name("refs/heads/" <> name), do: name
  defp branch_name(other), do: other

  defp read_status(path) do
    with {:ok, %{stdout: top}} <- Git.run(["rev-parse", "--show-toplevel"], cd: path),
         {:ok, status} <- Status.read(path) do
      {:ok, Path.expand(String.trim(top)), status}
    else
      _ ->
        {:error, Error.new(:not_found, "not a git checkout: #{path}")}
    end
  end

  defp infer_kind(path) do
    cond do
      File.regular?(Path.join(path, ".git")) -> "worktree"
      File.dir?(Path.join(path, ".git")) -> "clone"
      true -> "worktree"
    end
  end

  defp add_reason(reasons, true, reason), do: [reason | reasons]
  defp add_reason(reasons, false, _reason), do: reasons

  defp filter_repo(query, nil), do: query

  defp filter_repo(query, repo) do
    from(c in query,
      join: r in assoc(c, :repository),
      where: r.slug == ^repo
    )
  end

  defp filter_workspace_label(query, nil, nil), do: query

  defp filter_workspace_label(query, workspace, nil) do
    from(c in query,
      join: m in assoc(c, :workspace_members),
      join: w in assoc(m, :workspace),
      where: w.name == ^workspace and w.state == "active",
      distinct: true
    )
  end

  defp filter_workspace_label(query, nil, label) do
    from(c in query,
      join: m in assoc(c, :workspace_members),
      join: w in assoc(m, :workspace),
      join: l in assoc(w, :labels),
      where: l.label == ^label and w.state == "active",
      distinct: true
    )
  end

  defp filter_workspace_label(query, workspace, label) do
    from(c in query,
      join: m in assoc(c, :workspace_members),
      join: w in assoc(m, :workspace),
      join: l in assoc(w, :labels),
      where: w.name == ^workspace and w.state == "active" and l.label == ^label,
      distinct: true
    )
  end

  defp filter_state(query, nil), do: query
  defp filter_state(query, state), do: from(c in query, where: c.state == ^state)

  defp filter_kind(query, nil), do: query
  defp filter_kind(query, kind), do: from(c in query, where: c.kind == ^kind)

  defp filter_source(query, nil), do: query
  defp filter_source(query, source), do: from(c in query, where: c.source == ^source)

  defp changeset_error(changeset) do
    Error.new(:conflict, "cannot save checkout",
      details: %{errors: Ecto.Changeset.traverse_errors(changeset, fn {msg, _} -> msg end)}
    )
  end
end
