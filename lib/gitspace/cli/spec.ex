defmodule Gitspace.CLI.Spec do
  @moduledoc """
  Single source for the command surface.

  Help, completion and the manpage check derive names, aliases, subcommands and
  flags from this module. Prose help still lives next to the command
  implementation, but the structure must not be duplicated.
  """

  @type flag :: {atom(), :boolean | :string | :integer | :keep}
  @type subcommand :: %{
          name: String.t(),
          aliases: [String.t()],
          summary: String.t(),
          usage: [String.t()],
          flags: [flag()],
          subcommands: [t()],
          hidden: boolean()
        }
  @type t :: %{
          name: String.t(),
          aliases: [String.t()],
          group: atom(),
          summary: String.t(),
          usage: [String.t()],
          flags: [flag()],
          subcommands: [subcommand()],
          hidden: boolean()
        }

  @global_flags ~w(--json --no-color --verbose --yes --help --version -h)

  @shorts %{
    "ls" => "ls",
    "show" => "show <target>",
    "status" => "status <target>",
    "path" => "path <target>",
    "log" => "log <target>",
    "checkout" => "checkout <project>[@<ref>]",
    "push" => "push <target>",
    "rebase" => "rebase [target]",
    "base" => "base <target> [<ref>]",
    "workspace" => "workspace new|add|label|ls|edit|rm",
    "project" => "project new|ls|edit|add|remove|rm",
    "repo" => "repo init|import|add|ls|branches|fetch|rm|alias|set-url",
    "doctor" => "doctor check|fix|reindex|keep",
    "scan" => "scan [path...]",
    "link" => "link <path>",
    "unlink" => "unlink <path>",
    "setup" => "setup",
    "config" => "config list|get|set|export|import",
    "completion" => "completion bash|zsh|fish"
  }

  @commands [
    %{
      name: "ls",
      aliases: [],
      group: :inspect,
      summary: "indexed checkouts",
      usage: [
        "gitspace ls [--repo R] [--workspace W] [--project P] [--topic T]",
        "            [--label L] [--state S] [--kind K] [--source S]",
        "            [--refresh] [--verbose]"
      ],
      flags: [
        repo: :string,
        workspace: :string,
        project: :string,
        topic: :string,
        label: :string,
        state: :string,
        kind: :string,
        source: :string,
        verbose: :boolean,
        refresh: :boolean
      ],
      subcommands: [],
      hidden: false
    },
    %{
      name: "show",
      aliases: [],
      group: :inspect,
      summary: "identity and definition",
      usage: ["gitspace show <workspace|workspace:member|checkout|repo|project>"],
      flags: [],
      subcommands: [],
      hidden: false
    },
    %{
      name: "status",
      aliases: [],
      group: :inspect,
      summary: "live state, files and diffs",
      usage: [
        "gitspace status <target> [--refresh]",
        "gitspace status <workspace:member|checkout> --long [--diff] [--diff-lines N]"
      ],
      flags: [refresh: :boolean, long: :boolean, diff: :boolean, diff_lines: :integer],
      subcommands: [],
      hidden: false
    },
    %{
      name: "path",
      aliases: [],
      group: :inspect,
      summary: "print a checkout path",
      usage: ["gitspace path <workspace|workspace:member|checkout|repo|project>"],
      flags: [],
      subcommands: [],
      hidden: false
    },
    %{
      name: "log",
      aliases: [],
      group: :inspect,
      summary: "outgoing and incoming commits",
      usage: [
        "gitspace log <workspace|workspace:member|checkout|repo>",
        "            [--outgoing|--incoming|--both] [--limit N|--all] [--fetch]"
      ],
      flags: [
        outgoing: :boolean,
        incoming: :boolean,
        both: :boolean,
        limit: :integer,
        all: :boolean,
        fetch: :boolean
      ],
      subcommands: [],
      hidden: false
    },
    %{
      name: "checkout",
      aliases: ["co"],
      group: :work,
      summary: "check out a project topic (co = alias)",
      usage: [
        "gitspace checkout <project>[@<ref>] [--topic T] [--only M,...] [--exclude M,...]",
        "                              [--as-is] [--branch B] [--detach]",
        "                              [--as DIR] [--label L]... [--fetch] [--json]"
      ],
      flags: [
        topic: :string,
        only: :keep,
        exclude: :keep,
        as: :keep,
        as_is: :boolean,
        branch: :string,
        detach: :boolean,
        label: :keep,
        fetch: :boolean
      ],
      subcommands: [],
      hidden: false
    },
    %{
      name: "push",
      aliases: [],
      group: :work,
      summary: "push the checked-out branch",
      usage: [
        "gitspace push <workspace|workspace:member|checkout|repo>",
        "             [--dry-run] [--remote NAME] [--force|--force-with-lease]"
      ],
      flags: [
        dry_run: :boolean,
        remote: :string,
        force: :boolean,
        force_with_lease: :boolean
      ],
      subcommands: [],
      hidden: false
    },
    %{
      name: "rebase",
      aliases: [],
      group: :work,
      summary: "rebase worktrees onto their base",
      usage: [
        "gitspace rebase [<workspace|workspace:member|checkout|repo>] [--fetch]",
        "gitspace rebase [<target>] --continue",
        "gitspace rebase [<target>] --abort [--yes]"
      ],
      flags: [fetch: :boolean, continue: :boolean, abort: :boolean],
      subcommands: [],
      hidden: false
    },
    %{
      name: "base",
      aliases: [],
      group: :work,
      summary: "show or change the rebase base",
      usage: [
        "gitspace base <target>",
        "gitspace base <target> <ref>",
        "gitspace base <target> --clear"
      ],
      flags: [clear: :boolean],
      subcommands: [],
      hidden: false
    },
    %{
      name: "workspace",
      aliases: [],
      group: :workspace,
      summary: "workspaces, members and labels",
      usage: ["gitspace workspace <command> [options]"],
      flags: [],
      subcommands: [
        %{
          name: "new",
          aliases: [],
          summary: "create a workspace with explicit members",
          usage: [
            "gitspace workspace new [<project>@]<topic> [--own <repo>[@<ref>]]...",
            "    [--borrow <repo>[@<ref>]]... [--branch B] [--as-is]",
            "    [--label L]... [--description D] [--as <repo>=<dir>]...",
            "    [--fetch] [--dry-run] [--json]"
          ],
          flags: [
            own: :keep,
            borrow: :keep,
            as: :keep,
            branch: :string,
            as_is: :boolean,
            label: :keep,
            description: :string,
            fetch: :boolean,
            dry_run: :boolean
          ],
          subcommands: [],
          hidden: false
        },
        %{
          name: "add",
          aliases: [],
          summary: "add members to an existing workspace",
          usage: [
            "gitspace workspace add <workspace> [--own <repo>[@<ref>]]...",
            "    [--borrow <repo>[@<ref>]]... [--branch B] [--as-is]",
            "    [--as <repo>=<dir>]... [--fetch] [--dry-run] [--json]"
          ],
          flags: [
            own: :keep,
            borrow: :keep,
            as: :keep,
            branch: :string,
            as_is: :boolean,
            fetch: :boolean,
            dry_run: :boolean
          ],
          subcommands: [],
          hidden: false
        },
        %{
          name: "label",
          aliases: [],
          summary: "manage workspace labels",
          usage: [
            "gitspace workspace label add <workspace> <label>...",
            "gitspace workspace label rm <workspace> <label>...",
            "gitspace workspace label set <workspace> [<label>...]",
            "gitspace workspace label ls <workspace>"
          ],
          flags: [],
          subcommands: [
            %{
              name: "add",
              aliases: [],
              summary: "add labels",
              usage: [],
              flags: [],
              subcommands: [],
              hidden: false
            },
            %{
              name: "rm",
              aliases: [],
              summary: "remove labels",
              usage: [],
              flags: [],
              subcommands: [],
              hidden: false
            },
            %{
              name: "set",
              aliases: [],
              summary: "replace labels",
              usage: [],
              flags: [],
              subcommands: [],
              hidden: false
            },
            %{
              name: "ls",
              aliases: [],
              summary: "list labels",
              usage: [],
              flags: [],
              subcommands: [],
              hidden: false
            }
          ],
          hidden: false
        },
        %{
          name: "ls",
          aliases: [],
          summary: "list workspaces",
          usage: ["gitspace workspace ls [--project P] [--label L] [--all] [--json]"],
          flags: [project: :string, label: :string, all: :boolean],
          subcommands: [],
          hidden: false
        },
        %{
          name: "edit",
          aliases: [],
          summary: "change the description",
          usage: [
            "gitspace workspace edit <workspace> [--description D] [--clear-description]"
          ],
          flags: [description: :string, clear_description: :boolean],
          subcommands: [],
          hidden: false
        },
        %{
          name: "rm",
          aliases: [],
          summary: "remove a workspace or member",
          usage: [
            "gitspace workspace rm <workspace>[:<member>] [--force] [--delete-branch]",
            "    [--dry-run] [--yes] [--json]"
          ],
          flags: [force: :boolean, delete_branch: :boolean, dry_run: :boolean],
          subcommands: [],
          hidden: false
        },
        %{
          name: "status",
          aliases: [],
          summary: "hidden alias for status <workspace>",
          usage: ["gitspace workspace status <workspace> [--refresh] [--json]"],
          flags: [refresh: :boolean, long: :boolean, diff: :boolean, diff_lines: :integer],
          subcommands: [],
          hidden: true
        }
      ],
      hidden: false
    },
    %{
      name: "project",
      aliases: [],
      group: :project,
      summary: "project definitions",
      usage: ["gitspace project <command> [options]"],
      flags: [],
      subcommands: [
        %{
          name: "new",
          aliases: [],
          summary: "create a project",
          usage: [
            "gitspace project new <name> [--repo <alias>]... [--at <path>]",
            "    [--description D] [--branch-template T] [--default-ref REF]"
          ],
          flags: [
            repo: :keep,
            at: :string,
            description: :string,
            branch_template: :string,
            default_ref: :string
          ],
          subcommands: [],
          hidden: false
        },
        %{
          name: "ls",
          aliases: [],
          summary: "list projects",
          usage: ["gitspace project ls [--json]"],
          flags: [],
          subcommands: [],
          hidden: false
        },
        %{
          name: "edit",
          aliases: [],
          summary: "change the description",
          usage: [
            "gitspace project edit <name> [--description D] [--clear-description]"
          ],
          flags: [description: :string, clear_description: :boolean],
          subcommands: [],
          hidden: false
        },
        %{
          name: "add",
          aliases: [],
          summary: "add repositories",
          usage: ["gitspace project add <name> <repo>..."],
          flags: [],
          subcommands: [],
          hidden: false
        },
        %{
          name: "remove",
          aliases: [],
          summary: "remove repositories",
          usage: ["gitspace project remove <name> <repo>..."],
          flags: [],
          subcommands: [],
          hidden: false
        },
        %{
          name: "rm",
          aliases: [],
          summary: "remove the definition",
          usage: ["gitspace project rm <name> [--force]"],
          flags: [force: :boolean],
          subcommands: [],
          hidden: false
        },
        %{
          name: "show",
          aliases: [],
          summary: "hidden alias for show project:<name>",
          usage: ["gitspace project show <name> [--json]"],
          flags: [],
          subcommands: [],
          hidden: true
        }
      ],
      hidden: false
    },
    %{
      name: "repo",
      aliases: [],
      group: :repo,
      summary: "mirrors and repositories",
      usage: ["gitspace repo <command> [options]"],
      flags: [],
      subcommands: [
        %{
          name: "init",
          aliases: [],
          summary: "create an empty local repository",
          usage: ["gitspace repo init <name> [--branch B] [--topic T] [--path P]"],
          flags: [branch: :string, topic: :string, path: :string],
          subcommands: [],
          hidden: false
        },
        %{
          name: "import",
          aliases: [],
          summary: "adopt a local clone",
          usage: ["gitspace repo import <path> [--name N] [--no-link]"],
          flags: [name: :string, no_link: :boolean],
          subcommands: [],
          hidden: false
        },
        %{
          name: "add",
          aliases: [],
          summary: "register a remote-backed repository",
          usage: [
            "gitspace repo add <url-or-path> [--name N] [--remote NAME]",
            "    [--project P] [--no-fetch]"
          ],
          flags: [name: :string, remote: :string, project: :string, no_fetch: :boolean],
          subcommands: [],
          hidden: false
        },
        %{
          name: "ls",
          aliases: [],
          summary: "list repositories",
          usage: ["gitspace repo ls"],
          flags: [],
          subcommands: [],
          hidden: false
        },
        %{
          name: "branches",
          aliases: [],
          summary: "list branches and tags",
          usage: ["gitspace repo branches <repo> [--match GLOB|--regex RE] [--tags]"],
          flags: [match: :string, regex: :string, tags: :boolean],
          subcommands: [],
          hidden: false
        },
        %{
          name: "fetch",
          aliases: [],
          summary: "fetch a mirror or all mirrors",
          usage: ["gitspace repo fetch <repo>|--all"],
          flags: [all: :boolean],
          subcommands: [],
          hidden: false
        },
        %{
          name: "rm",
          aliases: [],
          summary: "remove a mirror",
          usage: ["gitspace repo rm <repo> [--force] [--dry-run] [--yes]"],
          flags: [force: :boolean, dry_run: :boolean],
          subcommands: [],
          hidden: false
        },
        %{
          name: "alias",
          aliases: [],
          summary: "change the alias",
          usage: ["gitspace repo alias <repo> <name>"],
          flags: [],
          subcommands: [],
          hidden: false
        },
        %{
          name: "set-url",
          aliases: [],
          summary: "change the fetch or push URL",
          usage: ["gitspace repo set-url <repo> <url> [--push]"],
          flags: [push: :boolean],
          subcommands: [],
          hidden: false
        }
      ],
      hidden: false
    },
    %{
      name: "doctor",
      aliases: [],
      group: :maintain,
      summary: "health, repair and index maintenance",
      usage: ["gitspace doctor [check|fix|reindex|keep] [options]"],
      flags: [],
      subcommands: [
        %{
          name: "check",
          aliases: [],
          summary: "check health",
          usage: ["gitspace doctor check"],
          flags: [],
          subcommands: [],
          hidden: false
        },
        %{
          name: "fix",
          aliases: [],
          summary: "repair problems",
          usage: ["gitspace doctor fix"],
          flags: [],
          subcommands: [],
          hidden: false
        },
        %{
          name: "reindex",
          aliases: [],
          summary: "rebuild the index",
          usage: ["gitspace doctor reindex"],
          flags: [],
          subcommands: [],
          hidden: false
        },
        %{
          name: "keep",
          aliases: [],
          summary: "inspect or prune keep refs",
          usage: [
            "gitspace doctor keep ls [--verbose]",
            "gitspace doctor keep prune [--older-than DAYS] [--dry-run] [--gc] [--yes]"
          ],
          flags: [],
          subcommands: [
            %{
              name: "ls",
              aliases: [],
              summary: "list keep refs",
              usage: [],
              flags: [verbose: :boolean],
              subcommands: [],
              hidden: false
            },
            %{
              name: "prune",
              aliases: [],
              summary: "prune keep refs",
              usage: [],
              flags: [older_than: :integer, dry_run: :boolean, gc: :boolean],
              subcommands: [],
              hidden: false
            }
          ],
          hidden: false
        }
      ],
      hidden: false
    },
    %{
      name: "scan",
      aliases: [],
      group: :maintain,
      summary: "discover existing clones and worktrees",
      usage: ["gitspace scan [path...] [--max-depth N] [--exclude GLOB]"],
      flags: [max_depth: :integer, exclude: :keep],
      subcommands: [],
      hidden: false
    },
    %{
      name: "link",
      aliases: [],
      group: :maintain,
      summary: "index an external checkout",
      usage: ["gitspace link <path> [--repo NAME]"],
      flags: [repo: :string],
      subcommands: [],
      hidden: false
    },
    %{
      name: "unlink",
      aliases: [],
      group: :maintain,
      summary: "forget an external checkout",
      usage: ["gitspace unlink <path>"],
      flags: [],
      subcommands: [],
      hidden: false
    },
    %{
      name: "setup",
      aliases: [],
      group: :maintain,
      summary: "choose data and projects directories",
      usage: ["gitspace setup [--data DIR] [--projects DIR] [--force]"],
      flags: [data: :string, projects: :string, force: :boolean],
      subcommands: [],
      hidden: false
    },
    %{
      name: "config",
      aliases: [],
      group: :maintain,
      summary: "settings, projects and repos",
      usage: ["gitspace config <list|get|set|export|import> [options]"],
      flags: [],
      subcommands: [
        %{
          name: "list",
          aliases: [],
          summary: "show effective configuration",
          usage: ["gitspace config list"],
          flags: [],
          subcommands: [],
          hidden: false
        },
        %{
          name: "get",
          aliases: [],
          summary: "read one setting",
          usage: ["gitspace config get <key>"],
          flags: [],
          subcommands: [],
          hidden: false
        },
        %{
          name: "set",
          aliases: [],
          summary: "change one setting",
          usage: ["gitspace config set <key> <value> [--force]"],
          flags: [force: :boolean],
          subcommands: [],
          hidden: false
        },
        %{
          name: "export",
          aliases: [],
          summary: "write a project and repo bundle",
          usage: ["gitspace config export [--output FILE]"],
          flags: [output: :string],
          subcommands: [],
          hidden: false
        },
        %{
          name: "import",
          aliases: [],
          summary: "create missing projects and repos",
          usage: ["gitspace config import <file|-> [--dry-run] [--no-fetch] [--yes]"],
          flags: [dry_run: :boolean, no_fetch: :boolean],
          subcommands: [],
          hidden: false
        }
      ],
      hidden: false
    },
    %{
      name: "completion",
      aliases: [],
      group: :maintain,
      summary: "print a shell completion script",
      usage: ["gitspace completion bash|zsh|fish"],
      flags: [],
      subcommands: [
        %{
          name: "bash",
          aliases: [],
          summary: "bash completion",
          usage: [],
          flags: [],
          subcommands: [],
          hidden: false
        },
        %{
          name: "zsh",
          aliases: [],
          summary: "zsh completion",
          usage: [],
          flags: [],
          subcommands: [],
          hidden: false
        },
        %{
          name: "fish",
          aliases: [],
          summary: "fish completion",
          usage: [],
          flags: [],
          subcommands: [],
          hidden: false
        }
      ],
      hidden: false
    },
    %{
      name: "help",
      aliases: [],
      group: :meta,
      summary: "show help",
      usage: ["gitspace help [command]"],
      flags: [],
      subcommands: [],
      hidden: true
    }
  ]

  @spec commands() :: [t()]
  def commands, do: @commands

  @spec command_names() :: [String.t()]
  def command_names do
    @commands
    |> Enum.reject(& &1.hidden)
    |> Enum.flat_map(&[&1.name | &1.aliases])
  end

  @spec completion_commands() :: [String.t()]
  def completion_commands, do: command_names() ++ ["help"]

  @spec command(String.t()) :: t() | nil
  def command(name) do
    Enum.find(@commands, fn command ->
      command.name == name or name in command.aliases
    end)
  end

  @spec visible_subcommands(t()) :: [subcommand()]
  def visible_subcommands(%{subcommands: subcommands}),
    do: Enum.reject(subcommands, & &1.hidden)

  @spec subcommand(String.t(), String.t()) :: subcommand() | nil
  def subcommand(command_name, subcommand_name) do
    with %{subcommands: subcommands} <- command(command_name) do
      Enum.find(subcommands, &(&1.name == subcommand_name or subcommand_name in &1.aliases))
    end
  end

  @spec flag_names(String.t(), String.t() | nil) :: [String.t()]
  def flag_names(command_name, subcommand_name \\ nil) do
    case {command(command_name), subcommand_name} do
      {nil, _} ->
        []

      {%{}, nil} ->
        flags(command(command_name))

      {%{}, sub} ->
        case subcommand(command_name, sub) do
          nil -> []
          sub_spec -> flags(sub_spec)
        end
    end
  end

  defp flags(%{flags: flags}),
    do: Enum.map(flags, fn {name, _type} -> "--" <> flag_name(name) end)

  @spec value_flags() :: [String.t()]
  def value_flags do
    @commands
    |> Enum.flat_map(&collect_value_flags/1)
    |> Enum.uniq()
  end

  defp collect_value_flags(%{flags: flags, subcommands: subcommands}) do
    own =
      flags
      |> Enum.reject(fn {_name, type} -> type == :boolean end)
      |> Enum.map(fn {name, _type} -> "--" <> flag_name(name) end)

    own ++ Enum.flat_map(subcommands, &collect_value_flags/1)
  end

  @spec global_flags() :: [String.t()]
  def global_flags, do: @global_flags

  @spec top_help() :: String.t()
  def top_help do
    groups = [
      {:inspect, "INSPECT"},
      {:work, "WORK"},
      {:workspace, "WORKSPACE"},
      {:project, "PROJECT"},
      {:repo, "REPO"},
      {:maintain, "MAINTAIN"},
      {:meta, "META"}
    ]

    sections =
      Enum.map(groups, fn {group, title} ->
        lines =
          @commands
          |> Enum.filter(&(&1.group == group and not &1.hidden))
          |> Enum.map(fn command ->
            short = Map.get(@shorts, command.name, syntax(command))
            gap = String.duplicate(" ", max(34 - String.length(short), 2))
            "  " <> short <> gap <> command.summary
          end)

        if lines == [] do
          ""
        else
          title <> "\n" <> Enum.join(lines, "\n")
        end
      end)

    ([
       "gitspace \u2014 workspaces for git checkouts",
       "",
       "USAGE",
       "  gitspace                     inbox: what needs a decision",
       "  gitspace <command> [options]",
       ""
     ] ++
       Enum.reject(sections, &(&1 == "")) ++
       ["", "GLOBAL", "  " <> Enum.join(@global_flags, " ")])
    |> Enum.join("\n")
  end

  defp syntax(command) do
    case command.usage do
      [first | _] -> String.replace_prefix(first, "gitspace ", "")
      [] -> command.name
    end
  end

  defp flag_name(name), do: name |> Atom.to_string() |> String.replace("_", "-")
end
