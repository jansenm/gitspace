defmodule Gitspace.CLI.Workspace do
  @moduledoc false

  alias Gitspace.{Create, Error, Teardown, Workspaces}
  alias Gitspace.CLI.{Helpers, Inventory, Output, Prompt}

  def run(global, args) do
    case args do
      ["new" | rest] -> new(global, rest)
      ["ls" | rest] -> list(global, rest)
      ["status" | rest] -> status(global, rest)
      ["edit" | rest] -> edit(global, rest)
      ["rm" | rest] -> remove(global, rest)
      [] -> {:ok, %{help: help()}, &render_help/1}
      ["help"] -> {:ok, %{help: help()}, &render_help/1}
      [other | _] -> {:error, Error.new(:usage, "unknown workspace command: #{other}")}
    end
  end

  defp new(global, args) do
    with {:ok, opts, rest} <- Helpers.parse(args, new_strict()),
         {:ok, name} <-
           one_arg(rest, "gitspace workspace new [<project>@]<topic> [--own repo]..."),
         {:ok, owned} <- specs(Keyword.get_values(opts, :own), "owned", opts),
         {:ok, borrowed} <- specs(Keyword.get_values(opts, :borrow), "borrowed", opts),
         {:ok, owned, borrowed} <-
           apply_member_aliases(owned, borrowed, Keyword.get_values(opts, :as)),
         {:ok, config} <- Helpers.load_config(),
         :ok <- Helpers.start_index(config) do
      create_opts =
        [
          branch: opts[:branch],
          as_is: opts[:as_is],
          labels: Keyword.get_values(opts, :label),
          fetch: opts[:fetch],
          dry_run: opts[:dry_run],
          created_by: "workspace new",
          on_occupied: occupied_handler(global, opts)
        ] ++ description_opt(opts)

      case Create.workspace_new(config, name, owned, borrowed, create_opts) do
        {:ok, result} ->
          {:ok, result, &render/1}

        {:partial, result, failures} ->
          {:partial, result, &render/1, partial_error(result, failures)}

        {:error, error} ->
          {:error, error}
      end
    end
  end

  defp new_strict do
    [
      own: :keep,
      borrow: :keep,
      as: :keep,
      branch: :string,
      as_is: :boolean,
      label: :keep,
      description: :string,
      fetch: :boolean,
      dry_run: :boolean
    ] ++ Helpers.global_strict()
  end

  defp description_opt(opts) do
    if Keyword.has_key?(opts, :description) do
      [description: opts[:description]]
    else
      []
    end
  end

  defp specs(values, ownership, opts) do
    Enum.reduce_while(values, {:ok, []}, fn value, {:ok, acc} ->
      case split_spec(value) do
        {:ok, repo, ref} ->
          branch_mode = spec_branch_mode(ref, ownership, opts)
          spec = %{repo: repo, ref: ref, ownership: ownership, branch_mode: branch_mode}
          {:cont, {:ok, acc ++ [spec]}}

        {:error, error} ->
          {:halt, {:error, error}}
      end
    end)
  end

  defp spec_branch_mode(ref, "borrowed", _opts), do: if(is_nil(ref), do: :derive, else: :ref)

  defp spec_branch_mode(ref, "owned", opts) do
    if opts[:as_is] do
      if is_nil(ref), do: :default, else: :ref
    else
      :derive
    end
  end

  defp apply_member_aliases(owned, borrowed, values) do
    with {:ok, aliases} <- member_aliases(values),
         {:ok, owned, aliases} <- assign_member_aliases(owned, aliases),
         {:ok, borrowed, aliases} <- assign_member_aliases(borrowed, aliases),
         :ok <- no_unused_aliases(aliases) do
      {:ok, owned, borrowed}
    end
  end

  defp member_aliases(values) do
    Enum.reduce_while(values, {:ok, %{}}, fn value, {:ok, acc} ->
      case String.split(value, "=", parts: 2) do
        [selector, name] when selector != "" and name != "" ->
          if Map.has_key?(acc, selector) do
            {:halt, {:error, Error.new(:usage, "duplicate --as for #{selector}")}}
          else
            {:cont, {:ok, Map.put(acc, selector, name)}}
          end

        _ ->
          {:halt,
           {:error, Error.new(:usage, "invalid --as #{inspect(value)}", hint: "use repo=name")}}
      end
    end)
  end

  defp assign_member_aliases(specs, aliases) do
    Enum.reduce_while(specs, {:ok, [], aliases}, fn spec, {:ok, acc, aliases} ->
      {name, aliases} = Map.pop(aliases, spec.repo)

      spec =
        if is_nil(name) do
          spec
        else
          Map.put(spec, :member_name, name)
        end

      {:cont, {:ok, acc ++ [spec], aliases}}
    end)
  end

  defp no_unused_aliases(aliases) do
    if map_size(aliases) == 0 do
      :ok
    else
      {:error,
       Error.new(:usage, "no such member for --as: #{Enum.join(Map.keys(aliases), ", ")}")}
    end
  end

  defp split_spec(value) do
    case String.split(value, "@", parts: 2) do
      [repo] when repo != "" ->
        {:ok, repo, nil}

      [repo, ref] when repo != "" and ref != "" ->
        {:ok, repo, ref}

      _ ->
        {:error,
         Error.new(:usage, "invalid member #{inspect(value)}", hint: "use repo or repo@ref")}
    end
  end

  defp occupied_handler(global, opts) do
    if not global.json and !opts[:dry_run] and Output.tty?() do
      &Prompt.occupied/1
    end
  end

  defp partial_error(result, failures) do
    total = length(result.members) + length(failures)
    failed = length(failures)
    names = failures |> Enum.map(& &1.repo) |> Enum.uniq() |> Enum.join(", ")

    message =
      cond do
        result.dry_run ->
          "#{result.workspace} could not be planned completely: #{failed} of #{total} member(s) failed: #{names}"

        result.created ->
          "workspace #{result.workspace} created partially: #{failed} of #{total} member(s) failed: #{names}"

        true ->
          "workspace #{result.workspace} update was partial: #{failed} of #{total} member(s) failed: #{names}"
      end

    Error.new(:partial, message,
      hint: "fix the reported members and re-run; existing members are untouched",
      details: Map.put(result, :failures, Enum.map(failures, &Map.drop(&1, [:error])))
    )
  end

  defp list(_global, args) do
    with {:ok, opts, rest} <- Helpers.parse(args, ls_strict()),
         :ok <- Helpers.no_extra_args(rest),
         {:ok, config} <- Helpers.load_config(),
         :ok <- Helpers.start_index(config) do
      workspaces =
        config
        |> Workspaces.list()
        |> filter_label(opts[:label])
        |> filter_project(opts[:project])
        |> Enum.map(&workspace_map/1)

      {:ok, %{workspaces: workspaces}, &render_list/1}
    end
  end

  defp ls_strict do
    [label: :string, project: :string, active: :boolean, torn_down: :boolean, all: :boolean] ++
      Helpers.global_strict()
  end

  defp filter_label(workspaces, nil), do: workspaces

  defp filter_label(workspaces, label) do
    Enum.filter(workspaces, fn workspace ->
      Enum.any?(workspace.labels, &(&1.label == label))
    end)
  end

  defp filter_project(workspaces, nil), do: workspaces

  defp filter_project(workspaces, project) do
    Enum.filter(workspaces, fn workspace ->
      workspace.name == project or String.starts_with?(workspace.name, project <> "@")
    end)
  end

  defp workspace_map(workspace) do
    owned = Enum.count(workspace.members, &(&1.ownership == "owned"))
    borrowed = Enum.count(workspace.members, &(&1.ownership == "borrowed"))

    %{
      id: workspace.id,
      name: workspace.name,
      description: workspace.description,
      labels: Enum.map(workspace.labels, & &1.label),
      members: length(workspace.members),
      owned: owned,
      borrowed: borrowed,
      marker_path: workspace.marker_path,
      inserted_at: workspace.inserted_at
    }
  end

  defp remove(global, args) do
    with {:ok, opts, rest} <- Helpers.parse(args, rm_strict()),
         {:ok, target} <- one_arg(rest, "gitspace workspace rm <workspace>[:<member>]"),
         {:ok, workspace_name, member_name} <- split_rm_target(target),
         {:ok, config} <- Helpers.load_config(),
         :ok <- Helpers.start_index(config),
         {:ok, workspace} <- Workspaces.get(config, workspace_name),
         {:ok, plan} <-
           Teardown.plan(config, workspace,
             member: member_name,
             delete_branch: opts[:delete_branch],
             force: opts[:force]
           ),
         :ok <- precheck_risky(plan, opts) do
      if opts[:dry_run] do
        case Teardown.execute(config, plan, dry_run: true) do
          {:ok, result} -> {:ok, result, &render_rm/1}
          {:partial, result, failures} -> {:partial, result, &render_rm/1, rm_partial(failures)}
          {:error, error} -> {:error, error}
        end
      else
        question =
          case member_name do
            nil -> "remove workspace #{workspace.name} and its owned checkouts?"
            member -> "remove member #{workspace.name}:#{member}?"
          end

        question = question <> branch_suffix(plan)

        with :ok <- Helpers.require_confirmation(global, opts, question) do
          case Teardown.execute(config, plan, force: opts[:force]) do
            {:ok, result} -> {:ok, result, &render_rm/1}
            {:partial, result, failures} -> {:partial, result, &render_rm/1, rm_partial(failures)}
            {:error, error} -> {:error, error}
          end
        end
      end
    end
  end

  defp rm_strict do
    [force: :boolean, dry_run: :boolean, delete_branch: :boolean] ++ Helpers.global_strict()
  end

  defp branch_suffix(plan) do
    deleted = Map.get(plan, :delete_branches, [])
    kept = Map.get(plan, :branches, [])

    [branch_verb(deleted, "deletes"), branch_verb(kept, "keeps")]
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> ""
      parts -> " (" <> Enum.join(parts, "; ") <> ")"
    end
  end

  defp branch_verb([], _verb), do: nil
  defp branch_verb([branch], verb), do: "#{verb} branch #{branch_label(branch)}"

  defp branch_verb([first, second], verb) do
    "#{verb} branches #{branch_label(first)}, #{branch_label(second)}"
  end

  defp branch_verb(branches, verb), do: "#{verb} #{length(branches)} branches"

  defp branch_label(%{repo: repo, name: name}), do: "#{repo}:#{name}"

  defp split_rm_target(target) do
    case String.split(target, ":", parts: 2) do
      [workspace] when workspace != "" ->
        {:ok, workspace, nil}

      [workspace, member] when workspace != "" and member != "" ->
        {:ok, workspace, member}

      _ ->
        {:error, Error.new(:usage, "usage: gitspace workspace rm <workspace>[:<member>]")}
    end
  end

  defp precheck_risky(plan, opts) do
    cond do
      !!opts[:dry_run] or !!opts[:force] -> :ok
      plan.risky == [] -> :ok
      true -> {:error, Teardown.risky_error(plan)}
    end
  end

  defp rm_partial(failures) do
    names = failures |> Enum.map(& &1.repo) |> Enum.uniq() |> Enum.join(", ")

    Error.new(:partial, "workspace removal was partial: #{names}",
      hint: "fix the reported members and re-run",
      details: %{failures: Enum.map(failures, &Map.drop(&1, [:error]))}
    )
  end

  defp edit(_global, args) do
    with {:ok, opts, rest} <- Helpers.parse(args, edit_strict()),
         {:ok, name} <- one_arg(rest, "gitspace workspace edit <workspace> [--description D]"),
         {:ok, config} <- Helpers.load_config(),
         :ok <- Helpers.start_index(config),
         {:ok, result} <- Workspaces.edit(config, name, opts) do
      {:ok, result, &render_edit/1}
    end
  end

  defp edit_strict do
    [description: :string, clear_description: :boolean] ++ Helpers.global_strict()
  end

  defp render_edit(result) do
    IO.puts("edited #{result.workspace}")
    IO.puts("  description: #{result.description || "(none)"}")

    labels = if result.labels == [], do: "(none)", else: Enum.join(result.labels, ", ")
    IO.puts("  labels:      #{labels}")
    IO.puts("  marker:      #{result.marker_path}")
  end

  defp status(_global, []),
    do: {:error, Error.new(:usage, "usage: gitspace workspace status <name>")}

  defp status(global, [name | rest]) do
    Inventory.status(global, [name | rest])
  end

  defp one_arg([arg], _usage), do: {:ok, arg}
  defp one_arg(_rest, usage), do: {:error, Error.new(:usage, "usage: #{usage}")}

  defp render(result) do
    action =
      cond do
        result.dry_run and result.created -> "would create"
        result.dry_run -> "would update"
        result.created -> "created"
        true -> "updated"
      end

    IO.puts("#{action} workspace #{result.workspace}")
    IO.puts("  path:     #{result.path}")
    IO.puts("  marker:   #{result.marker_path}")

    IO.puts(
      "  labels:   #{if result.labels == [], do: "-", else: Enum.join(result.labels, ", ")}"
    )

    if result.description do
      IO.puts("  describe: #{result.description}")
    end

    IO.puts("")

    Output.table(
      ["ACTION", "NAME", "OWN", "REPO", "REF", "BRANCH", "PATH"],
      Enum.map(result.members, fn member ->
        [
          member.action,
          member.name,
          member.ownership,
          member.repo,
          member.ref,
          member.branch || "(detached)",
          member.path
        ]
      end)
    )
  end

  defp render_list(%{workspaces: workspaces}) do
    Output.table(
      ["NAME", "MEMBERS", "OWNED", "BORROWED", "LABELS", "DESCRIPTION"],
      Enum.map(workspaces, fn workspace ->
        [
          workspace.name,
          workspace.members,
          workspace.owned,
          workspace.borrowed,
          workspace.labels,
          workspace.description
        ]
      end)
    )
  end

  defp render_rm(result) do
    action = if result.dry_run, do: "would remove", else: "removed"

    title =
      case result.member do
        nil -> "workspace #{result.workspace}"
        member -> "member #{result.workspace}:#{member}"
      end

    IO.puts("#{action} #{title}")
    IO.puts("  path:     #{result.path}")
    IO.puts("  marker:   #{result.marker_path}")

    if result.removed != [] do
      IO.puts("")

      Output.table(
        ["ACTION", "MEMBER", "OWN", "BRANCH", "PATH"],
        Enum.map(result.removed, fn member ->
          [
            member.action,
            member.name,
            member.ownership,
            member.branch || "(detached)",
            member.path
          ]
        end)
      )
    end

    if result.risky != [] do
      IO.puts("")
      IO.puts("risky members:")

      Enum.each(result.risky, fn member ->
        IO.puts("  #{member.member}: #{Enum.join(member.reasons, ", ")}")
      end)
    end

    if result[:deleted_branches] not in [nil, []] do
      IO.puts("")
      IO.puts(if result.dry_run, do: "branches to delete", else: "branches deleted")

      Enum.each(result.deleted_branches, fn branch ->
        notes =
          [
            if(branch[:forced], do: "forced"),
            if(branch[:keep_ref], do: "head kept at #{branch.keep_ref}")
          ]
          |> Enum.reject(&is_nil/1)

        suffix = if notes == [], do: "", else: " (" <> Enum.join(notes, "; ") <> ")"
        IO.puts("  #{branch.repo}:#{branch.name}#{suffix}")
      end)
    end

    if result.branches != [] do
      IO.puts("")
      IO.puts("branches kept")

      Enum.each(result.branches, fn branch ->
        suffix = if branch[:reason], do: " (#{branch.reason})", else: ""
        IO.puts("  #{branch.repo}:#{branch.name}#{suffix}")
      end)
    end

    if result.tombstoned do
      IO.puts("")
      IO.puts("workspace removed; the name may be reused")
    end

    if result[:project_directory_removed] do
      IO.puts("removed project directory #{result.project_path}")
    end

    if result.directory_kept do
      IO.puts("directory kept because it still contains files")
    end
  end

  defp render_help(%{help: help}), do: IO.puts(help)

  @doc false
  def help do
    """
    WORKSPACES AND PROJECTS
      A project is a named set of repositories. A workspace is the on-disk instance
      for one project + topic. `gitspace co` is the normal checkout path; this
      command exists for explicit owned/borrowed member lists, labels, descriptions,
      member directory names and dry runs.

    REMOVAL
      `workspace rm <workspace>` removes every member and tombstones the workspace.
      `workspace rm <workspace>:<member>` removes one membership; removing the last
      one tombstones the workspace. Borrowed checkouts are unlinked, never deleted.
      Risky owned members are refused unless --force archives their work under
      <data>/trash first. Branches are kept and listed as `branches kept`, in
      --dry-run and after removal. --delete-branch also deletes each owned local
      branch whose commits are already reachable from a remote, a tag or another
      local branch. The default branch and branches checked out elsewhere are
      never deleted. Combined with --force, a branch with commits that exist
      only here is anchored under refs/gitspace/keep/branch/... and then deleted.
      The push target and the remote branch are never touched. The project
      directory is removed with its
      last workspace when only the gitspace project marker is left; the
      project definition stays.

    USAGE
      gitspace workspace new [<project>@]<topic> [--own <repo>[@<ref>]]...
                                    [--borrow <repo>[@<ref>]]... [--branch B] [--as-is]
                                    [--label L]... [--description D]
                                    [--as <repo>=<dir>]... [--fetch] [--dry-run] [--json]
      gitspace workspace ls [--project P] [--label L] [--all] [--json]
      gitspace workspace status <workspace> [--refresh] [--json]
      gitspace workspace edit <workspace> [--description D] [--clear-description]
      gitspace workspace rm <workspace>[:<member>] [--force] [--delete-branch]
                                  [--dry-run] [--yes] [--json]

    TARGET
      `vemags@4711` names project and topic; `4711` is a topic whose project is
      inferred from the owned repositories. Topics may contain `/`; `@` is
      reserved and separates project from topic.

    OWNED MEMBERS
      The branch is derived from the topic using the project template (default
      feature/{topic}) and starts at the project default ref or the repo default.
      The topic is used verbatim in the branch, including '/'; only the
      workspace directory is slugged. --branch overrides the name; --as-is
      checks the ref out unchanged.

    BORROWED MEMBERS
      An existing checkout, symlinked into the workspace at its member name and
      never moved, branched or deleted. Removing the membership removes only the
      symlink. With several checkouts for one repository, select one with repo@ref.

    MEMBER DIRECTORIES
      Top-level by default. Use --as repo=name to choose a member directory.
      Names are immutable once the member exists.
    """
  end
end
