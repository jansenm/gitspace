defmodule Gitspace.CLI.ShellCommand do
  @moduledoc false

  alias Gitspace.{Env, Error}
  alias Gitspace.CLI.{Helpers, Terminal}

  def run(global, args) do
    with :ok <- reject_json(global),
         {:ok, opts, rest} <- Helpers.parse(args, strict(), c: :command),
         {:ok, target} <- target(rest),
         {:ok, config} <- Helpers.load_config(),
         :ok <- Helpers.start_index(config),
         {:ok, resolved} <- Env.resolve(config, target, no_env: !!opts[:no_env]) do
      shell = opts[:shell] || System.get_env("SHELL") || "/bin/sh"
      env = child_env(resolved.entries)
      shell_args = if is_binary(opts[:command]), do: ["-c", opts[:command]], else: []

      case Terminal.run(shell, shell_args, env: env, cd: resolved.path) do
        {:ok, status} ->
          {:exit, status}

        {:error, {:not_found, executable}} ->
          {:error, Error.new(:error, "shell not found: #{executable}")}

        {:error, error} ->
          {:error, Error.new(:error, "cannot start shell", hint: inspect(error))}
      end
    end
  end

  defp strict do
    [command: :string, shell: :string, no_env: :boolean] ++ Helpers.global_strict()
  end

  defp target([]), do: {:ok, "."}
  defp target([target]), do: {:ok, target}

  defp target(_rest) do
    {:error,
     Error.new(:usage, "usage: gitspace shell [target] [-c COMMAND] [--shell PATH] [--no-env]")}
  end

  defp child_env(entries) do
    overrides = Map.new(entries, fn entry -> {entry.key, entry.value} end)
    Map.merge(System.get_env(), overrides)
  end

  defp reject_json(%{json: true}) do
    {:error, Error.new(:usage, "--json is not supported for shell")}
  end

  defp reject_json(_global), do: :ok
end
