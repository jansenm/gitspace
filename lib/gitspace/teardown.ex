defmodule Gitspace.Teardown do
  @moduledoc """
  Safe removal of workspace members and whole workspaces.

  Owned members are removed as git worktrees. Borrowed members are only
  unlinked. Risky owned members are refused unless `--force` is given; force
  anchors HEAD, saves the tracked diff and untracked files under `<data>/trash`,
  and only then removes the worktree. Branches are never deleted here.
  """

  import Ecto.Query

  alias Gitspace.{Config, Error, Marker, Repo, Safety, Workspaces}
  alias Gitspace.Git.Worktree
  alias Gitspace.Index.{Checkout, Workspace, WorkspaceMember}

  @type target :: map()
  @type plan :: %{
          workspace: Workspace.t(),
          workspace_dir: Path.t(),
          targets: [target()],
          risky: [target()],
          member: String.t() | nil
        }

  @spec plan(Config.t(), Workspace.t(), keyword()) :: {:ok, plan()} | {:error, Error.t()}
  def plan(%Config{} = config, %Workspace{} = workspace, opts \\ []) do
    with {:ok, members} <- select_members(workspace, opts[:member]),
         {:ok, workspace_dir} <- workspace_dir(workspace),
         {:ok, targets} <- plan_targets(config, workspace, workspace_dir, members) do
      {:ok,
       %{
         workspace: workspace,
         workspace_dir: workspace_dir,
         targets: targets,
         risky: Enum.filter(targets, &risky?/1),
         member: opts[:member]
       }}
    end
  end

  @spec execute(Config.t(), plan(), keyword()) ::
          {:ok, map()} | {:partial, map(), [map()]} | {:error, Error.t()}
  def execute(%Config{} = config, plan, opts \\ []) do
    force = !!opts[:force]
    dry_run = !!opts[:dry_run]

    if dry_run do
      planned =
        Enum.map(plan.targets, fn target ->
          target_result(
            target,
            if(target.ownership == "borrowed", do: "would unlink", else: "would remove"),
            nil
          )
        end)

      {:ok, result(plan, planned, [], true, false, false)}
    else
      with :ok <- refuse_risky(plan, force),
           {:ok, archives} <- archive_risky(config, plan, force) do
        {removed, failures} = remove_targets(config, plan, force, archives)
        finalize(config, plan, removed, failures)
      end
    end
  end

  @spec remove(Config.t(), Workspace.t(), keyword()) ::
          {:ok, map()} | {:partial, map(), [map()]} | {:error, Error.t()}
  def remove(%Config{} = config, %Workspace{} = workspace, opts \\ []) do
    with {:ok, plan} <- plan(config, workspace, opts) do
      execute(config, plan, opts)
    end
  end

  @spec risky?(target()) :: boolean()
  def risky?(target) do
    target.risk_error != nil or (target.risk != nil and target.risk.at_risk)
  end

  @spec risky_error(plan()) :: Error.t()
  def risky_error(plan) do
    members =
      Enum.map(plan.risky, fn target ->
        %{
          member: target.name,
          repo: target.repo.slug,
          path: target.path,
          reasons: risk_reasons(target)
        }
      end)

    names = Enum.map_join(members, ", ", & &1.member)

    Error.new(:refused, "workspace has risky members: #{names}",
      hint: "re-run with --force to archive their work under <data>/trash and remove them",
      details: %{members: members}
    )
  end

  defp select_members(workspace, nil), do: {:ok, workspace.members}

  defp select_members(workspace, member_name) do
    case Enum.find(workspace.members, &member_matches?(&1, member_name)) do
      nil ->
        handles =
          Enum.map_join(workspace.members, ", ", fn member ->
            "#{workspace.name}:#{member.name || member.checkout.repository.slug}"
          end)

        {:error,
         Error.new(:not_found, "member not found in #{workspace.name}: #{member_name}",
           hint: "members: #{handles}"
         )}

      member ->
        {:ok, [member]}
    end
  end

  defp member_matches?(member, name) do
    repo = member.checkout.repository

    member.name == name or repo.slug == name or
      (member.checkout.path && Path.basename(member.checkout.path) == name)
  end

  defp workspace_dir(workspace) do
    case workspace.marker_path do
      nil ->
        {:error,
         Error.new(:error, "workspace #{workspace.name} has no marker path",
           hint: "run `gitspace doctor --reindex`"
         )}

      marker ->
        {:ok, Path.dirname(marker)}
    end
  end

  defp plan_targets(_config, workspace, workspace_dir, members) do
    members
    |> Enum.reduce_while({:ok, []}, fn member, {:ok, acc} ->
      case plan_target(workspace, workspace_dir, member) do
        {:ok, target} -> {:cont, {:ok, [target | acc]}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
    |> case do
      {:ok, targets} -> {:ok, Enum.reverse(targets)}
      error -> error
    end
  end

  defp plan_target(workspace, workspace_dir, member) do
    checkout = member.checkout
    repo = checkout.repository
    path = Path.expand(checkout.path)

    base = %{
      member: member,
      name: member.name || repo.slug,
      repo: repo,
      checkout: checkout,
      ownership: member.ownership,
      path: path,
      branch: checkout.branch,
      head: checkout.head_sha,
      present?: File.exists?(path),
      risk: nil,
      risk_error: nil,
      action: if(member.ownership == "borrowed", do: :unlink, else: :remove),
      archive: nil
    }

    cond do
      member.ownership == "borrowed" ->
        {:ok, base}

      not within?(path, workspace_dir) ->
        {:error,
         Error.new(:refused, "owned member escapes its workspace: #{path}",
           hint: "run `gitspace doctor` before removing"
         )}

      other_workspaces(member.checkout.id, workspace.id) != [] ->
        names = other_workspaces(member.checkout.id, workspace.id)

        {:error,
         Error.new(:refused, "checkout is also used by: #{Enum.join(names, ", ")}",
           hint: "remove the other workspace memberships first"
         )}

      true ->
        case File.lstat(path) do
          {:ok, %File.Stat{type: :directory}} ->
            case Safety.detect(path) do
              {:ok, risk} -> {:ok, %{base | risk: risk}}
              {:error, reason} -> {:ok, %{base | risk_error: reason}}
            end

          {:ok, %File.Stat{type: :symlink}} ->
            {:ok, %{base | risk_error: :symlink}}

          {:ok, _stat} ->
            {:ok, %{base | risk_error: :not_a_directory}}

          {:error, :enoent} ->
            {:ok, %{base | present?: false}}

          {:error, reason} ->
            {:ok, %{base | risk_error: reason}}
        end
    end
  end

  defp other_workspaces(checkout_id, workspace_id) do
    from(m in WorkspaceMember,
      join: w in assoc(m, :workspace),
      where: m.checkout_id == ^checkout_id,
      where: m.workspace_id != ^workspace_id,
      where: w.state == "active",
      select: w.name
    )
    |> Repo.all()
  end

  defp refuse_risky(_plan, true), do: :ok
  defp refuse_risky(%{risky: []}, _force), do: :ok
  defp refuse_risky(plan, false), do: {:error, risky_error(plan)}

  defp archive_risky(_config, %{risky: []}, _force), do: {:ok, %{}}
  defp archive_risky(_config, _plan, false), do: {:ok, %{}}

  defp archive_risky(config, plan, true) do
    Enum.reduce_while(plan.risky, {:ok, %{}}, fn target, {:ok, acc} ->
      case archive_target(config, plan.workspace, target) do
        {:ok, path} -> {:cont, {:ok, Map.put(acc, target.member.id, path)}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp archive_target(config, workspace, target) do
    cond do
      target.risk_error != nil ->
        {:error,
         Error.new(
           :refused,
           "cannot inspect #{target.path}: #{format_reason(target.risk_error)}",
           hint: "remove this member manually after checking its contents"
         )}

      is_nil(target.risk) or not target.risk.at_risk ->
        {:ok, nil}

      is_nil(target.repo.bare_path) or not File.dir?(target.repo.bare_path) ->
        {:error,
         Error.new(:refused, "mirror for #{target.repo.slug} is missing",
           hint: "cannot anchor the checkout safely"
         )}

      true ->
        trash = trash_dir(config, workspace, target)

        try do
          File.mkdir_p!(trash)

          {:ok, keep_ref, sha} =
            Safety.keep!(target.repo.bare_path, target.path, "#{workspace.name}-#{target.name}")

          write_patch!(target.path, trash)
          write_untracked!(target.path, trash)

          File.write!(
            Path.join(trash, "info.json"),
            Jason.encode!(
              %{
                workspace: workspace.name,
                member: target.name,
                repo: target.repo.slug,
                path: target.path,
                branch: target.branch,
                head: sha,
                keep_ref: keep_ref,
                archived_at: DateTime.utc_now() |> DateTime.to_iso8601()
              },
              pretty: true
            ) <> "\n"
          )

          {:ok, trash}
        rescue
          error ->
            {:error,
             Error.new(:error, "cannot archive #{target.path}: #{Exception.message(error)}",
               hint: "nothing was removed"
             )}
        end
    end
  end

  defp trash_dir(config, workspace, target) do
    stamp =
      DateTime.utc_now()
      |> DateTime.to_iso8601()
      |> String.replace([":", "."], "-")

    Path.join([
      config.data_dir,
      "trash",
      sanitize(workspace.name),
      sanitize(target.name),
      stamp
    ])
  end

  defp write_patch!(worktree, trash) do
    case Gitspace.Git.run(["diff", "--binary", "HEAD"], cd: worktree) do
      {:ok, %{stdout: ""}} -> :ok
      {:ok, %{stdout: patch}} -> File.write!(Path.join(trash, "tracked.patch"), patch)
      {:error, result} -> raise "git diff failed: #{result.stderr}"
    end
  end

  defp write_untracked!(worktree, trash) do
    case Safety.untracked(worktree) do
      {:ok, []} ->
        :ok

      {:ok, paths} ->
        _ = Safety.archive_untracked!(worktree, Path.join(trash, "untracked.tar.gz"), paths)
        :ok

      {:error, result} ->
        raise "git status failed: #{inspect(result)}"
    end
  end

  defp remove_targets(config, plan, force, archives) do
    Enum.reduce(plan.targets, {[], []}, fn target, {removed, failures} ->
      case remove_target(
             config,
             plan.workspace,
             target,
             force,
             Map.get(archives, target.member.id)
           ) do
        {:ok, result} -> {[result | removed], failures}
        {:error, error} -> {removed, [failure(target, error) | failures]}
      end
    end)
    |> then(fn {removed, failures} -> {Enum.reverse(removed), Enum.reverse(failures)} end)
  end

  defp remove_target(_config, _workspace, %{ownership: "borrowed"} = target, _force, _archive) do
    with :ok <- delete_membership(target.member) do
      {:ok, target_result(target, "unlinked", nil)}
    end
  end

  defp remove_target(_config, _workspace, target, force, archive) do
    result =
      if target.present? and File.dir?(target.path) do
        case Worktree.remove(target.repo.bare_path, target.path, force: force or risky?(target)) do
          {:ok, _} -> :ok
          {:error, git_result} -> {:error, worktree_error(target, git_result)}
        end
      else
        :ok
      end

    with :ok <- result,
         :ok <- delete_membership(target.member),
         :ok <- delete_checkout(target) do
      {:ok, target_result(target, "removed", archive)}
    end
  end

  defp delete_membership(member) do
    Repo.delete_all(from(m in WorkspaceMember, where: m.id == ^member.id))
    :ok
  end

  defp delete_checkout(%{ownership: "owned", checkout: checkout}) do
    remaining =
      Repo.aggregate(from(m in WorkspaceMember, where: m.checkout_id == ^checkout.id), :count)

    if remaining == 0 do
      Repo.delete_all(from(c in Checkout, where: c.id == ^checkout.id))
    end

    :ok
  end

  defp delete_checkout(_target), do: :ok

  defp finalize(config, plan, removed, failures) do
    workspace = plan.workspace

    remaining =
      from(m in WorkspaceMember,
        where: m.workspace_id == ^workspace.id,
        preload: [checkout: :repository]
      )
      |> Repo.all()

    result =
      if remaining == [] do
        tombstone_workspace(workspace, plan.workspace_dir, removed, failures)
      else
        rewrite_workspace(config, workspace, plan.workspace_dir, remaining, removed, failures)
      end

    case result do
      {:ok, result} when failures == [] ->
        {:ok, result}

      {:ok, result} ->
        {:partial, result, failures}

      {:error, error} when removed == [] ->
        {:error, error}

      {:error, error} ->
        {:partial, result(plan, removed, failures, false, false, false),
         failures ++ [failure(%{repo: workspace.name, ownership: "workspace"}, error)]}
    end
  end

  defp tombstone_workspace(workspace, dir, removed, failures) do
    _ = File.rm(Path.join(dir, Marker.marker_filename()))

    workspace
    |> Ecto.Changeset.change(%{state: "torn_down", torn_down_at: DateTime.utc_now()})
    |> Repo.update()
    |> case do
      {:ok, workspace} ->
        directory_removed = empty_dir_removed?(dir)

        {:ok,
         result(
           empty_plan(workspace, dir),
           removed,
           failures,
           false,
           true,
           directory_removed
         )}

      {:error, changeset} ->
        {:error,
         Error.new(:conflict, "cannot mark workspace torn down",
           details: %{errors: Ecto.Changeset.traverse_errors(changeset, fn {msg, _} -> msg end)}
         )}
    end
  end

  defp rewrite_workspace(config, workspace, dir, remaining, removed, failures) do
    marker = marker(workspace, dir, remaining)

    try do
      Marker.write!(dir, marker)

      case Workspaces.recover(config, dir, marker) do
        {:ok, _members, []} ->
          {:ok,
           result(
             empty_plan(workspace, dir),
             removed,
             failures,
             false,
             false,
             false
           )}

        {:ok, _members, issues} ->
          {:error,
           Error.new(:partial, "workspace marker written but indexing was incomplete",
             details: %{issues: issues}
           )}

        {:error, error} ->
          {:error, error}
      end
    rescue
      error ->
        {:error,
         Error.new(:error, "cannot rewrite workspace marker: #{Exception.message(error)}",
           hint: "the removed checkouts are gone; run `gitspace doctor --reindex`"
         )}
    end
  end

  defp marker(workspace, dir, remaining) do
    {project, topic} = Workspaces.parts(workspace)

    Marker.build(workspace.name,
      project: project,
      topic: topic,
      description: workspace.description,
      labels: Enum.map(workspace.labels, & &1.label),
      created_at:
        (workspace.inserted_at && DateTime.to_iso8601(workspace.inserted_at)) ||
          DateTime.utc_now() |> DateTime.to_iso8601(),
      members: Enum.map(remaining, &marker_member(&1, dir))
    )
  end

  defp marker_member(member, dir) do
    checkout = member.checkout
    repo = checkout.repository

    base = %{
      "repo" => repo.slug,
      "remote" => repo.remote_key,
      "name" => member.name || repo.slug,
      "ownership" => member.ownership,
      "branch" => checkout.branch,
      "ref" => checkout.branch || checkout.head_sha,
      "head" => checkout.head_sha
    }

    case member.ownership do
      "owned" ->
        Map.put(base, "rel_path", Path.relative_to(checkout.path, dir))

      _ ->
        Map.put(base, "path", checkout.path)
    end
  end

  defp empty_plan(workspace, dir) do
    %{workspace: workspace, workspace_dir: dir, targets: [], risky: [], member: nil}
  end

  @spec result(plan(), list(), list(), boolean(), boolean(), boolean()) :: map()
  defp result(plan, removed, failures, dry_run, tombstoned, directory_removed) do
    workspace = plan.workspace
    {project, topic} = Workspaces.parts(workspace)
    dir = plan.workspace_dir

    %{
      project: project,
      topic: topic,
      workspace: workspace.name,
      path: dir,
      marker_path: Path.join(dir, Marker.marker_filename()),
      member: plan.member,
      dry_run: dry_run,
      tombstoned: tombstoned,
      directory_removed: directory_removed,
      directory_kept: tombstoned and not directory_removed and File.dir?(dir),
      removed: Enum.map(removed, &public_target/1),
      risky: Enum.map(plan.risky, &public_risky/1),
      failures: Enum.map(failures, &Map.drop(&1, [:error]))
    }
  end

  defp target_result(target, action, archive) do
    %{
      name: target.name,
      repo: target.repo.slug,
      ownership: target.ownership,
      path: target.path,
      branch: target.branch,
      action: action,
      risk: risk_reasons(target),
      archive: archive
    }
  end

  defp public_target(target), do: target

  defp public_risky(target) do
    %{
      member: target.name,
      repo: target.repo.slug,
      path: target.path,
      reasons: risk_reasons(target)
    }
  end

  defp risk_reasons(%{risk_error: reason}) when not is_nil(reason),
    do: ["cannot inspect: #{format_reason(reason)}"]

  defp risk_reasons(%{risk: nil}), do: []

  defp risk_reasons(%{risk: risk}) do
    []
    |> add_reason(risk.unpushed > 0, "#{risk.unpushed} unpushed")
    |> add_reason(risk.dirty > 0, "#{risk.dirty} dirty")
    |> add_reason(risk.untracked > 0, "#{risk.untracked} untracked")
    |> Enum.reverse()
  end

  defp add_reason(reasons, true, reason), do: [reason | reasons]
  defp add_reason(reasons, false, _reason), do: reasons

  defp failure(target, error) do
    %{
      member: target[:name] || target[:repo],
      repo: target[:repo],
      code: error.code,
      reason: error.message,
      hint: error.hint,
      error: error
    }
  end

  defp worktree_error(target, result) do
    Error.new(:error, "cannot remove #{target.path}: #{String.trim(result.stderr)}",
      hint: "inspect the directory; it was not removed"
    )
  end

  @spec empty_dir_removed?(Path.t()) :: boolean()
  defp empty_dir_removed?(dir) do
    case File.ls(dir) do
      {:ok, []} ->
        case File.rmdir(dir) do
          :ok -> true
          {:error, _} -> false
        end

      _ ->
        false
    end
  end

  defp within?(path, dir) do
    dir = Path.expand(dir)
    path == dir or String.starts_with?(path, dir <> "/")
  end

  defp sanitize(value) do
    value
    |> String.replace(~r/[^A-Za-z0-9._-]+/, "-")
    |> String.trim("-")
  end

  defp format_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp format_reason(reason) when is_binary(reason), do: reason
  defp format_reason(reason), do: inspect(reason)
end
