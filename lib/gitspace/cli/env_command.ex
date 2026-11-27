defmodule Gitspace.CLI.EnvCommand do
  @moduledoc false

  import Gitspace.CLI.Output, only: [table: 2]

  alias Gitspace.{Env, Error}
  alias Gitspace.CLI.Helpers

  def run(global, args) do
    with {:ok, opts, rest} <- Helpers.parse(args, strict()),
         :ok <- validate(opts, global),
         {:ok, target} <- target(rest),
         {:ok, config} <- Helpers.load_config(),
         :ok <- Helpers.start_index(config),
         {:ok, resolved} <- Env.resolve(config, target) do
      data =
        resolved
        |> Map.put(:mode, mode(opts))
        |> Map.update!(:entries, fn entries ->
          if !!opts[:values] or !!opts[:shell] do
            entries
          else
            Enum.map(entries, &Map.drop(&1, [:value]))
          end
        end)

      {:ok, data, &render/1}
    end
  end

  defp strict, do: [values: :boolean, shell: :boolean] ++ Helpers.global_strict()

  defp validate(opts, global) do
    cond do
      !!opts[:values] and !!opts[:shell] ->
        {:error, Error.new(:usage, "--values and --shell are mutually exclusive")}

      opts[:shell] && global.json ->
        {:error, Error.new(:usage, "--shell cannot be combined with --json")}

      true ->
        :ok
    end
  end

  defp target([]), do: {:ok, "."}
  defp target([target]), do: {:ok, target}
  defp target(_rest), do: {:error, Error.new(:usage, "usage: gitspace env [target]")}

  defp mode(opts) do
    cond do
      opts[:shell] -> :shell
      opts[:values] -> :values
      true -> :keys
    end
  end

  defp render(%{mode: :shell, entries: entries}) do
    Enum.each(entries, fn entry ->
      IO.puts("export #{entry.key}=#{shell_quote(entry.value)}")
    end)
  end

  defp render(%{mode: :values, entries: entries}) do
    if entries == [] do
      IO.puts("(no variables)")
    else
      table(
        ["KEY", "VALUE", "SOURCE"],
        Enum.map(entries, fn entry -> [entry.key, entry.value, entry.source] end)
      )
    end
  end

  defp render(%{entries: entries}) do
    if entries == [] do
      IO.puts("(no variables)")
    else
      table(["KEY", "SOURCE"], Enum.map(entries, fn entry -> [entry.key, entry.source] end))
    end
  end

  defp shell_quote(value) do
    "'" <> String.replace(value, "'", "'\\''") <> "'"
  end
end
