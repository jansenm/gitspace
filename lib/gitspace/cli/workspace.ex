defmodule Gitspace.CLI.Workspace do
  @moduledoc false

  alias Gitspace.{Create, Error, Workspaces}
  alias Gitspace.CLI.{Helpers, Inventory, Output, Prompt}

  def run(global, args) do
    case args do
      ["new" | rest] -> new(global, rest)
      ["ls" | rest] -> list(global, rest)
      ["status" | rest] -> status(global, rest)
      [] -> {:ok, %{help: help()}, &render_help/1}
      ["help"] -> {:ok, %{help: help()}, &render_help/1}
      [other | _] -> {:error, Error.new(:usage, "unknown workspace command: #{other}")}
    end
  end

  defp new(global, args) do
    with {:ok, opts, rest} <- Helpers.parse(args, new_strict()),
         {:ok, name} <- one_arg(rest, "gitspace workspace new <name> [--own repo]..."),
         {:ok, owned} <- specs(Keyword.get_values(opts, :own), "owned"),
         {:ok, borrowed} <- specs(Keyword.get_values(opts, :borrow), "borrowed"),
         {:ok, owned, borrowed} <-
           apply_member_aliases(owned, borrowed, Keyword.get_values(opts, :as)),
         {:ok, config} <- Helpers.load_config(),
         :ok <- Helpers.start_index(config) do
      create_opts =
        [
          branch: opts[:branch],
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

  defp specs(values, ownership) do
    Enum.reduce_while(values, {:ok, []}, fn value, {:ok, acc} ->
      case split_spec(value) do
        {:ok, repo, ref} ->
          branch_mode = if is_nil(ref), do: :derive, else: :ref
          spec = %{repo: repo, ref: ref, ownership: ownership, branch_mode: branch_mode}
          {:cont, {:ok, acc ++ [spec]}}

        {:error, error} ->
          {:halt, {:error, error}}
      end
    end)
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
        |> Enum.map(&workspace_map/1)

      {:ok, %{workspaces: workspaces}, &render_list/1}
    end
  end

  defp ls_strict do
    [label: :string, active: :boolean, torn_down: :boolean, all: :boolean] ++
      Helpers.global_strict()
  end

  defp filter_label(workspaces, nil), do: workspaces

  defp filter_label(workspaces, label) do
    Enum.filter(workspaces, fn workspace ->
      Enum.any?(workspace.labels, &(&1.label == label))
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

  defp render_help(%{help: help}), do: IO.puts(help)

  @doc false
  def help do
    """
    USAGE
      gitspace workspace new <name> [--own <repo>[@<ref>]]... [--borrow <repo>[@<ref>]]...
                                    [--branch B] [--label L]... [--description D]
                                    [--as <repo>=<dir>]... [--fetch] [--dry-run] [--json]
      gitspace workspace ls [--label L] [--all] [--json]
      gitspace workspace status <name> [--refresh] [--json]

    OWNED MEMBERS
      The branch defaults to feature_<name> (configurable). --branch overrides it.
      An explicit @ref opts out of branch derivation and checks out that ref as-is.

    BORROWED MEMBERS
      An existing checkout, referenced but never moved, branched or deleted.
      With several checkouts for one repository, select one with repo@ref.

    MEMBER DIRECTORIES
      Top-level by default. Use --as repo=name to choose a member directory.
      Names are immutable once the member exists.
    """
  end
end
