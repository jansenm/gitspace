defmodule Gitspace.Git do
  @moduledoc """
  Runs git with a sanitized environment and separate stdout/stderr.

  The environment is inherited, but every variable that can redirect a git
  command to a different repository is removed with `env -u`. This is
  deliberately not done by mutating the VM environment: the CLI may later be
  embedded in a server, and per-call isolation is the correct boundary.
  """

  defmodule Error do
    defexception [:message, :result]

    @impl true
    def exception(opts) do
      result = Keyword.fetch!(opts, :result)

      message =
        "git #{Enum.join(result.argv, " ")} failed with exit #{inspect(result.exit)}: " <>
          String.trim(result.stderr)

      %__MODULE__{message: message, result: result}
    end
  end

  # Variables that silently redirect git away from the repository we intend.
  @scrub ~w(
    GIT_DIR
    GIT_WORK_TREE
    GIT_INDEX_FILE
    GIT_COMMON_DIR
    GIT_OBJECT_DIRECTORY
    GIT_ALTERNATE_OBJECT_DIRECTORIES
    GIT_CEILING_DIRECTORIES
    GIT_PREFIX
    GIT_NAMESPACE
    GIT_CONFIG_COUNT
  )

  @type result :: %{
          argv: [String.t()],
          stdout: binary(),
          stderr: binary(),
          exit: non_neg_integer() | :epipe
        }

  @spec run([String.t()], keyword()) :: {:ok, result()} | {:error, result()}
  def run(args, opts \\ []) when is_list(args) do
    cwd = Keyword.get(opts, :cd, File.cwd!())
    timeout = Keyword.get(opts, :timeout, 60_000)
    extra_env = Keyword.get(opts, :env, [])
    locks? = Keyword.get(opts, :locks, false)

    command = build_command(args, extra_env, locks?)

    if Application.get_env(:gitspace, :verbose, false) do
      IO.puts(:stderr, "$ (cd #{cwd} && #{Enum.join(command, " ")})")
    end

    try do
      {out, err, status} =
        command
        |> Exile.stream(stderr: :consume, cd: cwd, exit_timeout: timeout)
        |> Enum.reduce({[], [], 0}, fn
          {:stdout, data}, {out, err, _} -> {[out, data], err, 0}
          {:stderr, data}, {out, err, _} -> {out, [err, data], 0}
          {:exit, {:status, code}}, {out, err, _} -> {out, err, code}
          {:exit, :epipe}, {out, err, _} -> {out, err, :epipe}
        end)

      result = %{
        argv: args,
        stdout: IO.iodata_to_binary(out),
        stderr: IO.iodata_to_binary(err),
        exit: status
      }

      if status == 0, do: {:ok, result}, else: {:error, result}
    rescue
      error in Exile.Process.Error ->
        {:error, %{argv: args, stdout: "", stderr: Exception.message(error), exit: 127}}
    end
  end

  @spec run!([String.t()], keyword()) :: binary()
  def run!(args, opts \\ []) do
    case run(args, opts) do
      {:ok, %{stdout: stdout}} -> stdout
      {:error, result} -> raise Error, result: result
    end
  end

  defp build_command(args, extra_env, locks?) do
    env_bin = System.find_executable("env") || "/usr/bin/env"

    scrub = Enum.flat_map(@scrub, &["-u", &1])

    assignments =
      ["LC_ALL=C", "GIT_TERMINAL_PROMPT=0", "GIT_PAGER=cat"] ++
        if(locks?, do: [], else: ["GIT_OPTIONAL_LOCKS=0"]) ++
        format_env(extra_env)

    [env_bin] ++
      scrub ++
      assignments ++
      ["git", "--no-pager", "-c", "core.quotepath=false", "-c", "color.ui=false"] ++ args
  end

  defp format_env(env) when is_map(env),
    do: Enum.map(env, fn {key, value} -> "#{key}=#{value}" end)

  defp format_env(env) when is_list(env),
    do: Enum.map(env, fn {key, value} -> "#{key}=#{value}" end)
end
