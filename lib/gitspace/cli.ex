defmodule Gitspace.CLI do
  @moduledoc "Command dispatcher, global flags, help and exit codes."

  alias Gitspace.Error

  alias Gitspace.CLI.{
    Completion,
    Config,
    Co,
    Doctor,
    Inventory,
    Keep,
    Log,
    Output,
    Project,
    Push,
    Rebase,
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
    after
      # Completion snapshots are invalidated by mutations only. Reads such as
      # `ls` or `status` must not wake the shell cache.
      unless read_only?(args), do: Completion.touch()
    end
  end

  defp read_only?(args) do
    case command_name(args) do
      nil ->
        true

      command when command in ~w(ls log status show path help completion __complete version) ->
        true

      "config" ->
        subcommand(args) != "set"

      "doctor" ->
        not Enum.any?(args, &(&1 in ["--fix", "--reindex"]))

      "repo" ->
        subcommand(args) in ["ls", "fetch"]

      "workspace" ->
        subcommand(args) in ["ls", "status"]

      "project" ->
        subcommand(args) in ["ls", "show"]

      "keep" ->
        subcommand(args) == "ls"

      _ ->
        false
    end
  end

  defp subcommand(args) do
    args
    |> Enum.drop_while(&String.starts_with?(&1, "-"))
    |> Enum.drop(1)
    |> Enum.reject(&String.starts_with?(&1, "-"))
    |> List.first()
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

        "log" ->
          Log.run(global, command_args)

        "keep" ->
          Keep.run(global, command_args)

        "push" ->
          Push.run(global, command_args)

        "rebase" ->
          Rebase.run(global, command_args)

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
      log <target>                 outgoing and incoming commits
      keep ls|prune                list and prune refs/gitspace/keep anchors
      push <target>                push the checked-out branch
      rebase [target]              rebase worktrees onto their upstream
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
                      [--kind worktree|clone] [--source managed|external]
                      [--refresh] [--verbose]

        --verbose (or the old --wide) adds HASH and MIRROR to the table.
        --refresh recomputes the cached git status of the listed checkouts
        (no fetch).
        """

      "status" ->
        """
        USAGE
          gitspace status [target] [--refresh]
          gitspace status workspace:member
          gitspace status <workspace:member|checkout> --long [--diff] [--diff-lines N]

        --long lists the changed and untracked paths. --diff adds the staged and
        unstaged patch and implies --long. -l and -v are short for --long and
        --diff. Both need a single member or checkout target.

        --refresh recomputes git status; with no target it refreshes every
        indexed checkout before rendering the inbox. It never fetches.

        A checkout with a merge, rebase, cherry-pick or revert in progress
        reports it as `operation:`. `ls` and the inbox include it in the risk
        reasons.
        """

      "keep" ->
        Keep.help()

      "rebase" ->
        """
        USAGE
          gitspace rebase [<workspace|workspace:member|checkout>] [--fetch]
          gitspace rebase [<target>] --continue
          gitspace rebase [<target>] --abort [--yes]

        Without a target every managed worktree is considered. Each worktree
        is rebased onto its upstream independently; a conflict is reported and
        left in place while the remaining worktrees are still attempted.
        --continue and --abort operate on one target, or on every worktree with
        a rebase in progress when no target is given. --abort also rolls back
        completed rebases from the last batch (recorded in <data>/rebase.json),
        but only while HEAD still matches the rebased head and the working tree
        is clean. --fetch updates the mirrors before starting. Rebases require a
        clean tree, an attached branch and an upstream that exists (push the
        branch first).
        """

      "push" ->
        """
        USAGE
          gitspace push <workspace|workspace:member|checkout>
                       [--dry-run] [--remote NAME]

        Pushes the checked-out branch to the same-named branch on the remote
        (origin, the configured upstream's remote, or --remote). A branch that
        tracks a differently named upstream is never pushed to that upstream;
        the tracking is updated to the pushed branch. Borrowed members are
        skipped; detached checkouts and checkouts without a remote are refused.
        No force option exists.
        """

      "log" ->
        """
        USAGE
          gitspace log <workspace|workspace:member|checkout|repo>
                      [--outgoing|--incoming|--both] [--limit N|--all] [--fetch]

        Shows commits between the checkout and its upstream. outgoing is what a
        push would send; incoming is what a rebase or pull would integrate.
        Without an upstream, outgoing means "not on any remote or tag" and
        incoming compares with origin/<default> when that ref exists.

        The default limit is log.max_commits (10) per direction and member;
        --limit overrides it and --all shows everything. --fetch updates the
        mirror first, so incoming reflects the current upstream.
        """

      "co" ->
        """
        USAGE
          gitspace co <project>[@<ref>] [--topic T] [--only M,...] [--exclude M,...]
                                      [--as-is] [--branch B] [--detach]
                                      [--as DIR] [--label L]... [--fetch] [--json]

        @<ref> is the starting point. Without an explicit --topic/--name the
        ref is checked out as-is. A topic together with a ref derives an owned
        branch from the template (default feature/{topic}); a topic without a
        ref checks out each repository's default branch as-is. --branch creates
        that explicit branch instead. --as-is checks the ref or default out
        unchanged; --detach checks it out without a branch.

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
          gitspace repo init <name> [--branch B] [--topic T] [--path P]
          gitspace repo import <path> [--name N] [--no-link]
          gitspace repo add <url-or-path> [--name N] [--remote NAME] [--project P] [--no-fetch]
          gitspace repo ls
          gitspace repo fetch [<repo>|--all] [--prune]
          gitspace repo rm <repo> [--force] [--dry-run] [--yes]
          gitspace repo alias <repo> <name>
          gitspace repo set-url <repo> <url> [--push]

        `repo init` creates an empty local repository with its first checkout;
        `repo import` adopts an existing clone without a remote.
        `set-url` changes the fetch URL, or the push URL with `--push`; the
        repository keeps its identity and mirror directory.
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
          log.max_commits
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
