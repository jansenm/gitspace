defmodule Gitspace.CLI do
  @moduledoc "Command dispatcher, global flags, help and exit codes."

  alias Gitspace.Error

  alias Gitspace.CLI.{
    Completion,
    Config,
    Co,
    Doctor,
    Inventory,
    Output,
    Project,
    Reindex,
    Repo,
    Scan,
    Setup,
    Workspace
  }

  @global_flags ~w(--json --no-color --verbose --yes --help --version -h)

  def main(args) do
    args = Enum.map(args, &to_string/1)
    Logger.configure(level: :warning)
    global = global(args)
    code = run(args, global)
    System.halt(code)
  end

  @doc "Runs one command and returns its exit code. Used by tests."
  def run(args, global \\ nil) do
    args = Enum.map(args, &to_string/1)
    global = global || global(args)

    Application.put_env(
      :gitspace,
      :verbose,
      global.verbose and command_name(args) != "ls"
    )

    try do
      args
      |> dispatch(global)
      |> Output.emit(global)
    rescue
      error in Error ->
        Output.emit({:error, error}, global)

      error ->
        message =
          if global.verbose do
            Exception.format(:error, error, __STACKTRACE__)
          else
            Exception.message(error)
          end

        Output.emit({:error, Error.new(:error, message)}, global)
    end
  end

  defp dispatch(args, global) do
    cond do
      "--version" in args ->
        version()

      args == [] ->
        Inventory.inbox(global, [])

      true ->
        {before, rest} = Enum.split_while(args, &String.starts_with?(&1, "-"))

        case Enum.reject(before, &(&1 in @global_flags)) do
          [] -> dispatch_command(rest, before, global)
          [unknown | _] -> {:error, Error.new(:usage, "unknown option: #{unknown}")}
        end
    end
  end

  defp dispatch_command([], before, global) do
    if "--help" in before or "-h" in before do
      help()
    else
      Inventory.inbox(global, [])
    end
  end

  defp dispatch_command([command | command_args], before, global) do
    if "--help" in command_args or "-h" in command_args or "--help" in before do
      help(command)
    else
      case command do
        "ls" ->
          Inventory.ls(global, command_args)

        "co" ->
          Co.run(global, command_args)

        "workspace" ->
          Workspace.run(global, command_args)

        "project" ->
          Project.run(global, command_args)

        "status" ->
          Inventory.status(global, command_args)

        "show" ->
          Inventory.show(global, command_args)

        "path" ->
          Inventory.path(global, command_args)

        "repo" ->
          Repo.run(global, command_args)

        "scan" ->
          Scan.scan(global, command_args)

        "link" ->
          Scan.link(global, command_args)

        "unlink" ->
          Scan.unlink(global, command_args)

        "doctor" ->
          Doctor.run(global, command_args)

        "setup" ->
          Setup.run(global, command_args)

        "reindex" ->
          Reindex.run(global, command_args)

        "config" ->
          Config.run(global, command_args)

        "completion" ->
          Completion.run(global, command_args)

        "__complete" ->
          Completion.complete(command_args)

        "help" ->
          help()

        other ->
          {:error, Error.new(:usage, "unknown command: #{other}", hint: "run `gitspace help`")}
      end
    end
  end

  defp global(args) do
    %{
      json: "--json" in args,
      no_color: "--no-color" in args,
      verbose: "--verbose" in args,
      yes: "--yes" in args
    }
  end

  defp command_name(args) do
    args
    |> Enum.drop_while(&String.starts_with?(&1, "-"))
    |> List.first()
  end

  defp version do
    vsn =
      case Application.spec(:gitspace, :vsn) do
        nil -> "0.1.0"
        version -> to_string(version)
      end

    git =
      case Gitspace.Git.run(["version"]) do
        {:ok, %{stdout: out}} -> String.trim(out)
        _ -> "git unavailable"
      end

    {:ok, %{version: vsn, git: git},
     fn data -> IO.puts("gitspace #{data.version} (#{data.git})") end}
  end

  defp help, do: help(nil)

  defp help(nil) do
    {:ok, %{help: top_help()}, &render_help/1}
  end

  defp help(command) do
    {:ok, %{help: command_help(command)}, &render_help/1}
  end

  defp render_help(%{help: help}), do: IO.puts(help)

  defp top_help do
    """
    gitspace — workspaces for git checkouts

    USAGE
      gitspace                     inbox: what needs a decision
      gitspace <command> [options]

    COMMANDS
      ls                           all indexed checkouts
      co <project>[@<ref>]         check out a project topic
      workspace new|ls|status|rm   explicit workspace creation, inspection and removal
      project new|ls|show|add|remove|rm  project definitions
      status [target]              inbox, or one workspace/checkout/repository
      show <target>                details and provenance
      path <target>                print a checkout path
      repo add|ls|fetch|rm|alias|set-url  mirrors, aliases and remote URLs
      scan [path...]               discover existing clones and worktrees (read-only)
      link <path>                  index an external checkout
      unlink <path>                forget an external checkout
      doctor [--fix] [--reindex]   health checks
      config [list|get|set]        show or change the active configuration
      completion bash|zsh|fish     print a shell completion script
      setup                        choose data and projects directories
      reindex                      rebuild the index from git and markers

    GLOBAL
      --json --no-color --verbose --yes --help --version
    """
  end

  defp command_help(command) do
    case command do
      "ls" ->
        """
        USAGE
          gitspace ls [--repo R] [--workspace W] [--label L] [--state S]
                      [--kind worktree|clone] [--source managed|external] [--verbose]

        --verbose (or the old --wide) adds HASH and MIRROR to the table.
        """

      "status" ->
        """
        USAGE
          gitspace status [target] [--refresh]
          gitspace status workspace:member
        """

      "co" ->
        """
        USAGE
          gitspace co <project>[@<ref>] [--topic T] [--only M,...] [--exclude M,...]
                                      [--as-is] [--branch B] [--detach]
                                      [--as DIR] [--label L]... [--fetch] [--json]

        @<ref> is the starting point. Without an explicit --topic/--name the
        ref is checked out as-is. Naming a topic derives an owned branch from
        the template (default feature/{topic}); --branch creates that explicit
        branch instead. --as-is checks the ref out unchanged; --detach checks
        it out without a branch.

        --only and --exclude are mutually exclusive. By default every member
        of the project is checked out.

        EXAMPLES
          gitspace co ferroclass@main --topic dev
          gitspace co vemags@development --topic MT4711
          gitspace co vemags@development --topic MT4711 --only api,web
          gitspace co vemags@feature/MT4711 --topic MT4711 --exclude legacy
          gitspace co vemags@main --as-is --topic main
        """

      "project" ->
        Project.help()

      "workspace" ->
        Workspace.help()

      "show" ->
        """
        USAGE
          gitspace show <workspace|workspace:member|checkout|repo|path>
        """

      "path" ->
        """
        USAGE
          gitspace path <workspace|workspace:member|checkout|repo|path>
        """

      "repo" ->
        """
        USAGE
          gitspace repo add <url-or-path> [--name N] [--remote NAME] [--project P] [--no-fetch]
          gitspace repo ls
          gitspace repo fetch [<repo>|--all] [--prune]
          gitspace repo rm <repo> [--force] [--dry-run] [--yes]
          gitspace repo alias <repo> <name>
          gitspace repo set-url <repo> <url> [--push]

        `set-url` changes the fetch URL, or the push URL with `--push`.
        The new URL must resolve to the same canonical remote key.
        """

      "scan" ->
        """
        USAGE
          gitspace scan [path...] [--max-depth N] [--exclude GLOB]
        """

      "link" ->
        """
        USAGE
          gitspace link <path> [--repo NAME]
        """

      "unlink" ->
        """
        USAGE
          gitspace unlink <path>
        """

      "doctor" ->
        """
        USAGE
          gitspace doctor [--fix] [--reindex]
        """

      "config" ->
        """
        USAGE
          gitspace config [list]
          gitspace config get <key>
          gitspace config set <key> <value> [--force]

        KEYS
          paths.data
          projects.root
          branch.template
          git.minimum_version
          status.max_age_seconds
        """

      "completion" ->
        """
        USAGE
          gitspace completion bash
          gitspace completion zsh
          gitspace completion fish

        Bash:
          source <(gitspace completion bash)

        Zsh:
          gitspace completion zsh > "${fpath[1]}/_gitspace"

        Fish:
          gitspace completion fish | source
        """

      "setup" ->
        """
        USAGE
          gitspace setup [--data DIR] [--projects DIR] [--force]
        """

      "reindex" ->
        """
        USAGE
          gitspace reindex
        """

      _ ->
        top_help()
    end
  end
end
