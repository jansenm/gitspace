defmodule Gitspace.Workspaces do
  @moduledoc """
  Workspace metadata and recovery from `.gitspace.json` markers.

  The index is a cache; the marker is the durable record. `reindex/1` walks the
  checkout root, reads every marker, validates members against git, and rebuilds
  the workspace rows. Drift is reported, never silently repaired.
  """

  import Ecto.Query

  alias Gitspace.{Checkouts, Config, Error, Marker, Projects, Repo}
  alias Gitspace.Index.{Checkout, Repository, Workspace, WorkspaceLabel, WorkspaceMember}

  @spec reindex(Config.t()) :: {:ok, map()}
  def reindex(%Config{} = config) do
    projects = Projects.list(config)

    {markers, bad, project_issues} =
      Enum.reduce(projects, {[], [], []}, fn project, {markers, bad, issues} ->
        cond do
          not File.dir?(project.path) ->
            {markers, bad,
             [
               %{
                 kind: :missing_project_path,
                 project: project.name,
                 path: project.path
               }
               | issues
             ]}

          true ->
            {:ok, found, invalid} = Marker.find_all(project.path)

            found =
              Enum.map(found, fn {dir, marker} ->
                {dir,
                 marker
                 |> Map.put_new("project", project.name)
                 |> Map.put_new("topic", Path.basename(dir))}
              end)

            {kept, legacy} = Enum.split_with(found, &canonical_workspace?/1)

            legacy_issues =
              Enum.map(legacy, fn {dir, marker} ->
                %{
                  kind: :legacy_workspace_name,
                  workspace: marker["workspace"],
                  path: dir,
                  hint: "recreate it as project@topic"
                }
              end)

            {markers ++ kept, bad ++ invalid, issues ++ legacy_issues}
        end
      end)

    issues =
      Enum.map(bad, fn {path, reason} ->
        %{kind: :invalid_marker, path: path, reason: inspect(reason)}
      end) ++ project_issues

    {workspaces, members, issues} =
      Enum.reduce(markers, {0, 0, issues}, fn {dir, marker}, {ws_count, member_count, issues} ->
        case recover_workspace(config, dir, marker) do
          {:ok, member_total, issues2} ->
            {ws_count + 1, member_count + member_total, issues ++ issues2}

          {:error, error} ->
            {ws_count, member_count,
             issues ++ [%{kind: :workspace, path: dir, reason: error.message}]}
        end
      end)

    {:ok,
     %{
       workspaces: workspaces,
       members: members,
       issues: issues,
       orphaned: orphaned_workspaces(markers)
     }}
  end

  @spec list(Config.t()) :: [Workspace.t()]
  def list(%Config{} = _config) do
    from(w in Workspace,
      where: w.state == "active",
      order_by: [asc: w.name],
      preload: [members: [checkout: :repository], labels: []]
    )
    |> Repo.all()
  end

  @spec get(Config.t(), String.t()) :: {:ok, Workspace.t()} | {:error, Error.t()}
  def get(%Config{} = _config, name) do
    name = String.trim(name)

    query =
      from(w in Workspace,
        where: w.name == ^name and w.state == "active",
        preload: [members: [checkout: :repository], labels: []]
      )

    case Repo.one(query) do
      %Workspace{} = workspace ->
        {:ok, workspace}

      nil ->
        # A bare topic is accepted when it is unique across projects.
        matches =
          from(w in Workspace,
            where: w.state == "active",
            preload: [members: [checkout: :repository], labels: []]
          )
          |> Repo.all()
          |> Enum.filter(&String.ends_with?(&1.name, "@" <> name))

        case matches do
          [workspace] ->
            {:ok, workspace}

          [] ->
            {:error, Error.new(:not_found, "workspace not found: #{name}")}

          many ->
            names = Enum.map(many, & &1.name)

            {:error,
             Error.new(:ambiguous, "workspace name is ambiguous: #{name}",
               hint: "use one of: #{Enum.join(names, ", ")}",
               details: %{matches: names}
             )}
        end
    end
  end

  @doc "Project and topic for a workspace whose name is `project@topic`."
  @spec parts(Workspace.t()) :: {String.t() | nil, String.t()}
  def parts(%Workspace{name: name}) do
    case String.split(name, "@", parts: 2) do
      [project, topic] -> {project, topic}
      [topic] -> {nil, topic}
    end
  end

  @doc "Rebuilds one workspace from a marker. Used after creation writes the marker."
  @spec recover(Config.t(), Path.t(), map()) ::
          {:ok, non_neg_integer(), [map()]} | {:error, Error.t()}
  def recover(%Config{} = config, dir, marker), do: recover_workspace(config, dir, marker)

  defp recover_workspace(config, dir, marker) do
    with {:ok, workspace} <- upsert_workspace(dir, marker),
         :ok <- clear_children(workspace),
         :ok <- insert_labels(workspace, marker["labels"] || []) do
      {members, issues} =
        Enum.reduce(marker["members"] || [], {0, []}, fn member, {count, issues} ->
          case recover_member_safely(config, workspace, dir, member) do
            {:ok, _member} -> {count + 1, issues}
            {:error, issue} -> {count, [issue | issues]}
          end
        end)

      {:ok, members, Enum.reverse(issues)}
    else
      {:error, error} -> {:error, error}
    end
  end

  # A single malformed member must never prevent the remaining members from
  # being indexed. Constraint and path errors are reported as issues, not
  # raised through the whole recovery.
  defp recover_member_safely(config, workspace, dir, member) do
    recover_member(config, workspace, dir, member)
  rescue
    error ->
      {:error,
       %{
         kind: :member,
         workspace: workspace.name,
         repo: member["repo"],
         reason: Exception.message(error)
       }}
  end

  defp upsert_workspace(dir, marker) do
    attrs = %{
      name: marker["workspace"],
      description: marker["description"],
      state: "active",
      marker_path: Path.join(dir, Marker.marker_filename())
    }

    case Repo.get_by(Workspace, name: attrs.name, state: "active") do
      nil ->
        %Workspace{}
        |> Workspace.changeset(attrs)
        |> Repo.insert()

      workspace ->
        workspace
        |> Workspace.changeset(attrs)
        |> Repo.update()
    end
    |> case do
      {:ok, workspace} ->
        {:ok, workspace}

      {:error, changeset} ->
        {:error,
         Error.new(:conflict, "cannot recover workspace #{attrs.name}",
           details: %{errors: Ecto.Changeset.traverse_errors(changeset, fn {msg, _} -> msg end)}
         )}
    end
  end

  defp clear_children(workspace) do
    Repo.delete_all(from(m in WorkspaceMember, where: m.workspace_id == ^workspace.id))
    Repo.delete_all(from(l in WorkspaceLabel, where: l.workspace_id == ^workspace.id))
    :ok
  end

  defp insert_labels(_workspace, []), do: :ok

  defp insert_labels(workspace, labels) do
    labels
    |> Enum.map(&to_string/1)
    |> Enum.uniq()
    |> Enum.each(fn label ->
      %WorkspaceLabel{}
      |> WorkspaceLabel.changeset(%{workspace_id: workspace.id, label: label})
      |> Repo.insert!()
    end)

    :ok
  end

  defp recover_member(config, workspace, dir, member) do
    repo_name = member["repo"]
    ownership = member["ownership"]

    with {:ok, repo} <- find_member_repo(member),
         {:ok, path} <- member_path(dir, member),
         {:ok, checkout} <- import_member(config, repo, path, ownership, member) do
      %WorkspaceMember{}
      |> WorkspaceMember.changeset(%{
        workspace_id: workspace.id,
        checkout_id: checkout.id,
        repository_id: repo.id,
        name: member["name"] || Path.basename(path) || repo.slug,
        ownership: ownership,
        role: member["role"]
      })
      |> Repo.insert()
      |> case do
        {:ok, member} -> {:ok, member}
        {:error, changeset} -> {:error, member_issue(workspace, path, changeset)}
      end
    else
      {:error, %Error{} = error} ->
        {:error,
         %{
           kind: :member,
           workspace: workspace.name,
           repo: repo_name,
           reason: error.message
         }}
    end
  end

  defp find_member_repo(member) do
    remote = member["remote"]

    if is_binary(remote) do
      case Repo.get_by(Repository, remote_key: remote) do
        nil -> find_repo(member["repo"])
        repo -> {:ok, repo}
      end
    else
      find_repo(member["repo"])
    end
  end

  defp import_member(config, repo, path, ownership, member) do
    source = if ownership == "owned", do: "managed", else: borrowed_source(path)
    kind = borrowed_kind(path)

    if File.dir?(path) do
      case Checkouts.import(config, repo, path, kind: kind, source: source) do
        {:ok, checkout, _created} -> {:ok, checkout}
        {:error, error} -> missing_member(repo, path, ownership, member, error)
      end
    else
      missing_member(repo, path, ownership, member, nil)
    end
  end

  defp missing_member(repo, path, ownership, member, _error) do
    Checkouts.ensure_missing(repo, path, %{
      kind: kind_for(ownership),
      source: if(ownership == "owned", do: "managed", else: "external"),
      branch: member["branch"] || member["ref"],
      detached: is_nil(member["branch"])
    })
  end

  defp member_path(dir, %{"ownership" => "owned", "rel_path" => rel}) do
    path = Path.expand(Path.join(dir, rel))

    if within?(path, dir) do
      {:ok, path}
    else
      {:error, Error.new(:refused, "owned member escapes its workspace directory: #{rel}")}
    end
  end

  defp member_path(_dir, %{"ownership" => "borrowed", "path" => path}) when is_binary(path) do
    if Path.type(path) == :absolute do
      {:ok, Path.expand(path)}
    else
      {:error, Error.new(:refused, "borrowed member path must be absolute: #{path}")}
    end
  end

  defp member_path(_dir, member) do
    {:error,
     Error.new(:refused, "invalid member #{inspect(member["repo"])}",
       hint: "owned members need rel_path; borrowed members need an absolute path"
     )}
  end

  defp find_repo(name) when is_binary(name) do
    candidates =
      [name, name |> String.split("/") |> List.last()]
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    repo =
      Enum.find_value(candidates, fn candidate ->
        Repo.get_by(Repository, slug: candidate) ||
          Repo.get_by(Repository, remote_key: candidate)
      end)

    repo =
      repo ||
        from(r in Repository,
          where: like(r.remote_url, ^"%/#{name}") or like(r.remote_url, ^"%:#{name}"),
          limit: 1
        )
        |> Repo.one()

    case repo do
      nil ->
        {:error,
         Error.new(:not_found, "repository not registered: #{name}",
           hint: "run `gitspace repo add <url>` before reindexing"
         )}

      repo ->
        {:ok, repo}
    end
  end

  defp find_repo(_), do: {:error, Error.new(:refused, "marker member has no repository name")}

  defp borrowed_source(path) do
    case Repo.get_by(Checkout, path: Path.expand(path)) do
      nil -> "external"
      checkout -> checkout.source
    end
  end

  defp borrowed_kind(path) do
    cond do
      File.regular?(Path.join(path, ".git")) -> "worktree"
      File.dir?(Path.join(path, ".git")) -> "clone"
      true -> "worktree"
    end
  end

  defp kind_for("owned"), do: "worktree"
  defp kind_for(_), do: "worktree"

  defp member_issue(workspace, path, changeset) do
    %{
      kind: :member,
      workspace: workspace.name,
      path: path,
      reason:
        inspect(Ecto.Changeset.traverse_errors(changeset, fn {msg, _} -> msg end),
          limit: :infinity
        )
    }
  end

  defp canonical_workspace?({_dir, marker}) do
    name = marker["workspace"]
    is_binary(name) and String.contains?(name, "@")
  end

  defp orphaned_workspaces(markers) do
    paths = MapSet.new(markers, fn {dir, _} -> Path.join(dir, Marker.marker_filename()) end)

    from(w in Workspace, where: w.state == "active", select: {w.name, w.marker_path})
    |> Repo.all()
    |> Enum.reject(fn {_name, path} -> path && MapSet.member?(paths, path) end)
    |> Enum.map(fn {name, path} -> %{workspace: name, marker_path: path} end)
  end

  defp within?(path, dir) do
    dir = Path.expand(dir)
    path == dir or String.starts_with?(path, dir <> "/")
  end
end
