defmodule Gitspace.Keep do
  @moduledoc """
  Inventory and pruning for `refs/gitspace/keep/*`.

  Teardown and `doctor --fix` anchor commits there before removing worktrees;
  a rebase rollback anchors the pre-rebase head only for the duration of the
  reset. Anchors whose commit is reachable from a branch, remote or tag are
  redundant and can be pruned without losing anything. Orphaned anchors are
  kept unless an explicit age is given.
  """

  alias Gitspace.{Config, Git, Repos}

  @prefix "refs/gitspace/keep/"

  @type entry :: %{
          repo: String.t(),
          mirror: Path.t(),
          ref: String.t(),
          sha: String.t(),
          kind: String.t(),
          created_at: DateTime.t() | nil,
          age_days: non_neg_integer() | nil,
          redundant: boolean()
        }

  @spec list(Config.t()) :: [entry()]
  def list(%Config{} = config) do
    config
    |> mirrors()
    |> Enum.flat_map(&entries/1)
    |> Enum.sort_by(&{&1.repo, &1.ref})
  end

  @spec summary(Config.t()) :: %{
          total: non_neg_integer(),
          redundant: non_neg_integer(),
          orphaned: non_neg_integer(),
          oldest_days: non_neg_integer() | nil
        }
  def summary(%Config{} = config) do
    entries = list(config)

    %{
      total: length(entries),
      redundant: Enum.count(entries, & &1.redundant),
      orphaned: Enum.count(entries, &(not &1.redundant)),
      oldest_days:
        entries |> Enum.map(& &1.age_days) |> Enum.reject(&is_nil/1) |> Enum.max(fn -> nil end)
    }
  end

  @doc """
  Deletes keep refs.

  Redundant refs are always selected. With `:older_than` (days), orphaned refs
  at least that old are selected too. `:dry_run` only reports. `:gc` repacks
  each mirror that lost a ref.
  """
  @spec prune(Config.t(), keyword()) :: %{
          pruned: [entry()],
          kept: [entry()],
          errors: [map()],
          gc: [map()]
        }
  def prune(%Config{} = config, opts \\ []) do
    older_than = opts[:older_than]

    entries = list(config)
    targets = Enum.filter(entries, &selected?(&1, older_than))

    if opts[:dry_run] do
      %{pruned: targets, kept: entries -- targets, errors: [], gc: []}
    else
      {pruned, errors} = delete(targets)
      %{pruned: pruned, kept: entries -- targets, errors: errors, gc: gc(pruned, opts)}
    end
  end

  defp selected?(entry, older_than) do
    entry.redundant or
      (is_integer(older_than) and is_integer(entry.age_days) and entry.age_days >= older_than)
  end

  defp delete(entries) do
    {pruned, errors} =
      Enum.reduce(entries, {[], []}, fn entry, {pruned, errors} ->
        case Git.run(["update-ref", "-d", entry.ref], cd: entry.mirror) do
          {:ok, _} ->
            {[entry | pruned], errors}

          {:error, result} ->
            {pruned, [%{repo: entry.repo, ref: entry.ref, error: last_line(result)} | errors]}
        end
      end)

    {Enum.reverse(pruned), Enum.reverse(errors)}
  end

  defp gc(pruned, opts) do
    if opts[:gc] do
      do_gc(pruned)
    else
      []
    end
  end

  defp do_gc([]), do: []

  defp do_gc(pruned) do
    pruned
    |> Enum.map(& &1.mirror)
    |> Enum.uniq()
    |> Enum.map(fn mirror ->
      case Git.run(["gc", "--prune=now"], cd: mirror, locks: true, timeout: 300_000) do
        {:ok, _} -> %{mirror: mirror, gc: true}
        {:error, result} -> %{mirror: mirror, gc: false, error: last_line(result)}
      end
    end)
  end

  defp mirrors(%Config{} = config) do
    config
    |> Repos.list()
    |> Enum.map(& &1.repo)
    |> Enum.filter(&(is_binary(&1.bare_path) and File.dir?(&1.bare_path)))
  end

  defp entries(repo) do
    args = ["for-each-ref", "--format=%(refname)%00%(objectname)", @prefix]

    case Git.run(args, cd: repo.bare_path) do
      {:ok, %{stdout: out}} ->
        out
        |> String.split("\n", trim: true)
        |> Enum.flat_map(&parse(&1, repo))

      {:error, _} ->
        []
    end
  end

  defp parse(line, repo) do
    case String.split(line, "\0", parts: 2) do
      [ref, sha] ->
        [build(repo, ref, String.trim(sha))]

      _ ->
        []
    end
  end

  defp build(repo, ref, sha) do
    created_at = created_at(ref)

    %{
      repo: repo.slug,
      mirror: repo.bare_path,
      ref: ref,
      sha: sha,
      kind: kind(ref),
      created_at: created_at,
      age_days: age_days(created_at),
      redundant: redundant?(repo.bare_path, sha)
    }
  end

  defp kind(ref) do
    ref
    |> String.replace_prefix(@prefix, "")
    |> String.split("/", parts: 2)
    |> hd()
  end

  defp created_at(ref) do
    parts = String.split(ref, "/")
    category = Enum.at(parts, 3)
    last = List.last(parts) || ""

    stamp =
      case category do
        "rebase" -> last |> String.split("-", parts: 2) |> hd()
        "doctor" -> last |> String.split("-") |> List.last()
        _ -> last
      end

    case Integer.parse(stamp) do
      {seconds, ""} when seconds > 0 -> DateTime.from_unix!(seconds)
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp age_days(nil), do: nil

  defp age_days(%DateTime{} = at) do
    DateTime.utc_now() |> DateTime.diff(at, :day) |> max(0)
  end

  defp redundant?(bare, sha) do
    case Git.run(["rev-list", "-1", sha, "--not", "--branches", "--remotes", "--tags"], cd: bare) do
      {:ok, %{stdout: out}} -> String.trim(out) == ""
      {:error, _} -> false
    end
  end

  defp last_line(result) do
    (result.stdout <> result.stderr)
    |> String.split("\n", trim: true)
    |> List.last()
    |> case do
      nil -> "git failed"
      line -> line |> String.replace_prefix("error: ", "") |> String.replace_prefix("fatal: ", "")
    end
  end
end
