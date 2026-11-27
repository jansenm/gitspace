defmodule Gitspace.CLI.Repo do
  @moduledoc false

  alias Gitspace.{Branches, Create, Error, Projects, Repos}
  alias Gitspace.CLI.{Helpers, Output}

  defp add_strict,
    do:
      [name: :string, remote: :string, project: :string, no_fetch: :boolean] ++
        Helpers.global_strict()

  defp init_strict,
    do: [branch: :string, topic: :string, path: :string] ++ Helpers.global_strict()

  defp import_strict,
    do: [name: :string, no_link: :boolean] ++ Helpers.global_strict()

  defp branches_strict,
    do: [tags: :boolean, match: :string, regex: :string] ++ Helpers.global_strict()

  defp list_strict, do: Helpers.global_strict()
  defp fetch_strict, do: [all: :boolean] ++ Helpers.global_strict()
  defp rm_strict, do: [force: :boolean, dry_run: :boolean] ++ Helpers.global_strict()

  def run(global, args) do
    case args do
      ["init" | rest] -> init(global, rest)
      ["import" | rest] -> import_local(global, rest)
      ["branches" | rest] -> branches(global, rest)
      ["add" | rest] -> add(global, rest)
      ["ls" | rest] -> list(global, rest)
      ["fetch" | rest] -> fetch(global, rest)
      ["rm" | rest] -> remove(global, rest)
      ["alias" | rest] -> alias_repo(global, rest)
      ["set-url" | rest] -> set_url(global, rest)
      [] -> {:ok, %{help: help()}, &render_help/1}
      [other | _] -> {:error, Error.new(:usage, "unknown repo command: #{other}")}
    end
  end

  defp init(_global, args) do
    with {:ok, opts, rest} <- Helpers.parse(args, init_strict()),
         {:ok, name} <-
           one_arg(rest, "gitspace repo init <name> [--branch B] [--topic T] [--path P]"),
         {:ok, config} <- Helpers.load_config(),
         :ok <- Helpers.start_index(config) do
      case Repos.init_local(config, name, branch: opts[:branch] || "main") do
        {:ok, repo} ->
          case first_workspace(config, repo, opts) do
            {:ok, project, workspace} ->
              {:ok,
               %{
                 repo: repo_map(repo, 1),
                 project: project.name,
                 branch: repo.default_branch,
                 identity: repo.remote_key,
                 workspace: workspace.workspace,
                 path: workspace.path,
                 checkout: workspace.members |> hd() |> Map.get(:path),
                 marker: workspace.marker_path
               }, &render_init/1}

            {:error, error} ->
              _ = Repos.remove(config, repo.slug, force: true)
              {:error, error}
          end

        {:error, error} ->
          {:error, error}
      end
    end
  end

  defp import_local(_global, args) do
    with {:ok, opts, rest} <- Helpers.parse(args, import_strict()),
         {:ok, path} <- one_arg(rest, "gitspace repo import <path> [--name N] [--no-link]"),
         {:ok, config} <- Helpers.load_config(),
         :ok <- Helpers.start_index(config),
         {:ok, result} <-
           Repos.import_local(config, path, name: opts[:name], no_link: opts[:no_link]) do
      {:ok,
       %{
         repo: repo_map(result.repo, if(result.linked, do: 1, else: 0)),
         source: result.source,
         branch: result.branch,
         linked: result.linked
       }, &render_import/1}
    end
  end

  defp branches(_global, args) do
    with {:ok, opts, rest} <- Helpers.parse(args, branches_strict()),
         {:ok, name} <-
           one_arg(rest, "gitspace repo branches <repo> [--match GLOB|--regex RE] [--tags]"),
         {:ok, config} <- Helpers.load_config(),
         :ok <- Helpers.start_index(config),
         {:ok, result} <-
           Branches.list(config, name,
             tags: opts[:tags],
             match: opts[:match],
             regex: opts[:regex]
           ) do
      {:ok, result, &render_branches/1}
    end
  end

  defp first_workspace(config, repo, opts) do
    with {:ok, project} <- init_project(config, repo, opts),
         {:ok, workspace} <-
           Create.co(config, repo.slug, nil,
             topic: opts[:topic] || "main",
             as_is: true
           ) do
      {:ok, project, workspace}
    end
  end

  defp init_project(config, repo, opts) do
    case opts[:path] do
      nil -> Projects.ensure_implicit(config, repo)
      path -> Projects.create(config, repo.slug, path: path, repo: [repo.slug])
    end
  end

  defp add(_global, args) do
    with {:ok, opts, rest} <- Helpers.parse(args, add_strict()),
         {:ok, source} <- one_arg(rest, "gitspace repo add <url-or-path> [--remote NAME]"),
         {:ok, config} <- Helpers.load_config(),
         :ok <- Helpers.start_index(config),
         {:ok, repo} <-
           Repos.add(config, source,
             name: opts[:name],
             remote: opts[:remote],
             project: opts[:project],
             no_fetch: opts[:no_fetch]
           ) do
      data = %{
        repo: repo_map(repo, 0),
        project: opts[:project],
        fetched: !opts[:no_fetch]
      }

      {:ok, data, &render_add/1}
    end
  end

  defp list(global, args) do
    with {:ok, opts, rest} <- Helpers.parse(args, list_strict()),
         :ok <- Helpers.no_extra_args(rest),
         {:ok, config} <- Helpers.load_config(),
         :ok <- Helpers.start_index(config) do
      projects = Projects.list(config)

      repositories =
        Repos.list(config)
        |> Enum.map(fn %{repo: repo, checkouts: count} ->
          names = Enum.filter(projects, &(repo.remote_key in &1.members)) |> Enum.map(& &1.name)
          Map.put(repo_map(repo, count), :projects, names)
        end)

      verbose = !!global.verbose or !!opts[:verbose]

      {:ok, %{repositories: repositories, verbose: verbose}, &render_list/1}
    end
  end

  defp fetch(global, args) do
    with {:ok, opts, rest} <- Helpers.parse(args, fetch_strict()),
         {:ok, selector} <- selector(opts, rest),
         {:ok, config} <- Helpers.load_config(),
         :ok <- Helpers.start_index(config) do
      progress = progress(global)
      inline = selector == :all and not is_nil(progress)

      case Repos.fetch_selector(config, selector, on_progress: progress) do
        {:ok, repos} ->
          data = %{fetched: Enum.map(repos, & &1.slug), failed: [], inline: inline}
          {:ok, data, &render_fetch/1}

        {:partial, ok, errors} ->
          data = %{
            fetched: Enum.map(ok, & &1.slug),
            failed: Enum.map(errors, fn {slug, error} -> %{repo: slug, error: error.message} end),
            inline: inline
          }

          {:error,
           Error.new(:partial, "fetch failed for #{length(errors)} repository(ies)",
             hint: "failed: #{Enum.map_join(errors, ", ", fn {slug, _} -> slug end)}",
             details: data
           )}

        {:error, error} ->
          {:error, error}
      end
    end
  end

  defp remove(global, args) do
    with {:ok, opts, rest} <- Helpers.parse(args, rm_strict()),
         {:ok, selector} <- one_arg(rest, "gitspace repo rm <repo>"),
         {:ok, config} <- Helpers.load_config(),
         :ok <- Helpers.start_index(config),
         {:ok, repo} <- Repos.get(config, selector) do
      checkouts = Gitspace.Checkouts.list(config, repo: repo.slug) |> length()

      if opts[:dry_run] do
        {:ok,
         %{
           repository: repo.slug,
           mirror: repo.bare_path,
           checkouts_kept: checkouts,
           would_remove_mirror: repo.state != "external"
         }, &render_remove/1}
      else
        question = "remove mirror #{repo.slug} at #{repo.bare_path}?"

        with :ok <- Helpers.require_confirmation(global, opts, question),
             {:ok, result} <- Repos.remove(config, selector, force: opts[:force]) do
          {:ok, result, &render_remove/1}
        end
      end
    end
  end

  defp selector(opts, []) do
    if opts[:all],
      do: {:ok, :all},
      else: {:error, Error.new(:usage, "usage: gitspace repo fetch <repo>|--all")}
  end

  defp selector(opts, [selector]) do
    if opts[:all] do
      {:error, Error.new(:usage, "--all does not take a repository")}
    else
      {:ok, selector}
    end
  end

  defp selector(_opts, _rest) do
    {:error, Error.new(:usage, "usage: gitspace repo fetch <repo>|--all")}
  end

  defp one_arg([arg], _usage), do: {:ok, arg}
  defp one_arg(_rest, usage), do: {:error, Error.new(:usage, "usage: #{usage}")}

  defp alias_repo(_global, args) do
    with {:ok, _opts, rest} <- Helpers.parse(args, Helpers.global_strict()),
         {:ok, selector, name} <- selector_and_name(rest),
         {:ok, config} <- Helpers.load_config(),
         :ok <- Helpers.start_index(config),
         {:ok, repo} <- Repos.set_alias(config, selector, name) do
      checkouts = Gitspace.Checkouts.list(config, repo: repo.slug) |> length()

      {:ok, %{repo: repo_map(repo, checkouts)}, &render_alias/1}
    end
  end

  defp set_url(_global, args) do
    with {:ok, opts, rest} <- Helpers.parse(args, set_url_strict()),
         {:ok, selector, url} <-
           two_args(rest, "gitspace repo set-url <repo> <url> [--push]"),
         {:ok, config} <- Helpers.load_config(),
         :ok <- Helpers.start_index(config),
         {:ok, repo} <- Repos.get(config, selector),
         {:ok, result} <-
           Repos.set_remote_url(config, repo, url,
             push: opts[:push],
             no_fetch: opts[:no_fetch]
           ) do
      {:ok, result, &render_set_url/1}
    end
  end

  defp set_url_strict, do: [push: :boolean, no_fetch: :boolean] ++ Helpers.global_strict()

  defp two_args([selector, url], _usage) when selector != "" and url != "",
    do: {:ok, selector, url}

  defp two_args(_rest, usage), do: {:error, Error.new(:usage, "usage: #{usage}")}

  defp selector_and_name([selector, name]) when selector != "" and name != "" do
    {:ok, selector, name}
  end

  defp selector_and_name(_rest) do
    {:error, Error.new(:usage, "usage: gitspace repo alias <repo> <name>")}
  end

  defp repo_map(repo, checkouts) do
    %{
      id: repo.id,
      slug: repo.slug,
      remote_url: repo.remote_url,
      remote_key: repo.remote_key,
      origin_kind: repo.origin_kind,
      alias_source: repo.alias_source,
      hash: repo.bare_path && Path.basename(repo.bare_path, ".git"),
      bare_path: repo.bare_path,
      default_branch: repo.default_branch,
      state: repo.state,
      checkouts: checkouts,
      last_fetched_at: repo.last_fetched_at,
      last_fetch_error: repo.last_fetch_error
    }
  end

  defp render_add(data) do
    repo = data.repo
    IO.puts("registered #{repo.slug}")
    IO.puts("  remote:   #{repo.remote_url}")

    if data[:project] do
      IO.puts("  project:  #{data.project}")
    end

    IO.puts("  mirror:   #{repo.bare_path}")
    IO.puts("  default:  #{repo.default_branch || "?"}")

    if repo.last_fetch_error do
      IO.puts("  fetch:    failed (#{repo.last_fetch_error})")
    end
  end

  defp render_import(data) do
    repo = data.repo

    IO.puts("imported #{repo.slug}")
    IO.puts("  identity:  #{repo.remote_key}")
    IO.puts("  mirror:    #{repo.bare_path}")
    IO.puts("  branch:    #{data.branch}")
    IO.puts("  source:    #{data.source}")
    IO.puts("  linked:    #{if data.linked, do: "yes (external)", else: "no"}")
  end

  defp render_branches(data) do
    IO.puts("branches #{data.repo}")

    if data.branches == [] do
      IO.puts("  (none)")
    else
      rows =
        Enum.map(data.branches, fn branch ->
          notes =
            [
              if(branch.default, do: "default"),
              if(branch.checked_out, do: "checked out: #{branch.checked_out}")
            ]
            |> Enum.reject(&is_nil/1)
            |> Enum.join(", ")

          [Atom.to_string(branch.kind), branch.name, branch.sha, branch.date, notes]
        end)

      Output.table(["KIND", "BRANCH", "COMMIT", "DATE", "NOTE"], rows)
    end
  end

  defp remote_label(%{origin_kind: "local"}), do: "LOCAL"
  defp remote_label(repo), do: repo.remote_url

  defp render_init(data) do
    repo = data.repo

    IO.puts("initialized #{repo.slug}")
    IO.puts("  identity:  #{data.identity}")
    IO.puts("  mirror:    #{repo.bare_path}")
    IO.puts("  branch:    #{data.branch}")
    IO.puts("  project:   #{data.project}")
    IO.puts("  workspace: #{data.workspace}")
    IO.puts("  path:      #{data.path}")
    IO.puts("  checkout:  #{data.checkout}")
  end

  defp render_list(%{repositories: repositories} = data) do
    verbose = Map.get(data, :verbose, false)

    headers =
      ["SLUG", "PROJECT", "REMOTE", "STATE", "DEFAULT", "CHECKOUTS"] ++
        if(verbose, do: ["HASH", "MIRROR"], else: [])

    rows =
      Enum.map(repositories, fn repo ->
        base = [
          repo.slug,
          project_label(repo[:projects]),
          remote_label(repo),
          repo.state,
          repo.default_branch,
          repo.checkouts
        ]

        if verbose do
          base ++ [short_hash(repo.hash), repo.bare_path]
        else
          base
        end
      end)

    Output.table(headers, rows)
  end

  defp project_label([]), do: "-"
  defp project_label(names) when is_list(names), do: Enum.join(names, ",")

  defp short_hash(nil), do: "-"
  defp short_hash(hash), do: String.slice(hash, 0, 12)

  defp render_alias(%{repo: repo}) do
    IO.puts("alias: #{repo.slug}")
    IO.puts("  remote: #{repo.remote_url}")
    IO.puts("  mirror: #{repo.bare_path}")
  end

  defp progress(%{json: true}), do: nil

  defp progress(_global) do
    fn
      {:start, repo} -> IO.write("fetching #{repo.slug} ... ")
      {:ok, _repo} -> IO.puts("ok")
      {:error, slug, error} -> IO.puts("failed: #{failure_reason(slug, error)}")
    end
  end

  defp failure_reason(slug, error) do
    error.message
    |> String.replace_prefix("fetch failed for #{slug}: ", "")
    |> String.split("\n", trim: true)
    |> List.first()
    |> case do
      nil -> "fetch failed"
      line -> line
    end
  end

  defp render_fetch(%{inline: true, fetched: fetched}) do
    IO.puts("fetched #{length(fetched)} repositories")
  end

  defp render_fetch(%{fetched: fetched} = data) do
    Enum.each(fetched, &IO.puts("fetched #{&1}"))

    Enum.each(Map.get(data, :failed, []), fn failure ->
      IO.puts(:stderr, "failed #{failure.repo}: #{failure.error}")
    end)
  end

  defp render_remove(%{would_remove_mirror: true} = data) do
    IO.puts("would remove mirror #{data.repository}")
    IO.puts("  mirror:    #{data.mirror}")
    IO.puts("  checkouts: #{data.checkouts_kept} kept (directories are never deleted)")
  end

  defp render_remove(%{would_remove_mirror: false} = data) do
    IO.puts("nothing to remove for #{data.repository}")
  end

  defp render_remove(data) do
    IO.puts("removed mirror #{data.repository}")
    IO.puts("  checkouts unindexed: #{data.removed_checkouts}")
    IO.puts("  directories kept:    #{data.checkouts_kept}")

    if data[:bundle] do
      IO.puts("  bundle:              #{data.bundle}")
    end
  end

  defp help do
    """
    USAGE
      gitspace repo init <name> [--branch B] [--topic T] [--path P]
      gitspace repo import <path> [--name N] [--no-link]
      gitspace repo branches <repo> [--match GLOB|--regex RE] [--tags]
      gitspace repo add <url-or-path> [--name N] [--remote NAME] [--project P] [--no-fetch]
      gitspace repo ls [--verbose]
      gitspace repo fetch [<repo>|--all] [--prune]
      gitspace repo rm <repo> [--force] [--dry-run] [--yes]
      gitspace repo alias <repo> <name>
      gitspace repo set-url <repo> <url> [--push]

    LISTING
      `repo ls` is compact by default: slug, projects, remote, state, default
      branch and checkout count. `--verbose` adds the mirror hash and path.

    BRANCHES
      `repo branches` lists local branches, remote branches (as plain names, so
      `co repo@feature/x` works) and opt-in tags. --match takes a glob (* and ?),
      --regex an Elixir regex. Default and checked-out branches are marked.

    LOCAL REPOSITORIES
      `repo init` creates an empty managed repository with no upstream and its
      first checkout on an unborn branch. The mirror is the source of truth;
      `repo fetch` is a no-op and `repo rm` writes an `--all` bundle first.
      `--path` is the project directory, which must end with the repository
      name.

    ADD FROM A CHECKOUT
      Point `repo add` at an existing clone or worktree. With one remote its
      URL is registered automatically. With several, choose one with
      `--remote <name>`. A path without a remote is refused; pass a URL
      instead.

      When fetching, the mirror is seeded from the checkout with
      `git clone --reference ... --dissociate` so local objects are reused.

    REMOTE URLS
      `repo set-url` changes the fetch URL by default and the push URL with
      `--push`. The repository keeps its identity and mirror directory, so any
      host, port or path may change; only an address that already belongs to
      another repository is refused. Adopting the first upstream for a local
      repository fetches once (`--no-fetch` opts out). Multiple URL entries are
      refused.

        gitspace repo set-url ferroclass git@github.com:jansenm/ferroclass.git
        gitspace repo set-url ferroclass git@gitlab.com:jansenm/ferroclass.git
        gitspace repo set-url ferroclass git@github.com:jansenm/ferroclass.git --push
    """
  end

  defp render_set_url(data) do
    action = if data.previous == [], do: "adopted", else: "set"
    IO.puts("#{action} #{data.target} URL for #{data.repo}")
    IO.puts("  from:   #{List.first(data.previous) || "(none)"}")
    IO.puts("  to:     #{data.url}")
    IO.puts("  mirror: #{data.mirror}")

    cond do
      data[:fetch_error] ->
        IO.puts(:stderr, "fetch failed: #{data.fetch_error}")

      data[:fetched] ->
        IO.puts("  fetched: yes")

      true ->
        :ok
    end
  end

  defp render_help(%{help: help}), do: IO.puts(help)
end
