defmodule Gitspace.Inventory do
  @moduledoc "Read models for the inbox, `ls`, `status` and `show`."

  import Ecto.Query

  alias Gitspace.{Checkouts, Config, Error, Repo, Workspaces}
  alias Gitspace.Git.Operation
  alias Gitspace.Index.{Checkout, WorkspaceMember}

  @initial_refresh_limit 20

  @spec inbox(Config.t(), keyword()) :: map()
  def inbox(%Config{} = config, opts \\ []) do
    workspaces = Workspaces.list(config)
    member_ids = member_ids(workspaces)

    all_workspace_checkouts =
      workspaces
      |> Enum.flat_map(& &1.members)
      |> Enum.map(& &1.checkout)

    external =
      Checkouts.list(config, source: "external")
      |> Enum.reject(&MapSet.member?(member_ids, &1.id))

    orphans =
      Checkouts.list(config, source: "managed")
      |> Enum.reject(&MapSet.member?(member_ids, &1.id))

    all = all_workspace_checkouts ++ external ++ orphans

    refreshed =
      if opts[:refresh] do
        refresh_all(config, all, opts[:progress])
      else
        refresh_unknown(config, all, opts[:progress])
      end

    workspace_rows = Enum.map(workspaces, &workspace_row(config, &1, refreshed))
    external_rows = Enum.map(external, &checkout_row(config, &1, nil, refreshed))
    orphan_rows = Enum.map(orphans, &checkout_row(config, &1, nil, refreshed))

    needs =
      (workspace_rows ++ external_rows ++ orphan_rows)
      |> Enum.filter(&at_risk?/1)
      |> sort_needs()

    working =
      (workspace_rows ++ orphan_rows)
      |> Enum.reject(&at_risk?/1)
      |> Enum.sort_by(&activity_sort_key/1, :desc)
      |> Enum.take(6)

    %{
      counts: %{
        repositories: Repo.aggregate(Gitspace.Index.Repository, :count),
        checkouts: Repo.aggregate(Checkout, :count),
        workspaces: length(workspaces),
        needs: length(needs)
      },
      needs: needs,
      working: working,
      running: []
    }
  end

  @spec workspace_row(Config.t(), map(), map()) :: map()
  def workspace_row(%Config{} = config, workspace, refreshed \\ %{}) do
    members =
      Enum.map(workspace.members, fn member ->
        checkout = Map.get(refreshed, member.checkout_id, member.checkout)
        member_row(config, workspace, member, checkout)
      end)

    reasons =
      members
      |> Enum.flat_map(& &1.risk.reasons)
      |> Enum.uniq()

    {project, topic} = Workspaces.parts(workspace)

    %{
      kind: :workspace,
      name: workspace.name,
      project: project,
      topic: topic,
      description: workspace.description,
      labels: Enum.map(workspace.labels, & &1.label),
      members: members,
      owned: Enum.count(members, &(&1.ownership == "owned")),
      borrowed: Enum.count(members, &(&1.ownership == "borrowed")),
      unpushed: members |> Enum.map(&(&1.unpushed || 0)) |> Enum.sum(),
      dirty: members |> Enum.map(&(&1.dirty || 0)) |> Enum.sum(),
      missing: Enum.count(members, &(&1.state in ["missing", "broken"])),
      at_risk: reasons != [],
      reasons: reasons,
      last_activity:
        members
        |> Enum.map(& &1.last_seen_at)
        |> Enum.reject(&is_nil/1)
        |> Enum.max_by(&DateTime.to_unix/1, fn -> nil end)
    }
  end

  @spec checkout_row(Config.t(), Checkout.t(), map() | nil, map()) :: map()
  def checkout_row(%Config{} = config, %Checkout{} = checkout, membership, refreshed \\ %{}) do
    checkout = Map.get(refreshed, checkout.id, checkout)

    repo =
      case checkout.repository do
        %Gitspace.Index.Repository{} = repo -> repo
        _ -> Repo.get!(Gitspace.Index.Repository, checkout.repository_id)
      end

    {project, topic} = membership_parts(membership)
    operation = Operation.read(checkout.path)
    risk = operation_risk(Checkouts.risk(checkout), operation)

    %{
      kind: :checkout,
      id: checkout.id,
      repo: repo.slug,
      workspace: membership && membership.workspace.name,
      project: project,
      topic: topic,
      member: membership && (Map.get(membership, :name) || repo.slug),
      ownership: membership && membership.ownership,
      path: checkout.path,
      branch: checkout.branch,
      detached: checkout.detached,
      state: checkout.state,
      source: checkout.source,
      kind_name: checkout.kind,
      hash: mirror_hash(repo.bare_path),
      mirror: repo.bare_path,
      dirty: checkout.dirty,
      ahead: checkout.ahead,
      behind: checkout.behind,
      unpushed: checkout.unpushed,
      untracked: checkout.untracked,
      stale: not Checkouts.fresh?(checkout, config.status_max_age),
      operation: operation,
      risk: risk,
      age: human_age(checkout.last_seen_at || checkout.updated_at),
      last_seen_at: checkout.last_seen_at,
      last_status_at: checkout.last_status_at
    }
  end

  @spec ls(Config.t(), keyword()) :: [map()]
  def ls(%Config{} = config, filters \\ []) do
    memberships = memberships_by_checkout()

    checkouts =
      Checkouts.list(config, filters)
      |> then(fn checkouts ->
        if filters[:refresh] do
          Checkouts.refresh_many(config, checkouts, on_progress: filters[:progress])
        else
          checkouts
        end
      end)

    checkouts
    |> Enum.map(fn checkout ->
      checkout_row(config, checkout, Map.get(memberships, checkout.id))
    end)
    |> Enum.filter(&match_project(&1, filters[:project]))
    |> Enum.filter(&match_topic(&1, filters[:topic]))
  end

  defp match_project(_row, nil), do: true
  defp match_project(row, project), do: row.project == project

  defp match_topic(_row, nil), do: true
  defp match_topic(row, topic), do: row.topic == topic

  defp membership_parts(nil), do: {nil, nil}

  defp membership_parts(membership) do
    Workspaces.parts(membership.workspace)
  end

  @spec workspace_status(Config.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, Error.t()}
  def workspace_status(config, name, opts \\ []) do
    with {:ok, workspace} <- Workspaces.get(config, name) do
      members = Enum.map(workspace.members, & &1.checkout)

      refreshed =
        if opts[:refresh] do
          refresh_all(config, members, opts[:progress])
        else
          refresh_unknown(config, members, opts[:progress])
        end

      {:ok, workspace_row(config, workspace, refreshed)}
    end
  end

  @spec checkout_status(Config.t(), Checkout.t(), keyword()) :: map()
  def checkout_status(config, checkout, opts \\ []) do
    checkout =
      if opts[:refresh] do
        case Checkouts.refresh(config, checkout) do
          {:ok, refreshed} -> refreshed
          {:error, _} -> checkout
        end
      else
        Map.get(refresh_unknown(config, [checkout], nil), checkout.id, checkout)
      end

    membership = Map.get(memberships_by_checkout(), checkout.id)
    checkout_row(config, checkout, membership)
  end

  @spec show_checkout(Config.t(), Checkout.t()) :: map()
  def show_checkout(%Config{} = config, %Checkout{} = checkout) do
    row = checkout_status(config, checkout)

    memberships =
      from(m in WorkspaceMember,
        join: w in assoc(m, :workspace),
        where: m.checkout_id == ^checkout.id and w.state == "active",
        select: %{workspace: w.name, name: m.name, ownership: m.ownership, role: m.role}
      )
      |> Repo.all()

    Map.merge(row, %{
      head: checkout.head_sha,
      created_by: checkout.created_by,
      inserted_at: checkout.inserted_at,
      updated_at: checkout.updated_at,
      workspaces: memberships
    })
  end

  @spec show_workspace(Config.t(), String.t()) :: {:ok, map()} | {:error, Error.t()}
  def show_workspace(config, name) do
    with {:ok, workspace} <- Workspaces.get(config, name) do
      refreshed = refresh_unknown(config, Enum.map(workspace.members, & &1.checkout), nil)
      row = workspace_row(config, workspace, refreshed)

      {:ok,
       Map.merge(row, %{
         marker_path: workspace.marker_path,
         inserted_at: workspace.inserted_at,
         updated_at: workspace.updated_at
       })}
    end
  end

  @spec human_age(DateTime.t() | nil) :: String.t()
  def human_age(nil), do: "?"

  def human_age(%DateTime{} = at) do
    seconds = max(DateTime.diff(DateTime.utc_now(), at, :second), 0)

    cond do
      seconds < 60 -> "#{seconds}s"
      seconds < 3_600 -> "#{div(seconds, 60)}m"
      seconds < 86_400 -> "#{div(seconds, 3_600)}h"
      seconds < 2_592_000 -> "#{div(seconds, 86_400)}d"
      true -> "#{div(seconds, 2_592_000)}M"
    end
  end

  defp operation_risk(risk, nil), do: risk

  defp operation_risk(risk, operation) do
    reason = Operation.describe(operation)
    %{risk | at_risk: true, reasons: Enum.uniq(risk.reasons ++ [reason])}
  end

  defp mirror_hash(nil), do: nil
  defp mirror_hash(path), do: Path.basename(path, ".git")

  defp member_row(config, workspace, member, checkout) do
    base = checkout_row(config, checkout, %{workspace: workspace, ownership: member.ownership})
    name = member.name || base.repo

    Map.merge(base, %{
      handle: "#{workspace.name}:#{name}",
      name: name,
      ownership: member.ownership,
      role: member.role,
      workspace: workspace.name
    })
  end

  defp refresh_unknown(config, checkouts, progress) do
    checkouts =
      checkouts
      |> List.flatten()
      |> Enum.uniq_by(& &1.id)
      |> Enum.take(@initial_refresh_limit)

    to_refresh =
      Enum.filter(checkouts, &(is_nil(&1.last_status_at) and File.dir?(&1.path)))

    refreshed = refresh_all(config, to_refresh, progress)

    Map.new(checkouts, fn checkout ->
      {checkout.id, Map.get(refreshed, checkout.id, checkout)}
    end)
  end

  defp refresh_all(config, checkouts, progress) do
    checkouts
    |> Enum.with_index(1)
    |> Enum.map(fn {checkout, index} ->
      label = progress_label(checkout)
      notify(progress, {:start, index, length(checkouts), label})

      case Checkouts.refresh(config, checkout) do
        {:ok, refreshed} ->
          notify(progress, {:ok, index, length(checkouts), label})
          refreshed

        {:error, error} ->
          notify(progress, {:error, index, length(checkouts), label, Exception.message(error)})
          checkout
      end
    end)
    |> Map.new(&{&1.id, &1})
  end

  defp progress_label(%{repository: %Gitspace.Index.Repository{slug: slug}}), do: slug
  defp progress_label(%{path: path}), do: Path.basename(path)

  defp notify(nil, _event), do: :ok
  defp notify(callback, event) when is_function(callback, 1), do: callback.(event)

  defp memberships_by_checkout do
    from(m in WorkspaceMember,
      join: w in assoc(m, :workspace),
      where: w.state == "active",
      preload: [:workspace]
    )
    |> Repo.all()
    |> Enum.group_by(& &1.checkout_id)
    |> Map.new(fn {checkout_id, [member | _]} -> {checkout_id, member} end)
  end

  defp member_ids(workspaces) do
    workspaces
    |> Enum.flat_map(& &1.members)
    |> Enum.map(& &1.checkout_id)
    |> MapSet.new()
  end

  # Workspace rows carry the flag directly; checkout rows nest it under `risk`.
  defp at_risk?(%{at_risk: at_risk}), do: at_risk
  defp at_risk?(%{risk: %{at_risk: at_risk}}), do: at_risk
  defp at_risk?(_row), do: false

  defp sort_needs(rows) do
    Enum.sort_by(rows, fn row ->
      {if((row[:missing] || 0) > 0, do: 0, else: 1), -(row[:unpushed] || 0),
       row[:name] || row[:path]}
    end)
  end

  defp activity_sort_key(row) do
    row[:last_activity] || row[:last_seen_at] || ~U[1970-01-01 00:00:00Z]
  end
end
