defmodule Gitspace.CLI.Label do
  @moduledoc false

  alias Gitspace.{Error, Workspaces}
  alias Gitspace.CLI.Helpers

  def run(_global, args) do
    case args do
      ["add" | rest] -> change(:add, rest)
      ["rm" | rest] -> change(:remove, rest)
      ["set" | rest] -> change(:set, rest)
      ["ls" | rest] -> list(rest)
      [] -> {:ok, %{help: help()}, &render_help/1}
      ["help"] -> {:ok, %{help: help()}, &render_help/1}
      [other | _] -> {:error, Error.new(:usage, "unknown label command: #{other}")}
    end
  end

  defp change(action, args) do
    with {:ok, _opts, rest} <- Helpers.parse(args, Helpers.global_strict()),
         {:ok, workspace, labels} <- target_and_labels(rest, action),
         {:ok, config} <- Helpers.load_config(),
         :ok <- Helpers.start_index(config),
         {:ok, result} <- Workspaces.label(config, workspace, action, labels) do
      {:ok, result, &render_labels/1}
    end
  end

  defp list(args) do
    with {:ok, _opts, rest} <- Helpers.parse(args, Helpers.global_strict()),
         {:ok, workspace} <- one_arg(rest, "gitspace workspace label ls <workspace>"),
         {:ok, config} <- Helpers.load_config(),
         :ok <- Helpers.start_index(config),
         {:ok, workspace} <- Workspaces.get(config, workspace) do
      labels = Enum.map(workspace.labels, & &1.label)

      {:ok,
       %{
         workspace: workspace.name,
         labels: labels,
         description: workspace.description,
         marker_path: workspace.marker_path
       }, &render_labels/1}
    end
  end

  defp target_and_labels([workspace | labels], :set) when workspace != "" do
    if Enum.any?(labels, &(&1 == "")) do
      {:error, Error.new(:usage, "labels cannot be empty")}
    else
      {:ok, workspace, labels}
    end
  end

  defp target_and_labels([workspace | labels], _action)
       when workspace != "" and labels != [] do
    if Enum.any?(labels, &(&1 == "")) do
      {:error, Error.new(:usage, "labels cannot be empty")}
    else
      {:ok, workspace, labels}
    end
  end

  defp target_and_labels(_rest, _action) do
    {:error,
     Error.new(:usage, "usage: gitspace workspace label add|rm <workspace> <label>...",
       details: %{}
     )}
  end

  defp one_arg([arg], _usage) when arg != "", do: {:ok, arg}
  defp one_arg(_rest, usage), do: {:error, Error.new(:usage, "usage: #{usage}")}

  defp render_labels(data) do
    IO.puts("labels #{data.workspace}")

    if data.labels == [] do
      IO.puts("  (none)")
    else
      Enum.each(data.labels, &IO.puts("  #{&1}"))
    end
  end

  defp render_help(%{help: help}), do: IO.puts(help)

  @doc false
  def help do
    """
    USAGE
      gitspace workspace label add <workspace> <label>...
      gitspace workspace label rm <workspace> <label>...
      gitspace workspace label set <workspace> [<label>...]
      gitspace workspace label ls <workspace>

    Labels belong to workspaces. `add` is a union, `rm` removes individual
    labels, `set` replaces the whole set (without labels it clears them).
    The workspace marker is written first, so labels survive an index rebuild.

    EXAMPLES
      gitspace workspace label add vemags@4711 jira-123 review
      gitspace workspace label rm vemags@4711 review
      gitspace workspace label set vemags@4711 jira-123
      gitspace workspace label set vemags@4711
    """
  end
end
