defmodule Gitspace.CLI.Log do
  @moduledoc false

  alias Gitspace.{Checkouts, Error, Repos, Targets}
  alias Gitspace.CLI.Helpers
  alias Gitspace.Git.History
  alias Gitspace.Index.{Checkout, Repository}

  def run(_global, args) do
    with {:ok, opts, rest} <- Helpers.parse(args, strict()),
         {:ok, target} <- one_arg(rest),
         {:ok, config} <- Helpers.load_config(),
         {:ok, directions, limit} <- settings(opts, config),
         :ok <- Helpers.start_index(config),
         {:ok, resolved} <- Targets.resolve(config, target),
         {:ok, entries} <- entries(config, resolved),
         {:ok, entries} <- maybe_fetch(config, entries, opts) do
      entries = Enum.map(entries, &read_entry(&1, directions, limit))

      {:ok, %{target: target, directions: directions, limit: limit, entries: entries}, &render/1}
    end
  end

  defp strict do
    [
      outgoing: :boolean,
      incoming: :boolean,
      both: :boolean,
      limit: :integer,
      all: :boolean,
      fetch: :boolean
    ] ++ Helpers.global_strict()
  end

  defp one_arg([arg]), do: {:ok, arg}

  defp one_arg(_rest) do
    {:error, Error.new(:usage, "usage: gitspace log <workspace|workspace:member|checkout|repo>")}
  end

  defp settings(opts, config) do
    cond do
      opts[:limit] && opts[:all] ->
        {:error, Error.new(:usage, "--limit and --all are mutually exclusive")}

      is_integer(opts[:limit]) and opts[:limit] <= 0 ->
        {:error, Error.new(:usage, "--limit must be a positive integer")}

      true ->
        {:ok, directions(opts), limit(opts, config)}
    end
  end

  defp directions(opts) do
    cond do
      opts[:outgoing] && !opts[:incoming] -> [:outgoing]
      opts[:incoming] && !opts[:outgoing] -> [:incoming]
      true -> [:outgoing, :incoming]
    end
  end

  defp limit(opts, config) do
    if opts[:all], do: nil, else: opts[:limit] || config.log_max_commits
  end

  defp entries(_config, {:workspace, workspace}) do
    {:ok, Enum.map(workspace.members, &build_entry(workspace.name, &1.checkout, &1.name))}
  end

  defp entries(_config, {:member, workspace, member}) do
    {:ok, [build_entry(workspace.name, member.checkout, member.name)]}
  end

  defp entries(_config, {:checkout, checkout}) do
    {:ok, [build_entry(nil, checkout, nil)]}
  end

  defp entries(config, {:repo, repo}) do
    {:ok, Enum.map(Checkouts.list(config, repo: repo.slug), &build_entry(nil, &1, nil))}
  end

  defp entries(_config, _resolved) do
    {:error,
     Error.new(:usage, "log needs a workspace, workspace:member, checkout or repository target")}
  end

  defp build_entry(workspace, checkout, member) do
    repo = repository(checkout)

    handle =
      cond do
        is_binary(workspace) and is_binary(member) -> "#{workspace}:#{member}"
        is_binary(workspace) and repo -> "#{workspace}:#{repo.slug}"
        repo -> repo.slug
        true -> Path.basename(checkout.path)
      end

    %{
      handle: handle,
      path: checkout.path,
      repo: repo && repo.slug,
      default_branch: repo && repo.default_branch
    }
  end

  defp repository(%Checkout{repository: %Repository{} = repo}), do: repo
  defp repository(%Checkout{repository_id: id}), do: Gitspace.Repo.get(Repository, id)

  defp maybe_fetch(config, entries, opts) do
    if opts[:fetch] do
      fetch(config, entries)
    else
      {:ok, entries}
    end
  end

  defp fetch(config, entries) do
    repos =
      entries
      |> Enum.map(& &1.repo)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    Enum.reduce_while(repos, {:ok, entries}, fn slug, acc ->
      case Repos.get(config, slug) do
        {:ok, %{bare_path: nil}} ->
          # External checkouts have their own remotes; there is no mirror to fetch.
          {:cont, acc}

        {:ok, repo} ->
          case Repos.fetch(config, repo) do
            {:ok, _} -> {:cont, acc}
            {:error, error} -> {:halt, {:error, error}}
          end

        {:error, error} ->
          {:halt, {:error, error}}
      end
    end)
  end

  defp read_entry(%{path: path} = entry, directions, limit) do
    cond do
      not File.dir?(path) ->
        Map.put(entry, :error, "checkout directory is missing")

      true ->
        case History.read(path,
               limit: limit,
               directions: directions,
               default_branch: entry[:default_branch]
             ) do
          {:ok, history} ->
            Map.merge(entry, history)

          {:error, reason} ->
            Map.put(entry, :error, format_error(reason))
        end
    end
  end

  defp format_error(%{stderr: stderr}) when is_binary(stderr) and stderr != "",
    do: String.trim(stderr)

  defp format_error(other), do: inspect(other)

  defp render(%{entries: entries, directions: directions}) do
    if entries == [] do
      IO.puts("(no checkouts)")
    else
      Enum.each(entries, fn entry ->
        IO.puts("#{entry.handle}  #{entry.path}")

        case entry[:error] do
          nil -> render_entry(entry, directions)
          error -> IO.puts("  ! #{error}")
        end

        IO.puts("")
      end)
    end
  end

  defp render_entry(entry, directions) do
    IO.puts("  branch:   #{entry.branch || "(detached)"}")
    IO.puts("  upstream: #{entry.upstream || "(none)"}")
    render_side(:outgoing, entry.outgoing, directions)
    render_side(:incoming, entry.incoming, directions)
  end

  defp render_side(_name, %{enabled: false}, _directions), do: :ok

  defp render_side(name, %{base: nil}, _directions) do
    IO.puts("  #{side_label(name)} 0  (no base)")
  end

  defp render_side(name, side, _directions) do
    IO.puts("  #{side_label(name)} #{side.total}  (vs #{side.base})")

    Enum.each(side.commits, fn commit ->
      date = commit.date |> String.slice(0, 10)
      IO.puts("    #{commit.short}  #{date}  #{commit.subject}")
    end)

    if side.truncated do
      IO.puts("    … showing #{length(side.commits)} of #{side.total}; use --limit or --all")
    end
  end

  defp side_label(:outgoing), do: "outgoing"
  defp side_label(:incoming), do: "incoming"
end
