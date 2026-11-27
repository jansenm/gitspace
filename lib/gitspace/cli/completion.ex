defmodule Gitspace.CLI.Completion do
  @moduledoc """
  Shell completion for gitspace.

  `gitspace completion <shell>` prints a script. The script calls the hidden
  `__complete` command with the current command line; that command returns
  dynamic project, repository and workspace names as plain lines.

  Starting the BEAM is the expensive part of a completion, so two caches keep
  it out of the loop: the generated scripts memoize unfiltered candidates per
  context (keyed by a mutation stamp), and `__complete` snapshots the same
  lists in `<config>.complete.json`. Mutating commands bump `<config>.stamp`.
  """

  alias Gitspace.{Config, Projects, Repos, Workspaces}
  alias Gitspace.CLI.Helpers

  @cache_version 3

  @commands ~w(ls log push rebase co workspace project status show path repo scan link unlink doctor setup reindex config completion help)

  @subcommands %{
    "workspace" => ~w(new ls status rm help),
    "project" => ~w(new ls show add remove rm help),
    "repo" => ~w(init import add ls fetch rm alias set-url help),
    "config" => ~w(list get set help),
    "completion" => ~w(bash zsh fish)
  }

  @global_flags ~w(--json --no-color --verbose --yes --help --version)

  @command_flags %{
    "ls" =>
      ~w(--repo --project --topic --workspace --label --state --kind --source --verbose --wide),
    "co" => ~w(--topic --only --exclude --as --as-is --branch --detach --label --fetch),
    "project:new" => ~w(--repo --at --description --branch-template --default-ref),
    "project:rm" => ~w(--force),
    "repo:init" => ~w(--branch --topic --path),
    "repo:import" => ~w(--name --no-link),
    "repo:add" => ~w(--name --remote --project --no-fetch),
    "repo:fetch" => ~w(--all --prune),
    "repo:rm" => ~w(--force --dry-run),
    "repo:set-url" => ~w(--push),
    "workspace:new" =>
      ~w(--own --borrow --as --branch --as-is --label --description --fetch --dry-run),
    "workspace:ls" => ~w(--project --label --all),
    "workspace:status" => ~w(--refresh),
    "workspace:rm" => ~w(--force --dry-run),
    "status" => ~w(--refresh --long --diff --diff-lines),
    "log" => ~w(--outgoing --incoming --both --limit --all --fetch),
    "push" => ~w(--dry-run --remote),
    "rebase" => ~w(--continue --abort --fetch),
    "config:set" => ~w(--force),
    "setup" => ~w(--data --projects --checkouts --force),
    "doctor" => ~w(--fix --reindex),
    "scan" => ~w(--max-depth --exclude),
    "link" => ~w(--repo)
  }

  @value_flags ~w(--repo --project --topic --workspace --label --state --kind --source --only --exclude --as --branch --at --description --branch-template --default-ref --name --remote --own --borrow --data --projects --checkouts --max-depth --ide --shell --limit --diff-lines)

  @config_keys ~w(paths.data projects.root branch.template git.minimum_version status.max_age_seconds log.max_commits)

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
        case value_requests(before) do
          {:data, keys} = request ->
            cond do
              prefixed?(keys, current) ->
                expand_prefixed(current, keys)

              compound?(keys, current) ->
                [:compound]
                |> resolve()
                |> expand_compound(current)

              true ->
                resolve_requests(request)
            end

          request ->
            resolve_requests(request)
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

  # Candidates are either static or derived from the index. Data-backed
  # contexts are expressed as keys so the cache can answer them without
  # loading the config or starting Ecto.
  defp value_requests(before) do
    prev = List.last(before)
    cleaned = strip_globals(before)

    cond do
      prev in ~w(--state) -> {:static, ~w(ok missing broken unavailable detached)}
      prev in ~w(--kind) -> {:static, ~w(worktree clone)}
      prev in ~w(--source) -> {:static, ~w(managed external)}
      prev in ~w(--shell) -> {:static, ~w(bash zsh fish)}
      prev in ~w(--ide) -> {:static, ~w(code zed cursor)}
      prev in ~w(--project) -> {:data, [:projects]}
      prev in ~w(--workspace) -> {:data, [:workspace_names]}
      prev in ~w(--label) -> {:data, [:labels]}
      prev in ~w(--topic) -> {:data, [:topics]}
      prev in ~w(--repo --own --borrow) -> {:data, [:repos]}
      prev in ~w(--only --exclude) -> {:data, [{:members, command_project(cleaned) || ""}]}
      true -> positional_requests(before)
    end
  end

  defp resolve_requests({:static, values}), do: values
  defp resolve_requests({:data, keys}), do: resolve(keys)

  # `repo:` and `project:` selectors are only meaningful for target
  # positions; complete the name behind the prefix.
  defp prefixed?(keys, current) do
    keys == [:targets] and
      (String.starts_with?(current, "repo:") or String.starts_with?(current, "project:"))
  end

  defp expand_prefixed(current, _keys) do
    {prefix, key} =
      if String.starts_with?(current, "repo:") do
        {"repo:", :repos}
      else
        {"project:", :projects}
      end

    [key]
    |> resolve()
    |> Enum.map(&(prefix <> &1))
  end

  # Positional targets accept `project/topic/member`, `workspace:member` and
  # `project@topic` spellings. Once the current word contains a separator,
  # complete the next segment of those compound forms instead of filtering the
  # flat target list.
  defp compound?(keys, current) do
    (keys == [:targets] or keys == [:workspaces]) and
      String.contains?(current, ["/", ":", "@"])
  end

  defp expand_compound(candidates, current) do
    {base, _partial} = split_base(current)

    if base == "" do
      candidates
    else
      candidates
      |> Enum.filter(&String.starts_with?(&1, base))
      |> Enum.map(fn candidate ->
        candidate
        |> String.replace_prefix(base, "")
        |> String.split(["/", ":", "@"], parts: 2)
        |> hd()
        |> then(&(base <> &1))
      end)
      |> Enum.uniq()
    end
  end

  defp split_base(current) do
    case Regex.run(~r{^(.*[/:@])}, current) do
      [_, base] -> {base, String.replace_prefix(current, base, "")}
      nil -> {"", current}
    end
  end

  defp flags(before) do
    if "--" in before do
      []
    else
      cleaned = strip_globals(before)
      command = Enum.at(cleaned, 0)
      sub = subcommand(command, Enum.at(cleaned, 1))

      @global_flags ++
        Map.get(@command_flags, command, []) ++
        if(sub, do: Map.get(@command_flags, "#{command}:#{sub}", []), else: [])
    end
  end

  defp positional_requests(before) do
    if "--" in before do
      {:static, []}
    else
      cleaned = strip_globals(before)

      case cleaned do
        [] ->
          {:static, @commands}

        [command | rest] ->
          sub = subcommand(command, Enum.at(rest, 0))
          args = if sub, do: tl(rest), else: rest
          positional_values(command, sub, positional_args(args))
      end
    end
  end

  defp positional_values("co", nil, []), do: {:data, [:projects]}

  defp positional_values("log", nil, []), do: {:data, [:targets]}
  defp positional_values("push", nil, []), do: {:data, [:targets]}
  defp positional_values("rebase", nil, []), do: {:data, [:targets]}

  defp positional_values(command, nil, []) when command in ~w(status show path),
    do: {:data, [:targets]}

  defp positional_values("help", nil, []), do: {:static, @commands}

  defp positional_values(command, nil, []) do
    {:static, Map.get(@subcommands, command, [])}
  end

  defp positional_values(_command, nil, _args), do: {:static, []}

  defp positional_values("project", sub, args) do
    case {sub, length(args)} do
      {"show", 0} -> {:data, [:projects]}
      {"add", 0} -> {:data, [:projects]}
      {"remove", 0} -> {:data, [:projects]}
      {"rm", 0} -> {:data, [:projects]}
      {"add", count} when count >= 1 -> {:data, [:repos]}
      {"remove", count} when count >= 1 -> {:data, [:repos]}
      _ -> {:static, []}
    end
  end

  defp positional_values("repo", sub, args) do
    case {sub, length(args)} do
      {"fetch", 0} -> {:data, [:repos]}
      {"rm", 0} -> {:data, [:repos]}
      {"alias", 0} -> {:data, [:repos]}
      {"set-url", 0} -> {:data, [:repos]}
      _ -> {:static, []}
    end
  end

  defp positional_values("workspace", "new", []), do: {:data, [:projects]}

  defp positional_values("workspace", sub, []) when sub in ["status", "rm"] do
    {:data, [:workspaces]}
  end

  defp positional_values("config", sub, []) when sub in ["get", "set"] do
    {:static, @config_keys}
  end

  defp positional_values(_command, _sub, _args), do: {:static, []}

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

  defp resolve(keys) do
    keys = Enum.uniq(keys)

    case read_cache() do
      {:ok, lists} ->
        if Enum.all?(keys, &cached?(lists, &1)) do
          collect(lists, keys)
        else
          slow(keys)
        end

      :miss ->
        slow(keys)
    end
  end

  # Cache miss: load the config once and start the index once, then snapshot
  # every list a completion can ask for.
  defp slow(keys) do
    case Helpers.load_config() do
      {:ok, config} ->
        stamp = current_stamp()
        sources = sources(config)
        _ = Helpers.start_index(config)
        lists = build_lists(config)
        write_cache(lists, stamp, sources)
        collect(lists, keys)

      _ ->
        []
    end
  rescue
    _ -> []
  catch
    _, _ -> []
  end

  defp build_lists(config) do
    projects = Projects.list(config)
    project_names = Enum.map(projects, & &1.name)
    repos = Enum.map(Repos.list(config), & &1.repo.slug)
    workspaces = Workspaces.list(config)

    topics =
      workspaces
      |> Enum.map(fn workspace -> elem(Workspaces.parts(workspace), 1) end)
      |> Enum.uniq()

    workspace_names = Enum.map(workspaces, & &1.name)

    labels =
      workspaces
      |> Enum.flat_map(& &1.labels)
      |> Enum.map(& &1.label)
      |> Enum.uniq()

    workspace_targets =
      Enum.flat_map(workspaces, fn workspace ->
        members =
          Enum.map(workspace.members, fn member ->
            "#{workspace.name}:#{member.name || member.checkout.repository.slug}"
          end)

        [workspace.name | members]
      end)

    members =
      Map.new(projects, fn project ->
        slugs =
          case Projects.resolve_members(config, project) do
            {:ok, repos} -> Enum.map(repos, & &1.slug)
            {:error, _} -> []
          end

        {project.name, slugs}
      end)

    compounds =
      Enum.flat_map(workspaces, fn workspace ->
        {project, topic} = Workspaces.parts(workspace)

        paths =
          if project do
            [workspace.name, "#{project}/#{topic}"]
          else
            [workspace.name]
          end

        member_forms =
          Enum.flat_map(workspace.members, fn member ->
            name = member.name || member.checkout.repository.slug

            forms = ["#{workspace.name}:#{name}", "#{workspace.name}/#{name}"]
            if project, do: forms ++ ["#{project}/#{topic}/#{name}"], else: forms
          end)

        paths ++ member_forms
      end)

    %{
      "projects" => project_names,
      "repos" => repos,
      "topics" => topics,
      "workspaces" => workspace_targets,
      "workspace_names" => workspace_names,
      "labels" => labels,
      "targets" => Enum.uniq(project_names ++ workspace_targets ++ repos),
      "members" => members,
      "compound" => Enum.uniq(compounds)
    }
  end

  defp collect(lists, keys) do
    keys
    |> Enum.flat_map(fn
      :projects -> lists["projects"]
      :repos -> lists["repos"]
      :topics -> lists["topics"]
      :workspaces -> lists["workspaces"]
      :workspace_names -> lists["workspace_names"]
      :labels -> lists["labels"]
      :targets -> lists["targets"]
      :compound -> lists["compound"]
      {:members, ""} -> lists["repos"]
      {:members, project} -> Map.get(lists["members"] || %{}, project, [])
    end)
    |> Enum.uniq()
  end

  defp cached?(lists, :projects), do: is_list(lists["projects"])
  defp cached?(lists, :repos), do: is_list(lists["repos"])
  defp cached?(lists, :topics), do: is_list(lists["topics"])
  defp cached?(lists, :workspaces), do: is_list(lists["workspaces"])
  defp cached?(lists, :workspace_names), do: is_list(lists["workspace_names"])
  defp cached?(lists, :labels), do: is_list(lists["labels"])
  defp cached?(lists, :targets), do: is_list(lists["targets"])
  defp cached?(lists, :compound), do: is_list(lists["compound"])
  defp cached?(lists, {:members, ""}), do: is_list(lists["repos"])
  defp cached?(lists, {:members, project}), do: is_map_key(lists["members"] || %{}, project)
  defp cached?(_lists, _key), do: false

  # The cache lives next to the config file, so test configs and multiple
  # `GITSPACE_CONFIG`s stay isolated. A mutation stamp plus the config,
  # projects and index timestamps validate it without touching TOML or Ecto.
  defp read_cache do
    with {:ok, body} <- File.read(cache_path()),
         {:ok,
          %{
            "version" => @cache_version,
            "app" => app,
            "stamp" => stamp,
            "sources" => sources,
            "env" => env,
            "lists" => lists
          }}
         when is_map(lists) <- Jason.decode(body),
         true <- app == app_version(),
         true <- stamp == current_stamp(),
         true <- env == current_env(),
         true <- sources_current?(sources) do
      {:ok, lists}
    else
      _ -> :miss
    end
  end

  defp write_cache(lists, stamp, sources) do
    payload = %{
      "version" => @cache_version,
      "app" => app_version(),
      "stamp" => stamp,
      "sources" => sources,
      "env" => current_env(),
      "lists" => lists
    }

    path = cache_path()
    tmp = path <> ".tmp"
    File.mkdir_p!(Path.dirname(path))

    with :ok <- File.write(tmp, Jason.encode!(payload)),
         :ok <- File.rename(tmp, path) do
      :ok
    else
      _ ->
        _ = File.rm(tmp)
        :ok
    end
  rescue
    _ -> :ok
  end

  # Index mutations are covered by the stamp that `CLI.run/2` writes after a
  # mutating command. Only user-editable inputs need a timestamp check; the
  # index files are deliberately excluded because SQLite rewrites or removes
  # its WAL on every connect and would invalidate the cache on each call.
  defp sources(config) do
    [config.path, Projects.path(config)]
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.map(&source_entry/1)
  end

  defp source_entry(path) do
    case File.stat(path) do
      {:ok, %File.Stat{mtime: mtime, size: size}} ->
        %{"path" => path, "mtime" => mtime_seconds(mtime), "size" => size}

      {:error, _} ->
        %{"path" => path, "mtime" => nil, "size" => nil}
    end
  end

  defp sources_current?(sources) when is_list(sources) do
    Enum.all?(sources, fn
      %{"path" => path, "mtime" => mtime, "size" => size} ->
        case File.stat(path) do
          {:ok, %File.Stat{mtime: now_mtime, size: now_size}} ->
            mtime_seconds(now_mtime) == mtime and now_size == size

          {:error, _} ->
            is_nil(mtime) and is_nil(size)
        end

      _ ->
        false
    end)
  end

  defp sources_current?(_), do: false

  defp mtime_seconds({{_, _, _}, {_, _, _}} = mtime),
    do: :calendar.datetime_to_gregorian_seconds(mtime)

  defp mtime_seconds(_), do: nil

  defp current_env do
    %{
      "GITSPACE_DATA" => System.get_env("GITSPACE_DATA"),
      "GITSPACE_PROJECTS_ROOT" => System.get_env("GITSPACE_PROJECTS_ROOT")
    }
  end

  defp app_version do
    case Application.spec(:gitspace, :vsn) do
      nil -> "dev"
      vsn -> to_string(vsn)
    end
  end

  defp cache_path, do: Config.config_path() <> ".complete.json"
  defp stamp_path, do: Config.config_path() <> ".stamp"

  defp current_stamp do
    case File.read(stamp_path()) do
      {:ok, body} -> String.trim(body)
      {:error, _} -> "0"
    end
  end

  @doc "Invalidates completion caches after a mutating command."
  @spec touch() :: :ok
  def touch do
    path = stamp_path()
    dir = Path.dirname(path)

    if File.dir?(dir) do
      tmp = path <> ".tmp"
      File.write!(tmp, Integer.to_string(System.system_time(:microsecond)))
      File.rename!(tmp, path)
    end

    :ok
  rescue
    _ -> :ok
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
      local base="${cur%"${cur##*[/:@]}"}"
      if [[ $cur == -* ]]; then
        base="-"
      fi
      local -a before=("${COMP_WORDS[@]:1:COMP_CWORD-1}")
      local index=$((COMP_CWORD - 1))
      local config="${GITSPACE_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/gitspace/config.toml}"
      local stamp
      [[ -r "${config}.stamp" ]] && stamp=$(<"${config}.stamp")
      local bin fingerprint
      bin=$(command -v gitspace)
      if [[ -n $bin ]]; then
        fingerprint=$(stat -c '%Y-%s' "$bin" 2>/dev/null || stat -f '%m-%z' "$bin" 2>/dev/null)
      fi
      local cache_dir="${XDG_CACHE_HOME:-$HOME/.cache}/gitspace"
      local sum
      sum=$(printf '%s\\n' "$config" "$stamp" "$fingerprint" "$index" "$base" "${before[@]}" | cksum)
      local cache="$cache_dir/${sum%% *}"
      local -a candidates=()
      if [[ ! -f $cache ]]; then
        mkdir -p "$cache_dir"
        find "$cache_dir" -type f -mtime +1 -delete 2>/dev/null
        gitspace __complete "$index" "${before[@]}" "$base" >"$cache"
      fi
      if [[ -s $cache ]]; then
        mapfile -t candidates <"$cache"
        mapfile -t COMPREPLY < <(compgen -W "${candidates[*]}" -- "$cur")
      elif [[ $cur != -* ]]; then
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
      local cur="$PREFIX"
      local base="${cur%"${cur##*[/:@]}"}"
      if [[ $cur == -* ]]; then
        base="-"
      fi
      local -a before=("${words[2,CURRENT-1]}")
      local index=$((CURRENT - 2))
      local config="${GITSPACE_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/gitspace/config.toml}"
      local stamp
      [[ -r "${config}.stamp" ]] && stamp=$(<"${config}.stamp")
      local bin fingerprint
      bin=$(command -v gitspace)
      if [[ -n $bin ]]; then
        fingerprint=$(stat -c '%Y-%s' "$bin" 2>/dev/null || stat -f '%m-%z' "$bin" 2>/dev/null)
      fi
      local cache_dir="${XDG_CACHE_HOME:-$HOME/.cache}/gitspace"
      local sum
      sum=$(printf '%s\\n' "$config" "$stamp" "$fingerprint" "$index" "$base" "${before[@]}" | cksum)
      local cache="$cache_dir/${sum%% *}"
      local -a reply
      if [[ ! -f $cache ]]; then
        mkdir -p "$cache_dir"
        find "$cache_dir" -type f -mtime +1 -delete 2>/dev/null
        gitspace __complete "$index" "${before[@]}" "$base" >"$cache"
      fi
      if [[ -s $cache ]]; then
        reply=("${(@f)$(cat "$cache")}")
        reply=("${(@M)reply:#${PREFIX}*}")
      fi
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
        set -l base (string replace -r '^(.*[/:@]).*\$' '\$1' -- "$current")
        if test "$base" = "$current"
            set base ""
        end
        if test (string sub -l 1 -- "$current") = "-"
            set base "-"
        end
        set -e tokens[1]
        set -l config $GITSPACE_CONFIG
        if not set -q GITSPACE_CONFIG
            if set -q XDG_CONFIG_HOME
                set config $XDG_CONFIG_HOME/gitspace/config.toml
            else
                set config $HOME/.config/gitspace/config.toml
            end
        end
        set -l stamp
        if test -r "$config.stamp"
            set stamp (cat "$config.stamp")
        end
        set -l bin (command -s gitspace)
        set -l fingerprint
        if test -n "$bin"
            set fingerprint (stat -c '%Y-%s' "$bin" 2>/dev/null)
            if test -z "$fingerprint"
                set fingerprint (stat -f '%m-%z' "$bin" 2>/dev/null)
            end
        end
        set -l cache_dir $HOME/.cache/gitspace
        if set -q XDG_CACHE_HOME
            set cache_dir $XDG_CACHE_HOME/gitspace
        end
        set -l sum (printf '%s\\n' "$config" "$stamp" "$fingerprint" (count $tokens) "$base" $tokens | cksum)
        set -l cache $cache_dir/(string split ' ' -- $sum)[1]
        if not test -f $cache
            mkdir -p $cache_dir
            find $cache_dir -type f -mtime +1 -delete 2>/dev/null
            gitspace __complete (count $tokens) $tokens "$base" >$cache
        end
        if test -s $cache
            string match -a "$current*" (cat $cache)
        end
    end
    complete -c gitspace -f -a '(__gitspace_complete)'
    complete -c gsp -f -a '(__gitspace_complete)'
    """
  end
end
