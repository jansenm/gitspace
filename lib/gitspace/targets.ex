defmodule Gitspace.Targets do
  @moduledoc """
  Resolves user-facing targets to index rows.

  Order: `workspace:member`, exact workspace, exact repository, path, unique
  substring. Ambiguity is an error, never a guess.
  """

  alias Gitspace.{Checkouts, Config, Error, Marker, Repos, Workspaces}
  alias Gitspace.Index.{Checkout, Repository, Workspace}

  @type resolved ::
          {:workspace, Workspace.t()}
          | {:checkout, Checkout.t()}
          | {:member, Workspace.t(), map()}
          | {:repo, Repository.t()}

  @spec resolve(Config.t(), String.t()) :: {:ok, resolved()} | {:error, Error.t()}
  def resolve(%Config{} = config, target) do
    target = String.trim(target)

    cond do
      target == "" ->
        {:error, Error.new(:usage, "target is required")}

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
          case workspace.members do
            [member] ->
              {:ok,
               %{
                 path: member.checkout.path,
                 kind: :workspace,
                 target: target,
                 handle: handle(workspace, member)
               }}

            members ->
              handles = Enum.map(members, &handle(workspace, &1))

              {:error,
               Error.new(:ambiguous, "#{workspace.name} has #{length(members)} members",
                 hint: "use one of: #{Enum.join(handles, ", ")}",
                 details: %{members: handles}
               )}
          end

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
    case Workspaces.get(config, target) do
      {:ok, workspace} ->
        {:ok, {:workspace, workspace}}

      {:error, _} ->
        case Repos.get(config, target) do
          {:ok, repo} -> {:ok, {:repo, repo}}
          {:error, _} -> resolve_path_or_suffix(config, target)
        end
    end
  end

  defp resolve_path_or_suffix(config, target) do
    path = Path.expand(target)

    cond do
      File.exists?(path) ->
        case checkouts_at_path(config, path) do
          {:ok, checkout} -> {:ok, {:checkout, checkout}}
          :none -> resolve_workspace_dir(config, path) || resolve_suffix(config, target)
        end

      true ->
        resolve_suffix(config, target)
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
      workspace_candidates(config) ++ repo_candidates(config) ++ checkout_candidates(config)

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
      repo_slug == member_name or Path.basename(member.checkout.path) == member_name
    end)
  end

  defp handle(workspace, member) do
    repo = member.checkout.repository

    "#{workspace.name}:#{if(repo, do: repo.slug, else: Path.basename(member.checkout.path))}"
  end
end
