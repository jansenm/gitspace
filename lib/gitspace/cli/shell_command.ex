defmodule Gitspace.CLI.ShellCommand do
  @moduledoc false

  alias Gitspace.{Env, Error}
  alias Gitspace.CLI.{Helpers, Output, Terminal}

  def run(global, args) do
    with :ok <- reject_json(global),
         {:ok, opts, rest} <- Helpers.parse(args, strict(), c: :command),
         {:ok, target} <- target(rest),
         {:ok, config} <- Helpers.load_config(),
         :ok <- Helpers.start_index(config),
         {:ok, resolved} <- Env.resolve(config, target, no_env: !!opts[:no_env]) do
      shell = shell_path(opts)
      env = child_env(resolved.entries)
      run_shell(shell, opts[:command], env, resolved.path)
    end
  end

  defp run_shell(shell, command, env, path) when is_binary(command) do
    run_child(shell, ["-c", command], env, path)
  end

  defp run_shell(shell, _command, env, path) do
    cond do
      not Output.tty?() ->
        {:error,
         Error.new(:refused, "an interactive shell needs a terminal",
           hint: "use `gitspace shell -c COMMAND`"
         )}

      System.find_executable("script") == nil ->
        {:error,
         Error.new(:error, "an interactive shell needs script(1)",
           hint: "install util-linux or use `gitspace shell -c COMMAND`"
         )}

      true ->
        # Port children get their own session without a controlling terminal,
        # so bash refuses job control. script(1) allocates a PTY and runs the
        # shell as its foreground session.
        run_child("script", ["-qef", "/dev/null", "--", shell], env, path)
    end
  end

  defp run_child(executable, args, env, path) do
    case Terminal.run(executable, args, env: env, cd: path) do
      {:ok, status} ->
        {:exit, status}

      {:error, {:not_found, executable}} ->
        {:error, Error.new(:error, "shell not found: #{executable}")}

      {:error, error} ->
        {:error, Error.new(:error, "cannot start shell", hint: inspect(error))}
    end
  end

  defp shell_path(opts) do
    [opts[:shell], System.get_env("SHELL"), "/bin/sh"]
    |> Enum.find(fn value -> is_binary(value) and value != "" end)
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
