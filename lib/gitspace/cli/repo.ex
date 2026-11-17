defmodule Gitspace.CLI.Repo do
  @moduledoc false

  alias Gitspace.{Error, Repos}
  alias Gitspace.CLI.{Helpers, Output}

  defp add_strict,
    do: [name: :string, remote: :string, no_fetch: :boolean] ++ Helpers.global_strict()

  defp list_strict, do: Helpers.global_strict()
  defp fetch_strict, do: [all: :boolean, prune: :boolean] ++ Helpers.global_strict()
  defp rm_strict, do: [force: :boolean, dry_run: :boolean] ++ Helpers.global_strict()

  def run(global, args) do
    case args do
      ["add" | rest] -> add(global, rest)
      ["ls" | rest] -> list(global, rest)
      ["fetch" | rest] -> fetch(global, rest)
      ["rm" | rest] -> remove(global, rest)
      ["alias" | rest] -> alias_repo(global, rest)
      [] -> {:ok, %{help: help()}, &render_help/1}
      [other | _] -> {:error, Error.new(:usage, "unknown repo command: #{other}")}
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
             no_fetch: opts[:no_fetch]
           ) do
      data = %{
        repo: repo_map(repo, 0),
        fetched: !opts[:no_fetch]
      }

      {:ok, data, &render_add/1}
    end
  end

  defp list(_global, args) do
    with {:ok, _opts, rest} <- Helpers.parse(args, list_strict()),
         :ok <- Helpers.no_extra_args(rest),
         {:ok, config} <- Helpers.load_config(),
         :ok <- Helpers.start_index(config) do
      repositories =
        Repos.list(config)
        |> Enum.map(fn %{repo: repo, checkouts: count} -> repo_map(repo, count) end)

      {:ok, %{repositories: repositories}, &render_list/1}
    end
  end

  defp fetch(_global, args) do
    with {:ok, opts, rest} <- Helpers.parse(args, fetch_strict()),
         {:ok, selector} <- selector(opts, rest),
         {:ok, config} <- Helpers.load_config(),
         :ok <- Helpers.start_index(config) do
      case Repos.fetch_selector(config, selector) do
        {:ok, repos} ->
          data = %{fetched: Enum.map(repos, & &1.slug), failed: []}
          {:ok, data, &render_fetch/1}

        {:partial, ok, errors} ->
          data = %{
            fetched: Enum.map(ok, & &1.slug),
            failed: Enum.map(errors, fn {slug, error} -> %{repo: slug, error: error.message} end)
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

  defp selector(_opts, []), do: {:ok, :all}

  defp selector(_opts, [selector]), do: {:ok, selector}

  defp selector(_opts, _rest) do
    {:error, Error.new(:usage, "usage: gitspace repo fetch [<repo>|--all]")}
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
    IO.puts("  mirror:   #{repo.bare_path}")
    IO.puts("  default:  #{repo.default_branch || "?"}")

    if repo.last_fetch_error do
      IO.puts("  fetch:    failed (#{repo.last_fetch_error})")
    end
  end

  defp render_list(%{repositories: repositories}) do
    Output.table(
      ["SLUG", "REMOTE", "STATE", "DEFAULT", "CHECKOUTS", "HASH", "MIRROR"],
      Enum.map(repositories, fn repo ->
        [
          repo.slug,
          repo.remote_url,
          repo.state,
          repo.default_branch,
          repo.checkouts,
          String.slice(repo.hash || "", 0, 12),
          repo.bare_path
        ]
      end)
    )
  end

  defp render_alias(%{repo: repo}) do
    IO.puts("alias: #{repo.slug}")
    IO.puts("  remote: #{repo.remote_url}")
    IO.puts("  mirror: #{repo.bare_path}")
  end

  defp render_fetch(%{fetched: fetched, failed: failed}) do
    Enum.each(fetched, &IO.puts("fetched #{&1}"))

    Enum.each(failed, fn failure ->
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
  end

  defp help do
    """
    USAGE
      gitspace repo add <url-or-path> [--name N] [--remote NAME] [--no-fetch]
      gitspace repo ls
      gitspace repo fetch [<repo>|--all] [--prune]
      gitspace repo rm <repo> [--force] [--dry-run] [--yes]
      gitspace repo alias <repo> <name>

    ADD FROM A CHECKOUT
      Point `repo add` at an existing clone or worktree. With one remote its
      URL is registered automatically. With several, choose one with
      `--remote <name>`. A local git repository without remotes is mirrored
      from its path, as before.
    """
  end

  defp render_help(%{help: help}), do: IO.puts(help)
end
