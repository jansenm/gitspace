defmodule Gitspace.CLI.Inventory do
  @moduledoc false

  alias Gitspace.{Error, Inventory, Targets, Workspaces}
  alias Gitspace.CLI.{Helpers, Output}
  alias Gitspace.Git.{Changes, Operation}

  def inbox(_global, args) do
    with {:ok, _opts, rest} <- Helpers.parse(args, Helpers.global_strict()),
         :ok <- Helpers.no_extra_args(rest),
         {:ok, config} <- Helpers.load_config(),
         :ok <- Helpers.start_index(config) do
      {:ok, Inventory.inbox(config), &render_inbox/1}
    end
  end

  def ls(global, args) do
    with {:ok, opts, rest} <- Helpers.parse(args, ls_strict()),
         :ok <- Helpers.no_extra_args(rest),
         {:ok, config} <- Helpers.load_config(),
         :ok <- Helpers.start_index(config) do
      rows =
        Inventory.ls(config,
          refresh: opts[:refresh],
          repo: opts[:repo],
          workspace: opts[:workspace],
          project: opts[:project],
          topic: opts[:topic],
          label: opts[:label],
          state: opts[:state],
          kind: opts[:kind],
          source: opts[:source]
        )

      verbose = !!global.verbose or !!opts[:wide]

      {:ok, %{checkouts: rows, verbose: verbose}, &render_ls/1}
    end
  end

  def status(_global, args) do
    with {:ok, opts, rest} <- Helpers.parse(args, status_strict(), l: :long, v: :diff),
         :ok <- validate_status_options(opts),
         {:ok, config} <- Helpers.load_config(),
         :ok <- Helpers.start_index(config) do
      case rest do
        [] ->
          if detail?(opts) do
            {:error, Error.new(:usage, "status --long/--diff needs a member or checkout target")}
          else
            {:ok, Inventory.inbox(config, refresh: opts[:refresh]), &render_inbox/1}
          end

        [target] ->
          status_target(config, target, opts)

        _ ->
          {:error, Error.new(:usage, "usage: gitspace status [target]")}
      end
    end
  end

  defp detail?(opts), do: !!opts[:long] or !!opts[:diff]

  defp validate_status_options(opts) do
    case opts[:diff_lines] do
      nil -> :ok
      lines when is_integer(lines) and lines >= 0 -> :ok
      _ -> {:error, Error.new(:usage, "--diff-lines must be a non-negative integer")}
    end
  end

  def show(_global, args) do
    with {:ok, _opts, rest} <- Helpers.parse(args, Helpers.global_strict()),
         {:ok, target} <- one_arg(rest, "gitspace show <target>"),
         {:ok, config} <- Helpers.load_config(),
         :ok <- Helpers.start_index(config),
         {:ok, resolved} <- Targets.resolve(config, target) do
      case resolved do
        {:workspace, workspace} ->
          case Inventory.show_workspace(config, workspace.name) do
            {:ok, row} -> {:ok, %{workspace: row}, &render_show_workspace/1}
            {:error, error} -> {:error, error}
          end

        {:member, _workspace, member} ->
          {:ok, %{checkout: Inventory.show_checkout(config, member.checkout)},
           &render_show_checkout/1}

        {:checkout, checkout} ->
          {:ok, %{checkout: Inventory.show_checkout(config, checkout)}, &render_show_checkout/1}

        {:project, project} ->
          {:ok, %{project: project, workspaces: project_workspaces(config, project)},
           &render_show_project/1}

        {:repo, repo} ->
          {:ok,
           %{
             repo: repo_map(repo),
             checkouts: Inventory.ls(config, repo: repo.slug)
           }, &render_show_repo/1}
      end
    end
  end

  def path(_global, args) do
    with {:ok, _opts, rest} <- Helpers.parse(args, Helpers.global_strict()),
         {:ok, target} <- one_arg(rest, "gitspace path <target>"),
         {:ok, config} <- Helpers.load_config(),
         :ok <- Helpers.start_index(config),
         {:ok, result} <- Targets.path_for(config, target) do
      {:ok, result, &render_path/1}
    end
  end

  defp status_target(config, target, opts) do
    with {:ok, resolved} <- Targets.resolve(config, target) do
      if detail?(opts) and not single_checkout?(resolved) do
        {:error, Error.new(:usage, "status --long/--diff needs a member or checkout target")}
      else
        resolved_status(config, resolved, opts)
      end
    end
  end

  defp single_checkout?({:member, _workspace, _member}), do: true
  defp single_checkout?({:checkout, _checkout}), do: true
  defp single_checkout?(_resolved), do: false

  defp resolved_status(config, resolved, opts) do
    case resolved do
      {:workspace, workspace} ->
        case Inventory.workspace_status(config, workspace.name, refresh: opts[:refresh]) do
          {:ok, row} ->
            {:ok, %{workspace: row, refreshed: !!opts[:refresh]}, &render_workspace_status/1}

          {:error, error} ->
            {:error, error}
        end

      {:member, _workspace, member} ->
        row = Inventory.checkout_status(config, member.checkout, refresh: opts[:refresh])
        {:ok, checkout_data(row, opts), &render_checkout_status/1}

      {:checkout, checkout} ->
        row = Inventory.checkout_status(config, checkout, refresh: opts[:refresh])
        {:ok, checkout_data(row, opts), &render_checkout_status/1}

      {:project, project} ->
        {:ok,
         %{
           project: project,
           checkouts: Inventory.ls(config, project: project.name, refresh: opts[:refresh])
         }, &render_project_status/1}

      {:repo, repo} ->
        {:ok,
         %{
           repo: repo.slug,
           checkouts: Inventory.ls(config, repo: repo.slug, refresh: opts[:refresh])
         }, &render_repo_status/1}
    end
  end

  defp checkout_data(row, opts) do
    data = %{checkout: row, refreshed: !!opts[:refresh]}

    if detail?(opts) do
      Map.merge(data, details(row.path, opts))
    else
      data
    end
  end

  defp details(path, opts) do
    details =
      case Changes.entries(path) do
        {:ok, entries} -> %{changes: entries}
        {:error, reason} -> %{changes_error: error_text(reason)}
      end

    if opts[:diff] do
      case Changes.diff(path, max_lines: opts[:diff_lines] || 200) do
        {:ok, diff} -> Map.put(details, :diff, diff)
        {:error, reason} -> Map.put(details, :diff_error, error_text(reason))
      end
    else
      details
    end
  end

  defp error_text(%{stderr: stderr}) when is_binary(stderr) and stderr != "",
    do: String.trim(stderr)

  defp error_text(other), do: inspect(other)

  defp ls_strict do
    [
      repo: :string,
      workspace: :string,
      project: :string,
      topic: :string,
      label: :string,
      state: :string,
      kind: :string,
      source: :string,
      all: :boolean,
      wide: :boolean,
      refresh: :boolean
    ] ++ Helpers.global_strict()
  end

  defp status_strict do
    [refresh: :boolean, long: :boolean, diff: :boolean, diff_lines: :integer] ++
      Helpers.global_strict()
  end

  defp one_arg([arg], _usage), do: {:ok, arg}
  defp one_arg(_rest, usage), do: {:error, Error.new(:usage, "usage: #{usage}")}

  defp repo_map(repo) do
    %{
      id: repo.id,
      slug: repo.slug,
      remote_url: repo.remote_url,
      origin_kind: repo.origin_kind,
      bare_path: repo.bare_path,
      default_branch: repo.default_branch,
      state: repo.state,
      last_fetched_at: repo.last_fetched_at,
      last_fetch_error: repo.last_fetch_error
    }
  end

  defp render_inbox(data) do
    counts = data.counts

    IO.puts(
      "#{counts.repositories} repos · #{counts.checkouts} checkouts · " <>
        "#{counts.workspaces} workspaces · #{counts.needs} need a decision"
    )

    IO.puts("")
    IO.puts("NEEDS YOU")
    if data.needs == [], do: IO.puts("  (nothing)")

    Enum.each(data.needs, fn row ->
      case row.kind do
        :workspace ->
          IO.puts(
            "  ! #{row.name}  #{row.owned} owned · #{row.borrowed} borrowed  " <>
              "#{Enum.join(row.reasons, ", ")}  #{Inventory.human_age(row.last_activity)}"
          )

          if row.description, do: IO.puts("      #{row.description}")

        :checkout ->
          IO.puts(
            "  ! #{row.repo}  #{row.path}  #{Enum.join(row.risk.reasons, ", ")}  #{row.age}"
          )
      end
    end)

    IO.puts("")
    IO.puts("WORKING")

    if data.working == [] do
      IO.puts("  (nothing)")
    else
      Enum.each(data.working, fn row ->
        case row.kind do
          :workspace ->
            IO.puts(
              "  #{row.name}  #{row.owned} owned · #{row.borrowed} borrowed  " <>
                "#{Inventory.human_age(row.last_activity)}"
            )

          :checkout ->
            IO.puts("  #{row.repo}  #{row.branch || "(detached)"}  #{row.path}  #{row.age}")
        end
      end)
    end

    IO.puts("")
    IO.puts("next: gitspace ls · gitspace doctor")
  end

  defp render_ls(%{checkouts: rows} = data) do
    verbose = Map.get(data, :verbose, false)

    headers =
      [
        "PROJECT",
        "TOPIC",
        "MEMBER",
        "BRANCH",
        "DIRTY",
        "AHEAD",
        "BEHIND",
        "UNPUSHED",
        "AGE"
      ] ++ if(verbose, do: ["HASH", "MIRROR"], else: [])

    table_rows =
      Enum.map(rows, fn row ->
        base = [
          row.project || "-",
          row.topic || "-",
          row.member || row.repo,
          row.branch || "(detached)",
          number(row.dirty, row.stale),
          number(row.ahead, row.stale),
          number(row.behind, row.stale),
          number(row.unpushed, row.stale),
          row.age
        ]

        if verbose do
          base ++ [short_hash(row.hash), row.mirror || "-"]
        else
          base
        end
      end)

    Output.table(headers, table_rows)
  end

  defp short_hash(nil), do: "-"
  defp short_hash(hash), do: String.slice(hash, 0, 12)

  defp render_workspace_status(%{workspace: workspace}) do
    labels = if workspace.labels == [], do: "-", else: Enum.join(workspace.labels, ", ")

    IO.puts(
      "#{workspace.name} · #{workspace.description || "(no description)"} · " <>
        "#{length(workspace.members)} members (#{workspace.owned} owned, #{workspace.borrowed} borrowed)"
    )

    IO.puts("labels: #{labels}")
    IO.puts("")

    Output.table(
      ["MEMBER", "OWN", "REF", "DIRTY", "AHEAD", "BEHIND", "UNPUSHED", "STATE"],
      Enum.map(workspace.members, fn member ->
        [
          member.handle,
          member.ownership,
          member.branch || "(detached)",
          number(member.dirty, member.stale),
          number(member.ahead, member.stale),
          number(member.behind, member.stale),
          number(member.unpushed, member.stale),
          member.state
        ]
      end)
    )

    if workspace.reasons == [] do
      IO.puts("")
      IO.puts("clean")
    else
      IO.puts("")
      IO.puts("! #{Enum.join(workspace.reasons, ", ")}")
    end
  end

  defp render_checkout_status(%{checkout: checkout} = data) do
    IO.puts("#{checkout.repo} · #{checkout.path}")
    IO.puts("  workspace: #{checkout.workspace || "-"}")
    IO.puts("  branch:    #{checkout.branch || "(detached)"}")
    IO.puts("  state:     #{checkout.state}#{if checkout.stale, do: " (status stale)", else: ""}")
    IO.puts("  source:    #{checkout.source} (#{checkout.kind_name})")
    IO.puts("  dirty:     #{number(checkout.dirty, checkout.stale)}")
    IO.puts("  ahead:     #{number(checkout.ahead, checkout.stale)}")
    IO.puts("  behind:    #{number(checkout.behind, checkout.stale)}")
    IO.puts("  unpushed:  #{number(checkout.unpushed, checkout.stale)}")
    IO.puts("  age:       #{checkout.age}")

    if checkout.operation do
      IO.puts("  operation: #{Operation.describe(checkout.operation)}")
    end

    if checkout.risk.reasons != [] do
      IO.puts("  risk:      #{Enum.join(checkout.risk.reasons, ", ")}")
    end

    render_changes(Map.get(data, :changes), Map.get(data, :changes_error))
    render_diff(Map.get(data, :diff), Map.get(data, :diff_error))
  end

  defp render_changes(nil, nil), do: :ok

  defp render_changes(_changes, error) when is_binary(error),
    do: IO.puts("  files:     ! #{error}")

  defp render_changes([], _error), do: IO.puts("  files:     (clean)")

  defp render_changes(entries, _error) do
    IO.puts("  files:")

    Enum.each(entries, fn entry ->
      origin = if entry.orig_path, do: " (from #{entry.orig_path})", else: ""
      IO.puts("    #{entry.status}  #{entry.path}#{origin}")
    end)
  end

  defp render_diff(nil, nil), do: :ok
  defp render_diff(_diff, error) when is_binary(error), do: IO.puts("  diff:      ! #{error}")

  defp render_diff(diff, _error) do
    if diff.unstaged == "" and diff.staged == "" do
      IO.puts("  diff:      (clean)")
    else
      render_patch("unstaged", diff.unstaged)
      render_patch("staged", diff.staged)

      if diff.truncated do
        IO.puts("  (diff truncated; use --diff-lines)")
      end
    end
  end

  defp render_patch(_label, ""), do: :ok

  defp render_patch(label, patch) do
    IO.puts("  diff (#{label}):")

    patch
    |> String.trim_trailing()
    |> String.split("\n")
    |> Enum.each(&IO.puts("    " <> &1))
  end

  defp render_repo_status(%{repo: repo, checkouts: rows}) do
    IO.puts("repository #{repo}")
    render_ls(%{checkouts: rows, verbose: false})
  end

  defp render_show_workspace(%{workspace: workspace}) do
    render_workspace_status(%{workspace: workspace})
    IO.puts("  marker:    #{workspace.marker_path || "-"}")
  end

  defp render_show_checkout(%{checkout: checkout}) do
    render_checkout_status(%{checkout: checkout})

    if checkout.workspaces != [] do
      IO.puts(
        "  workspaces: " <>
          Enum.map_join(checkout.workspaces, ", ", fn m -> "#{m.workspace} (#{m.ownership})" end)
      )
    end
  end

  defp project_workspaces(config, project) do
    Workspaces.list(config)
    |> Enum.filter(fn workspace ->
      workspace.name == project.name or String.starts_with?(workspace.name, project.name <> "@")
    end)
  end

  defp render_show_project(%{project: project, workspaces: workspaces}) do
    IO.puts("#{project.name}")
    IO.puts("  path:    #{project.path}")
    IO.puts("  members: #{length(project.members)}")
    IO.puts("  source:  #{project.source}")

    if project.description do
      IO.puts("  describe: #{project.description}")
    end

    if workspaces != [] do
      IO.puts("")
      IO.puts("workspaces:")

      Enum.each(workspaces, fn workspace ->
        IO.puts("  #{workspace.name}  #{workspace.marker_path}")
      end)
    end
  end

  defp render_project_status(%{project: project, checkouts: rows}) do
    IO.puts("project #{project.name}")
    IO.puts("  path: #{project.path}")
    IO.puts("")
    render_ls(%{checkouts: rows, verbose: false})
  end

  defp render_show_repo(%{repo: repo, checkouts: rows}) do
    remote = if repo.origin_kind == "local", do: "LOCAL (no upstream)", else: repo.remote_url
    IO.puts("#{repo.slug} · #{remote}")
    IO.puts("  mirror:    #{repo.bare_path || "(external)"}")
    IO.puts("  default:   #{repo.default_branch || "?"}")
    IO.puts("")
    render_ls(%{checkouts: rows, verbose: true})
  end

  defp render_path(data) do
    IO.puts(data.path)
  end

  defp number(nil, _stale), do: "?"
  defp number(_value, true), do: "?"
  defp number(value, _stale), do: value
end
