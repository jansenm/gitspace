defmodule Gitspace.CLI.Co do
  @moduledoc false

  alias Gitspace.{Create, Error}
  alias Gitspace.CLI.{Helpers, Output, Prompt}

  def run(global, args) do
    with {:ok, opts, rest} <- Helpers.parse(args, strict()),
         {:ok, target} <- one_arg(rest, "gitspace co <repo>@<ref>"),
         {:ok, repo, ref} <- split_target(target),
         {:ok, config} <- Helpers.load_config(),
         :ok <- Helpers.start_index(config) do
      create_opts = [
        name: opts[:name],
        branch: opts[:branch],
        detach: opts[:detach],
        labels: Keyword.get_values(opts, :label),
        fetch: opts[:fetch],
        created_by: "co",
        on_occupied: occupied_handler(global)
      ]

      case Create.co(config, repo, ref, create_opts) do
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
      name: :string,
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
      [repo, ref] when repo != "" and ref != "" ->
        {:ok, repo, ref}

      _ ->
        {:error,
         Error.new(:usage, "usage: gitspace co <repo>@<ref>",
           hint: "for example: gitspace co api@hotfix/timeout"
         )}
    end
  end

  defp one_arg([arg], _usage), do: {:ok, arg}
  defp one_arg(_rest, usage), do: {:error, Error.new(:usage, "usage: #{usage}")}

  defp co_data(result, ref) do
    member =
      case result.members do
        [member | _] -> member
        [] -> %{}
      end

    %{
      work: result.workspace,
      path: member[:path],
      repo: member[:repo],
      ref: ref,
      head: member[:head],
      branch: member[:branch],
      detached: member[:detached],
      ownership: member[:ownership],
      labels: result.labels,
      reused: member[:action] == "reused",
      marker: result.marker_path
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
        data.detached -> "created detached"
        true -> "created"
      end

    IO.puts("#{action}: #{data.path}")
    IO.puts("  work:     #{data.work}")
    IO.puts("  repo:     #{data.repo}")
    IO.puts("  ref:      #{data.ref}")
    IO.puts("  branch:   #{data.branch || "(detached)"}")

    if data.head do
      IO.puts("  head:     #{String.slice(data.head, 0, 12)}")
    end

    IO.puts("  labels:   #{if data.labels == [], do: "-", else: Enum.join(data.labels, ", ")}")

    if data.ownership == "borrowed" do
      IO.puts("  borrowed: the existing checkout was kept in place")
    end
  end
end
