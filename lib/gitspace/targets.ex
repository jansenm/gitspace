defmodule Gitspace.Targets do
  @moduledoc """
  Resolves user-facing targets to index rows.

  Order: `workspace:member`, exact workspace, exact project,
  `project/topic[/member]` against the index, existing path (relative to the
  working directory or to a project root), repository alias, unique substring.
  Ambiguity is an error, never a guess.

  Paths and `project/topic[/member]` are checked before repository aliases so
  that a layout-shaped target addresses one checkout instead of being read as
  a repository selector.
  """

  alias Gitspace.{Checkouts, Config, Error, Marker, Projects, Repos, Workspaces}
  alias Gitspace.Index.{Checkout, Repository, Workspace}

  @type resolved ::
          {:workspace, Workspace.t()}
          | {:checkout, Checkout.t()}
          | {:member, Workspace.t(), map()}
          | {:repo, Repository.t()}
          | {:project, Projects.t()}

  @spec resolve(Config.t(), String.t()) :: {:ok, resolved()} | {:error, Error.t()}
  def resolve(%Config{} = config, target) do
    target = String.trim(target)

    cond do
      target == "" ->
        {:error, Error.new(:usage, "target is required")}

      String.starts_with?(target, "project:") ->
        target
        |> String.replace_prefix("project:", "")
        |> then(&Projects.get(config, &1))
        |> case do
          {:ok, project} -> {:ok, {:project, project}}
          {:error, error} -> {:error, error}
        end

      String.starts_with?(target, "repo:") ->
        target
        |> String.replace_prefix("repo:", "")
        |> then(&Repos.get(config, &1))
        |> case do
          {:ok, repo} -> {:ok, {:repo, repo}}
          {:error, error} -> {:error, error}
        end

      String.contains?(target, ":") ->
        resolve_member(config, target)

      true ->
        resolve_named(config, target)
    end
  end

  @spec path_for(Config.t(), String.t()) :: {:ok, map()} | {:error, Error.t()}
  def path_for(%Config{} = config, target) do
    with {:ok, resolved} <- resolve(config, target) do
      case resolved do
        {:checkout, checkout} ->
          {:ok, %{path: checkout.path, kind: :checkout, target: target}}

        {:member, workspace, member} ->
          {:ok,
           %{
             path: member.checkout.path,
             kind: :member,
             target: target,
             handle: handle(workspace, member)
           }}

        {:workspace, workspace} ->
          root =
            case workspace.marker_path do
              nil -> nil
              marker -> Path.dirname(marker)
            end

          if root do
            {:ok, %{path: root, kind: :workspace, target: target}}
          else
            {:error,
             Error.new(:error, "workspace #{workspace.name} has no recorded path",
               hint: "run `gitspace doctor --reindex`"
             )}
          end

        {:project, project} ->
          {:ok, %{path: project.path, kind: :project, target: target}}

        {:repo, repo} ->
          checkouts = Checkouts.list(config, repo: repo.slug)

          case checkouts do
            [checkout] ->
              {:ok, %{path: checkout.path, kind: :repo, target: target}}

            [] ->
              {:error, Error.new(:not_found, "no indexed checkouts for #{repo.slug}")}

            many ->
              {:error,
               Error.new(:ambiguous, "#{repo.slug} has #{length(many)} checkouts",
                 hint: "use one of:\n" <> Enum.map_join(many, "\n", &("  " <> &1.path))
               )}
          end
      end
    end
  end

  defp resolve_member(config, target) do
    case String.split(target, ":", parts: 2) do
      [workspace_name, member_name] ->
        with {:ok, workspace} <- Workspaces.get(config, workspace_name) do
          case find_member(workspace, member_name) do
            nil ->
              handles = Enum.map(workspace.members, &handle(workspace, &1))

              {:error,
               Error.new(:not_found, "member not found: #{target}",
                 hint: "available: #{Enum.join(handles, ", ")}"
               )}

            member ->
              {:ok, {:member, workspace, member}}
          end
        end

      _ ->
        {:error, Error.new(:usage, "invalid target: #{target}")}
    end
  end

  defp resolve_named(config, target) do
    with :error <- exact_workspace(config, target),
         :error <- exact_project(config, target),
         :none <- resolve_slash_target(config, target),
         :none <- resolve_existing_path(config, target) do
      resolve_repo_or_suffix(config, target)
    end
  end

  defp exact_workspace(config, target) do
    case Workspaces.get(config, target) do
      {:ok, workspace} -> {:ok, {:workspace, workspace}}
      {:error, _} -> :error
    end
  end

  defp exact_project(config, target) do
    case Projects.get(config, target) do
      {:ok, project} -> {:ok, {:project, project}}
      {:error, _} -> :error
    end
  end

  # `project/topic[/member]` addresses the index, not just the filesystem:
  # topic directories are slugged (`feature/x` lives in `feature-x`) and a
  # project root may be outside `projects_root`, so a literal path is not
  # always enough. Without this, such a target fell through to the repository
  # alias fallback and listed every checkout of the repository.
  defp resolve_slash_target(config, target) do
    case project_for_target(config, target) do
      {:ok, project, rest} -> resolve_slash_candidates(config, project, rest)
      :error -> :none
    end
  end

  defp project_for_target(config, target) do
    case String.split(target, "/") do
      [project_name | rest] when rest != [] ->
        case Projects.get(config, project_name) do
          {:ok, project} -> {:ok, project, rest}
          {:error, _} -> :error
        end

      _ ->
        :error
    end
  end

  defp resolve_slash_candidates(config, project, segments) do
    case slash_workspace(config, project, Enum.join(segments, "/")) do
      {:ok, workspace} ->
        {:ok, {:workspace, workspace}}

      :none when length(segments) > 1 ->
        {topic_segments, [member_name]} = Enum.split(segments, -1)

        case slash_workspace(config, project, Enum.join(topic_segments, "/")) do
          {:ok, workspace} -> find_slash_member(workspace, member_name)
          :none -> :none
        end

      :none ->
        :none
    end
  end

  defp slash_workspace(config, project, topic) do
    ["#{project.name}@#{topic}", "#{project.name}/#{topic}"]
    |> Enum.find_value(:none, fn name ->
      case Workspaces.get(config, name) do
        {:ok, workspace} -> {:ok, workspace}
        {:error, _} -> nil
      end
    end)
  end

  defp find_slash_member(workspace, member_name) do
    case find_member(workspace, member_name) do
      nil ->
        handles = Enum.map(workspace.members, &handle(workspace, &1))

        {:error,
         Error.new(:not_found, "member not found: #{workspace.name}/#{member_name}",
           hint: "available: #{Enum.join(handles, ", ")}"
         )}

      member ->
        {:ok, {:member, workspace, member}}
    end
  end

  defp resolve_repo_or_suffix(config, target) do
    case project_for_target(config, target) do
      {:ok, %{name: project_name}, _rest} ->
        # `project/...` is layout-shaped. Never let its last segment fall back
        # to a repository selector: that is what turned a mistyped member path
        # into a listing of the whole repository.
        {:error,
         Error.new(:not_found, "no workspace or member at #{target}",
           hint: "run `gitspace ls --project #{project_name}` or use repo:<repository>"
         )}

      :error ->
        case Repos.get(config, target) do
          {:ok, repo} -> {:ok, {:repo, repo}}
          {:error, _} -> resolve_suffix(config, target)
        end
    end
  end

  # An existing directory named by the target wins over an alias match: a
  # `project/topic/member` argument addresses that one checkout. Relative
  # targets are tried against the working directory and against the project
  # roots, so the layout works from any directory.
  defp resolve_existing_path(config, target) do
    config
    |> candidate_paths(target)
    |> Enum.find_value(:none, fn path ->
      case resolve_path(config, path) do
        {:ok, _} = resolved -> resolved
        :none -> nil
      end
    end)
  end

  defp candidate_paths(config, target) do
    expanded = Path.expand(target)

    project_paths =
      case String.split(target, "/", parts: 2) do
        [project_name, rest] when rest != "" ->
          case Projects.get(config, project_name) do
            {:ok, project} -> [Path.expand(Path.join(project.path, rest))]
            {:error, _} -> []
          end

        _ ->
          []
      end

    roots =
      if Path.type(target) == :absolute do
        []
      else
        [Path.expand(Path.join(config.projects_root, target))]
      end

    Enum.uniq([expanded | roots ++ project_paths])
  end

  defp resolve_path(config, path) do
    if File.exists?(path) do
      case checkouts_at_path(config, path) do
        {:ok, checkout} ->
          {:ok, {:checkout, checkout}}

        :none ->
          case resolve_workspace_dir(config, path) do
            {:ok, _} = resolved -> resolved
            nil -> :none
          end
      end
    else
      :none
    end
  end

  defp checkouts_at_path(_config, path) do
    case Checkouts.get_by_path(path) do
      {:ok, checkout} ->
        {:ok, checkout}

      {:error, _} ->
        # A path inside a checkout resolves to its root.
        case Gitspace.Git.run(["rev-parse", "--show-toplevel"], cd: path) do
          {:ok, %{stdout: top}} ->
            case Checkouts.get_by_path(Path.expand(String.trim(top))) do
              {:ok, checkout} -> {:ok, checkout}
              {:error, _} -> :none
            end

          {:error, _} ->
            :none
        end
    end
  end

  defp resolve_workspace_dir(config, path) do
    case Marker.read(path) do
      {:ok, marker} ->
        case Workspaces.get(config, marker["workspace"]) do
          {:ok, workspace} -> {:ok, {:workspace, workspace}}
          {:error, _} -> nil
        end

      {:error, _} ->
        nil
    end
  end

  defp resolve_suffix(config, target) do
    candidates =
      workspace_candidates(config) ++
        project_candidates(config) ++ repo_candidates(config) ++ checkout_candidates(config)

    matches =
      Enum.filter(candidates, fn candidate -> String.contains?(candidate.label, target) end)

    case Enum.uniq_by(matches, & &1.key) do
      [match] ->
        {:ok, match.value}

      [] ->
        {:error,
         Error.new(:not_found, "unknown target: #{target}",
           hint: "run `gitspace ls` to see indexed checkouts"
         )}

      many ->
        labels = many |> Enum.map(& &1.label) |> Enum.uniq() |> Enum.sort()

        {:error,
         Error.new(:ambiguous, "ambiguous target: #{target}",
           hint: "matches: #{Enum.join(labels, ", ")}",
           details: %{matches: labels}
         )}
    end
  end

  defp workspace_candidates(config) do
    Enum.map(Workspaces.list(config), fn workspace ->
      %{label: workspace.name, key: {:workspace, workspace.id}, value: {:workspace, workspace}}
    end)
  end

  defp project_candidates(config) do
    Enum.map(Projects.list(config), fn project ->
      %{label: project.name, key: {:project, project.name}, value: {:project, project}}
    end)
  end

  defp repo_candidates(config) do
    Enum.map(Repos.list(config), fn %{repo: repo} ->
      %{label: repo.slug, key: {:repo, repo.id}, value: {:repo, repo}}
    end)
  end

  defp checkout_candidates(config) do
    Enum.flat_map(Checkouts.list(config), fn checkout ->
      labels = [checkout.path, Path.basename(checkout.path)] |> Enum.uniq()

      Enum.map(labels, fn label ->
        %{label: label, key: {:checkout, checkout.id}, value: {:checkout, checkout}}
      end)
    end)
  end

  defp find_member(workspace, member_name) do
    Enum.find(workspace.members, fn member ->
      repo_slug = member.checkout.repository && member.checkout.repository.slug

      member.name == member_name or
        repo_slug == member_name or
        Path.basename(member.checkout.path) == member_name
    end)
  end

  defp handle(workspace, member) do
    repo = member.checkout.repository
    name = member.name || (repo && repo.slug) || Path.basename(member.checkout.path)

    "#{workspace.name}:#{name}"
  end
end
