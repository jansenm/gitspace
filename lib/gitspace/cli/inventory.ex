defmodule Gitspace.CLI.Inventory do
  @moduledoc false

  alias Gitspace.{Error, Inventory, Targets}
  alias Gitspace.CLI.{Helpers, Output}

  def inbox(_global, args) do
    with {:ok, _opts, rest} <- Helpers.parse(args, Helpers.global_strict()),
         :ok <- Helpers.no_extra_args(rest),
         {:ok, config} <- Helpers.load_config(),
         :ok <- Helpers.start_index(config) do
      {:ok, Inventory.inbox(config), &render_inbox/1}
    end
  end

  def ls(_global, args) do
    with {:ok, opts, rest} <- Helpers.parse(args, ls_strict()),
         :ok <- Helpers.no_extra_args(rest),
         {:ok, config} <- Helpers.load_config(),
         :ok <- Helpers.start_index(config) do
      rows =
        Inventory.ls(config,
          repo: opts[:repo],
          workspace: opts[:workspace],
          label: opts[:label],
          state: opts[:state],
          kind: opts[:kind],
          source: opts[:source]
        )

      {:ok, %{checkouts: rows, wide: !!opts[:wide]}, &render_ls/1}
    end
  end

  def status(_global, args) do
    with {:ok, opts, rest} <- Helpers.parse(args, status_strict()),
         {:ok, config} <- Helpers.load_config(),
         :ok <- Helpers.start_index(config) do
      case rest do
        [] ->
          {:ok, Inventory.inbox(config), &render_inbox/1}

        [target] ->
          status_target(config, target, opts)

        _ ->
          {:error, Error.new(:usage, "usage: gitspace status [target]")}
      end
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
      case resolved do
        {:workspace, workspace} ->
          case Inventory.workspace_status(config, workspace.name, refresh: opts[:refresh]) do
            {:ok, row} ->
              {:ok, %{workspace: row, refreshed: !!opts[:refresh]}, &render_workspace_status/1}

            {:error, error} ->
              {:error, error}
          end

        {:member, _workspace, member} ->
          {:ok,
           %{
             checkout:
               Inventory.checkout_status(config, member.checkout, refresh: opts[:refresh]),
             refreshed: !!opts[:refresh]
           }, &render_checkout_status/1}

        {:checkout, checkout} ->
          {:ok,
           %{
             checkout: Inventory.checkout_status(config, checkout, refresh: opts[:refresh]),
             refreshed: !!opts[:refresh]
           }, &render_checkout_status/1}

        {:repo, repo} ->
          {:ok, %{repo: repo.slug, checkouts: Inventory.ls(config, repo: repo.slug)},
           &render_repo_status/1}
      end
    end
  end

  defp ls_strict do
    [
      repo: :string,
      workspace: :string,
      label: :string,
      state: :string,
      kind: :string,
      source: :string,
      all: :boolean,
      wide: :boolean
    ] ++ Helpers.global_strict()
  end

  defp status_strict, do: [refresh: :boolean] ++ Helpers.global_strict()

  defp one_arg([arg], _usage), do: {:ok, arg}
  defp one_arg(_rest, usage), do: {:error, Error.new(:usage, "usage: #{usage}")}

  defp repo_map(repo) do
    %{
      id: repo.id,
      slug: repo.slug,
      remote_url: repo.remote_url,
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

  defp render_ls(%{checkouts: rows, wide: wide}) do
    headers =
      if wide do
        [
          "KIND",
          "REPO",
          "WORKSPACE",
          "BRANCH",
          "DIRTY",
          "AHEAD",
          "BEHIND",
          "UNPUSHED",
          "AGE",
          "SOURCE",
          "PATH"
        ]
      else
        [
          "KIND",
          "REPO",
          "WORKSPACE",
          "BRANCH",
          "DIRTY",
          "AHEAD",
          "BEHIND",
          "UNPUSHED",
          "AGE",
          "PATH"
        ]
      end

    table_rows =
      Enum.map(rows, fn row ->
        base = [
          row.kind_name,
          row.repo,
          row.workspace || "-",
          row.branch || "(detached)",
          number(row.dirty, row.stale),
          number(row.ahead, row.stale),
          number(row.behind, row.stale),
          number(row.unpushed, row.stale),
          row.age
        ]

        if wide, do: base ++ [row.source, row.path], else: base ++ [row.path]
      end)

    Output.table(headers, table_rows)
  end

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

  defp render_checkout_status(%{checkout: checkout}) do
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

    if checkout.risk.reasons != [] do
      IO.puts("  risk:      #{Enum.join(checkout.risk.reasons, ", ")}")
    end
  end

  defp render_repo_status(%{repo: repo, checkouts: rows}) do
    IO.puts("repository #{repo}")
    render_ls(%{checkouts: rows, wide: false})
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

  defp render_show_repo(%{repo: repo, checkouts: rows}) do
    IO.puts("#{repo.slug} · #{repo.remote_url}")
    IO.puts("  mirror:    #{repo.bare_path || "(external)"}")
    IO.puts("  default:   #{repo.default_branch || "?"}")
    IO.puts("")
    render_ls(%{checkouts: rows, wide: true})
  end

  defp render_path(data) do
    IO.puts(data.path)
  end

  defp number(nil, _stale), do: "?"
  defp number(_value, true), do: "?"
  defp number(value, _stale), do: value
end
