defmodule Gitspace.CLI do
  @moduledoc "M0 CLI entrypoint. The full v1 surface arrives in M1+."

  def main(args) do
    case args do
      ["--version"] -> version()
      ["--help"] -> help()
      [] -> help()
      ["doctor"] -> doctor()
      other -> unknown(other)
    end
  end

  defp version do
    IO.puts("gitspace #{vsn()} (#{git_version()})")
    halt(0)
  end

  defp help do
    IO.puts("""
    gitspace — workspaces for git checkouts (M0 spike)

    USAGE
      gitspace --version
      gitspace doctor

    The full v1 CLI is not implemented yet. M0 proves the git and safety mechanics.
    """)

    halt(0)
  end

  defp doctor do
    IO.puts("gitspace      #{vsn()}")
    IO.puts("git           #{git_version()}")
    IO.puts("elixir        #{System.version()}")
    IO.puts("otp           #{System.otp_release()}")
    IO.puts("burrito       #{System.get_env("__BURRITO", "0")}")
    halt(0)
  end

  defp unknown(args) do
    IO.puts(:stderr, "unknown command: #{Enum.join(args, " ")}")
    IO.puts(:stderr, "run `gitspace --help`")
    halt(2)
  end

  defp vsn do
    case Application.spec(:gitspace, :vsn) do
      nil -> "0.1.0"
      version -> to_string(version)
    end
  end

  # Deliberately goes through Gitspace.Git: `doctor` then proves that the
  # subprocess layer (Exile + helper binaries) works in the packaged binary.
  defp git_version do
    case Gitspace.Git.run(["version"]) do
      {:ok, %{stdout: out}} -> String.trim(out)
      _ -> "unavailable"
    end
  end

  defp halt(code), do: System.halt(code)
end
