defmodule Gitspace.CLI.Terminal do
  @moduledoc """
  Runs an interactive child process with the terminal inherited.

  `System.cmd/3` connects the child through pipes, which breaks editors and
  interactive shells. `:nouse_stdio` leaves file descriptors 0/1/2 attached to
  the terminal, so the child is a real foreground process.
  """

  @spec run(Path.t(), [String.t()], keyword()) :: {:ok, non_neg_integer()} | {:error, term()}
  def run(executable, args, opts \\ []) do
    executable =
      case System.find_executable(executable) do
        nil -> executable
        path -> path
      end

    if File.exists?(executable) do
      port_opts = [
        :nouse_stdio,
        :exit_status,
        {:args, Enum.map(args, &to_charlist/1)}
      ]

      port_opts =
        case opts[:cd] do
          nil -> port_opts
          dir -> [{:cd, to_charlist(dir)} | port_opts]
        end

      port_opts =
        case env(opts[:env]) do
          [] -> port_opts
          env -> [{:env, env} | port_opts]
        end

      try do
        port = Port.open({:spawn_executable, to_charlist(executable)}, port_opts)
        wait(port)
      rescue
        error -> {:error, error}
      end
    else
      {:error, {:not_found, executable}}
    end
  end

  defp wait(port) do
    receive do
      {^port, {:exit_status, status}} -> {:ok, status}
      {^port, _other} -> wait(port)
    end
  end

  defp env(nil), do: []

  defp env(env) when is_map(env) do
    env
    |> Enum.map(fn {key, value} -> {to_charlist(key), to_charlist(value)} end)
  end

  defp env(env) when is_list(env) do
    Enum.map(env, fn {key, value} -> {to_charlist(key), to_charlist(value)} end)
  end
end
