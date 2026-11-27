defmodule Gitspace.CLI.Co do
  @moduledoc false

  alias Gitspace.{Create, Error}
  alias Gitspace.CLI.{Helpers, Output, Prompt}

  def run(global, args) do
    with {:ok, opts, rest} <- Helpers.parse(args, strict()),
         {:ok, target} <- one_arg(rest, "gitspace co <project>[@<ref>]"),
         {:ok, project, ref} <- split_target(target),
         {:ok, config} <- Helpers.load_config(),
         :ok <- Helpers.start_index(config) do
      create_opts = [
        topic: opts[:topic],
        only: Keyword.get_values(opts, :only),
        exclude: Keyword.get_values(opts, :exclude),
        as: opts[:as],
        as_is: opts[:as_is],
        branch: opts[:branch],
        detach: opts[:detach],
        labels: Keyword.get_values(opts, :label),
        fetch: opts[:fetch],
        created_by: "co",
        on_occupied: occupied_handler(global)
      ]

      case Create.co(config, project, ref, create_opts) do
        {:ok, result} ->
          {:ok, co_data(result, ref), &render/1}

        {:partial, result, failures} ->
          {:partial, co_data(result, ref), &render/1, partial_error(result, failures)}

        {:error, error} ->
          {:error, error}
      end
    end
  end

  defp strict do
    [
      topic: :string,
      only: :keep,
      exclude: :keep,
      as: :string,
      as_is: :boolean,
      branch: :string,
      detach: :boolean,
      label: :keep,
      fetch: :boolean
    ] ++ Helpers.global_strict()
  end

  defp occupied_handler(global) do
    if not global.json and Output.tty?() do
      &Prompt.occupied/1
    end
  end

  defp split_target(target) do
    case String.split(target, "@", parts: 2) do
      [project] when project != "" ->
        {:ok, project, nil}

      [project, ref] when project != "" and ref != "" ->
        {:ok, project, ref}

      _ ->
        {:error,
         Error.new(:usage, "usage: gitspace co <project>[@<ref>]",
           hint:
             "for example: gitspace co vemags --topic MT4711 (defaults) or gitspace co vemags@main --topic MT4711"
         )}
    end
  end

  defp one_arg([arg], _usage), do: {:ok, arg}
  defp one_arg(_rest, usage), do: {:error, Error.new(:usage, "usage: #{usage}")}

  defp co_data(result, ref) do
    first =
      case result.members do
        [member | _] -> member
        [] -> %{}
      end

    %{
      project: result.project,
      topic: result.topic,
      workspace: result.workspace,
      work: result.workspace,
      path: result.path,
      marker: result.marker_path,
      ref: ref,
      labels: result.labels,
      members: Enum.map(result.members, &member_map/1),
      name: first[:name],
      repo: first[:repo],
      head: first[:head],
      branch: first[:branch],
      detached: first[:detached],
      ownership: first[:ownership],
      reused:
        result.members != [] and
          Enum.all?(result.members, &(&1.action in ["reused", "kept"]))
    }
  end

  defp member_map(member) do
    %{
      repo: member[:repo],
      name: member[:name],
      path: member[:path],
      branch: member[:branch],
      detached: member[:detached],
      ref: member[:ref],
      head: member[:head],
      ownership: member[:ownership],
      action: member[:action]
    }
  end

  defp partial_error(result, failures) do
    total = length(result.members) + length(failures)
    failed = length(failures)
    names = failures |> Enum.map(& &1.repo) |> Enum.uniq() |> Enum.join(", ")

    Error.new(
      :partial,
      "#{result.workspace} created partially: #{failed} of #{total} member(s) failed: #{names}",
      hint: "fix the reported member and re-run; existing members are untouched",
      details: Map.put(result, :failures, Enum.map(failures, &Map.drop(&1, [:error])))
    )
  end

  defp render(data) do
    action =
      cond do
        data.reused -> "already checked out"
        Enum.all?(data.members, &(&1.action == "created")) -> "created"
        true -> "updated"
      end

    IO.puts("#{action}: #{data.path}")
    IO.puts("  project:  #{data.project}")
    IO.puts("  topic:    #{data.topic}")
    IO.puts("  ref:      #{data.ref || "(each repository default)"}")

    IO.puts("  labels:   #{if data.labels == [], do: "-", else: Enum.join(data.labels, ", ")}")

    IO.puts("")

    Output.table(
      ["ACTION", "MEMBER", "BRANCH", "PATH"],
      Enum.map(data.members, fn member ->
        [
          member.action,
          member.name || member.repo,
          member.branch || "(detached)",
          member.path
        ]
      end)
    )
  end
end
