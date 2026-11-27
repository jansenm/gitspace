defmodule Gitspace.CLI.Keep do
  @moduledoc false

  alias Gitspace.{Error, Keep}
  alias Gitspace.CLI.{Helpers, Output}

  def run(global, args) do
    case args do
      ["ls" | rest] -> list(global, rest)
      ["prune" | rest] -> prune(global, rest)
      ["help"] -> {:ok, %{help: help()}, &IO.puts/1}
      [] -> {:ok, %{help: help()}, &IO.puts/1}
      [other | _] -> {:error, Error.new(:usage, "unknown keep command: #{other}")}
    end
  end

  defp list(global, args) do
    with {:ok, _opts, rest} <- Helpers.parse(args, Helpers.global_strict()),
         :ok <- Helpers.no_extra_args(rest),
         {:ok, config} <- Helpers.load_config(),
         :ok <- Helpers.start_index(config) do
      entries = Keep.list(config)
      {:ok, %{entries: entries, verbose: !!global.verbose}, &render_list/1}
    end
  end

  defp prune(global, args) do
    with {:ok, opts, rest} <- Helpers.parse(args, prune_strict()),
         :ok <- Helpers.no_extra_args(rest),
         :ok <- validate_older_than(opts),
         {:ok, config} <- Helpers.load_config(),
         :ok <- Helpers.start_index(config) do
      preview = Keep.prune(config, older_than: opts[:older_than], dry_run: true)

      with :ok <- confirm(global, opts, preview) do
        result =
          Keep.prune(config,
            older_than: opts[:older_than],
            dry_run: opts[:dry_run],
            gc: opts[:gc]
          )

        {:ok, Map.put(result, :dry_run, !!opts[:dry_run]), &render_prune/1}
      end
    end
  end

  defp prune_strict do
    [older_than: :integer, dry_run: :boolean, gc: :boolean] ++ Helpers.global_strict()
  end

  defp validate_older_than(opts) do
    case opts[:older_than] do
      nil -> :ok
      days when is_integer(days) and days >= 0 -> :ok
      _ -> {:error, Error.new(:usage, "--older-than must be a non-negative integer")}
    end
  end

  defp confirm(global, opts, preview) do
    orphaned = Enum.count(preview.pruned, &(not &1.redundant))

    cond do
      opts[:dry_run] ->
        :ok

      orphaned > 0 ->
        Helpers.require_confirmation(
          global,
          opts,
          "delete #{length(preview.pruned)} keep ref(s), including #{orphaned} orphaned commit(s)?"
        )

      true ->
        :ok
    end
  end

  defp render_list(%{entries: entries} = data) do
    headers =
      ["REPO", "KIND", "AGE", "STATE", "COMMIT"] ++ if(data.verbose, do: ["REF"], else: [])

    rows =
      Enum.map(entries, fn entry ->
        base = [
          entry.repo,
          entry.kind,
          age(entry.age_days),
          if(entry.redundant, do: "redundant", else: "kept"),
          String.slice(entry.sha, 0, 12)
        ]

        if data.verbose, do: base ++ [entry.ref], else: base
      end)

    Output.table(headers, rows)
  end

  defp render_prune(%{dry_run: true} = result) do
    IO.puts("would prune #{length(result.pruned)} keep ref(s)")

    result.pruned
    |> Enum.group_by(& &1.repo)
    |> Enum.sort_by(fn {repo, _} -> repo end)
    |> Enum.each(fn {repo, entries} ->
      IO.puts("  #{repo}: #{length(entries)}")
    end)

    if result.kept != [], do: IO.puts("kept #{length(result.kept)}")
  end

  defp render_prune(result) do
    IO.puts("pruned #{length(result.pruned)} keep ref(s)")

    result.pruned
    |> Enum.group_by(& &1.repo)
    |> Enum.sort_by(fn {repo, _} -> repo end)
    |> Enum.each(fn {repo, entries} ->
      IO.puts("  #{repo}: #{length(entries)}")
    end)

    if result.kept != [], do: IO.puts("kept #{length(result.kept)}")

    Enum.each(result.errors, fn error ->
      IO.puts(:stderr, "failed #{error.repo} #{error.ref}: #{error.error}")
    end)

    Enum.each(result.gc, fn gc ->
      if gc[:error], do: IO.puts(:stderr, "gc #{gc.mirror}: #{gc.error}")
    end)
  end

  defp age(nil), do: "?"
  defp age(days), do: "#{days}d"

  def help do
    """
    USAGE
      gitspace keep ls [--verbose] [--json]
      gitspace keep prune [--older-than DAYS] [--dry-run] [--gc] [--yes] [--json]

    Keep refs anchor commits under refs/gitspace/keep/ before a worktree is
    removed or its stale metadata is pruned. `prune` always removes redundant
    anchors whose commit is reachable from a branch, remote or tag. Orphaned
    anchors are only removed when --older-than is given; that asks for
    confirmation unless --yes is passed. --gc repacks mirrors that lost refs.
    """
  end
end
