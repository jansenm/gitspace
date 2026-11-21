defmodule Gitspace.CLI.Completion do
  @moduledoc """
  Shell completion for gitspace.

  `gitspace completion <shell>` prints a script. The script calls the hidden
  `__complete` command with the current command line; that command returns
  dynamic project, repository and workspace names as plain lines.
  """

  alias Gitspace.{Projects, Repos, Workspaces}
  alias Gitspace.CLI.Helpers

  @commands ~w(ls co workspace project status show path repo scan link unlink doctor setup reindex config completion help)

  @subcommands %{
    "workspace" => ~w(new ls status rm help),
    "project" => ~w(new ls show add remove rm help),
    "repo" => ~w(add ls fetch rm alias help),
    "config" => ~w(list get set help),
    "completion" => ~w(bash zsh fish)
  }

  @global_flags ~w(--json --no-color --verbose --yes --help --version)

  @command_flags %{
    "ls" =>
      ~w(--repo --project --topic --workspace --label --state --kind --source --verbose --wide),
    "co" => ~w(--topic --only --exclude --as --new-branch --branch --detach --label --fetch),
    "project:new" => ~w(--repo --at --description --branch-template --default-ref),
    "project:rm" => ~w(--force),
    "repo:add" => ~w(--name --remote --project --no-fetch),
    "repo:fetch" => ~w(--all --prune),
    "repo:rm" => ~w(--force --dry-run),
    "workspace:new" =>
      ~w(--project --own --borrow --as --branch --label --description --fetch --dry-run),
    "workspace:ls" => ~w(--project --label --all),
    "workspace:status" => ~w(--refresh),
    "workspace:rm" => ~w(--force --dry-run),
    "status" => ~w(--refresh),
    "config:set" => ~w(--force),
    "setup" => ~w(--data --projects --checkouts --force),
    "doctor" => ~w(--fix --reindex),
    "scan" => ~w(--max-depth --exclude),
    "link" => ~w(--repo)
  }

  @value_flags ~w(--repo --project --topic --workspace --label --state --kind --source --only --exclude --as --branch --at --description --branch-template --default-ref --name --remote --own --borrow --data --projects --checkouts --max-depth --ide --shell)

  @config_keys ~w(paths.data projects.root branch.template git.minimum_version status.max_age_seconds)

  @spec run(map(), [String.t()]) :: {:ok, map(), fun()} | {:error, Gitspace.Error.t()}
  def run(_global, args) do
    case args do
      [shell] when shell in ~w(bash zsh fish) ->
        {:ok, %{shell: shell, script: script(String.to_atom(shell))}, &render_script/1}

      [] ->
        {:ok, %{shells: ~w(bash zsh fish)}, &render_help/1}

      ["help"] ->
        {:ok, %{shells: ~w(bash zsh fish)}, &render_help/1}

      [other | _] ->
        {:error,
         Gitspace.Error.new(:usage, "unknown shell: #{other}",
           hint: "choose one of: bash, zsh, fish"
         )}
    end
  end

  @doc "Hidden `__complete` command. Always succeeds so shell completion is quiet."
  @spec complete([String.t()]) :: {:ok, map(), fun()}
  def complete(args) do
    values = values(args)
    {:ok, %{values: values}, &render_values/1}
  end

  @doc false
  @spec values([String.t()]) :: [String.t()]
  def values([index | words]) do
    index =
      case Integer.parse(index) do
        {value, _} when value >= 0 -> value
        _ -> 0
      end

    current = Enum.at(words, index) || ""
    before = Enum.take(words, index)

    values =
      if String.starts_with?(current, "-") do
        flags(before)
      else
        case value_context(before, current) do
          [] -> positional(before)
          values -> values
        end
      end

    values
    |> Enum.uniq()
    |> Enum.filter(&String.starts_with?(&1, current))
    |> Enum.sort()
  rescue
    _ -> []
  end

  def values(_), do: []

  defp value_context(before, _current) do
    prev = List.last(before)
    cleaned = strip_globals(before)

    case prev do
      "--project" -> projects()
      "--topic" -> topics()
      "--repo" -> repos()
      "--only" -> members(command_project(cleaned) || "")
      "--exclude" -> members(command_project(cleaned) || "")
      "--own" -> repos()
      "--borrow" -> repos()
      "--state" -> ~w(ok missing broken unavailable detached)
      "--kind" -> ~w(worktree clone)
      "--source" -> ~w(managed external)
      "--shell" -> ~w(bash zsh fish)
      "--ide" -> ~w(code zed cursor)
      _ -> []
    end
  end

  defp flags(before) do
    cleaned = strip_globals(before)
    command = Enum.at(cleaned, 0)
    sub = subcommand(command, Enum.at(cleaned, 1))

    @global_flags ++
      Map.get(@command_flags, command, []) ++
      if(sub, do: Map.get(@command_flags, "#{command}:#{sub}", []), else: [])
  end

  defp positional(before) do
    cleaned = strip_globals(before)

    case cleaned do
      [] ->
        @commands

      [command | rest] ->
        sub = subcommand(command, Enum.at(rest, 0))
        args = if sub, do: tl(rest), else: rest
        positional_values(command, sub, positional_args(args))
    end
  end

  defp positional_values("co", nil, []), do: projects()
  defp positional_values("status", nil, []), do: all_targets()
  defp positional_values("show", nil, []), do: all_targets()
  defp positional_values("path", nil, []), do: all_targets()
  defp positional_values("help", nil, []), do: @commands

  defp positional_values(command, nil, []) do
    Map.get(@subcommands, command, [])
  end

  defp positional_values(_command, nil, _args), do: []

  defp positional_values("project", sub, args) do
    case {sub, length(args)} do
      {"show", 0} -> projects()
      {"add", 0} -> projects()
      {"remove", 0} -> projects()
      {"rm", 0} -> projects()
      {"add", count} when count >= 1 -> repos()
      {"remove", count} when count >= 1 -> repos()
      _ -> []
    end
  end

  defp positional_values("repo", sub, args) do
    case {sub, length(args)} do
      {"fetch", 0} -> repos()
      {"rm", 0} -> repos()
      {"alias", 0} -> repos()
      _ -> []
    end
  end

  defp positional_values("workspace", sub, []) when sub in ["status", "rm"] do
    workspace_targets()
  end

  defp positional_values("config", sub, []) when sub in ["get", "set"] do
    @config_keys
  end

  defp positional_values("status", _sub, []), do: all_targets()
  defp positional_values("show", _sub, []), do: all_targets()
  defp positional_values("path", _sub, []), do: all_targets()
  defp positional_values(_command, _sub, _args), do: []

  defp subcommand(command, candidate) do
    if candidate in Map.get(@subcommands, command, []), do: candidate
  end

  defp positional_args(words) do
    {args, _skip} =
      Enum.reduce(words, {[], false}, fn word, {args, skip?} ->
        cond do
          skip? -> {args, false}
          String.starts_with?(word, "-") -> {args, word in @value_flags}
          true -> {[word | args], false}
        end
      end)

    Enum.reverse(args)
  end

  defp command_project(cleaned) do
    case cleaned do
      ["co" | rest] ->
        rest
        |> positional_args()
        |> List.first()

      ["workspace", "new" | rest] ->
        rest
        |> positional_args()
        |> List.first()

      _ ->
        nil
    end
  end

  defp strip_globals(words) do
    words
    |> Enum.drop_while(&(&1 in @global_flags))
  end

  defp projects do
    dynamic(fn config -> Enum.map(Projects.list(config), & &1.name) end)
  end

  defp repos do
    dynamic(fn config ->
      _ = Helpers.start_index(config)
      Enum.map(Repos.list(config), & &1.repo.slug)
    end)
  end

  defp topics do
    dynamic(fn config ->
      _ = Helpers.start_index(config)

      config
      |> Workspaces.list()
      |> Enum.map(fn workspace -> elem(Workspaces.parts(workspace), 1) end)
      |> Enum.uniq()
    end)
  end

  defp members(""), do: repos()

  defp members(project) do
    dynamic(fn config ->
      _ = Helpers.start_index(config)

      with {:ok, project} <- Projects.get(config, project),
           {:ok, repos} <- Projects.resolve_members(config, project) do
        Enum.map(repos, & &1.slug)
      else
        _ -> []
      end
    end)
  end

  defp all_targets do
    projects() ++ workspace_targets() ++ repos()
  end

  defp workspace_targets do
    dynamic(fn config ->
      _ = Helpers.start_index(config)

      config
      |> Workspaces.list()
      |> Enum.flat_map(fn workspace ->
        members =
          Enum.map(workspace.members, fn member ->
            "#{workspace.name}:#{member.name || member.checkout.repository.slug}"
          end)

        [workspace.name | members]
      end)
    end)
  end

  defp dynamic(fun) do
    case Helpers.load_config() do
      {:ok, config} ->
        try do
          fun.(config)
        rescue
          _ -> []
        catch
          _, _ -> []
        end

      _ ->
        []
    end
  end

  defp render_values(%{values: values}) do
    Enum.each(values, &IO.puts/1)
  end

  defp render_script(%{script: script}), do: IO.write(script)

  defp render_help(%{shells: shells}) do
    IO.puts("""
    USAGE
      gitspace completion bash
      gitspace completion zsh
      gitspace completion fish

    Shells: #{Enum.join(shells, ", ")}
    """)
  end

  @doc false
  def script(:bash) do
    """
    _gitspace_complete() {
      local cur="${COMP_WORDS[COMP_CWORD]}"
      local -a args=("${COMP_WORDS[@]:1}")
      mapfile -t COMPREPLY < <(gitspace __complete "$((COMP_CWORD-1))" "${args[@]}")
      if [[ ${#COMPREPLY[@]} -eq 0 && "$cur" != -* ]]; then
        mapfile -t COMPREPLY < <(compgen -f -- "$cur")
      fi
    }
    complete -o nospace -F _gitspace_complete gitspace gsp
    """
  end

  def script(:zsh) do
    """
    #compdef gitspace gsp
    _gitspace_complete() {
      local -a reply
      local -a args=("${words[2,CURRENT]}")
      reply=("${(@f)$(gitspace __complete "$((CURRENT-2))" "${args[@]}")}")
      reply=("${(@)reply:#}")
      if (( ${#reply} )); then
        compadd -- "${reply[@]}"
      else
        _files
      fi
    }
    compdef _gitspace_complete gitspace gsp
    """
  end

  def script(:fish) do
    """
    function __gitspace_complete
        set -l tokens (commandline -opc)
        set -l current (commandline -ct)
        set -e tokens[1]
        gitspace __complete (count $tokens) $tokens $current
    end
    complete -c gitspace -f -a '(__gitspace_complete)'
    complete -c gsp -f -a '(__gitspace_complete)'
    """
  end
end
