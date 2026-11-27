defmodule Gitspace.Git.Changes do
  @moduledoc """
  Working tree file entries and diffs for a single checkout.

  Entries come from `git status --porcelain=v2 -z`, the same source the status
  counters use. Diffs are only read on demand and capped so a large change
  cannot flood the terminal.
  """

  alias Gitspace.Git

  @type entry :: %{
          path: String.t(),
          status: String.t(),
          index: String.t(),
          worktree: String.t(),
          orig_path: String.t() | nil,
          untracked: boolean()
        }

  @spec entries(Path.t()) :: {:ok, [entry()]} | {:error, term()}
  def entries(worktree) do
    args = ["status", "--porcelain=v2", "-z", "--untracked-files=normal"]

    case Git.run(args, cd: worktree) do
      {:ok, %{stdout: out}} ->
        {:ok,
         out
         |> String.split("\0", trim: true)
         |> parse()
         |> Enum.sort_by(& &1.path)}

      {:error, _} = error ->
        error
    end
  end

  @spec diff(Path.t(), keyword()) ::
          {:ok, %{staged: String.t(), unstaged: String.t(), truncated: boolean()}}
          | {:error, term()}
  def diff(worktree, opts \\ []) do
    max_lines = Keyword.get(opts, :max_lines, 200)

    with {:ok, unstaged} <- run_diff(worktree, []),
         {:ok, staged} <- run_diff(worktree, ["--cached"]) do
      {unstaged, unstaged_truncated} = truncate(unstaged, max_lines)
      {staged, staged_truncated} = truncate(staged, max_lines)

      {:ok,
       %{
         staged: staged,
         unstaged: unstaged,
         truncated: unstaged_truncated or staged_truncated
       }}
    end
  end

  defp run_diff(worktree, args) do
    case Git.run(["diff", "--no-color", "--no-ext-diff" | args], cd: worktree) do
      {:ok, %{stdout: out}} -> {:ok, out}
      {:error, _} = error -> error
    end
  end

  defp truncate(text, max) when is_integer(max) and max > 0 do
    lines = String.split(text, "\n")

    if length(lines) > max do
      kept = lines |> Enum.take(max) |> Enum.join("\n")
      {kept <> "\n… #{length(lines) - max} lines truncated", true}
    else
      {text, false}
    end
  end

  defp truncate(text, _max), do: {text, false}

  defp parse(records), do: parse(records, [])

  defp parse([], acc), do: Enum.reverse(acc)

  defp parse(["1 " <> rest | tail], acc) do
    case String.split(rest, " ", parts: 8) do
      [xy, _sub, _mh, _mi, _mw, _hh, _hi, path] ->
        parse(tail, [entry(xy, path) | acc])

      _ ->
        parse(tail, acc)
    end
  end

  defp parse(["2 " <> rest | tail], acc) do
    case String.split(rest, " ", parts: 9) do
      [xy, _sub, _mh, _mi, _mw, _hh, _hi, _score, path] ->
        {orig_path, tail} = pop_orig(tail)
        parse(tail, [entry(xy, path) |> Map.put(:orig_path, orig_path) | acc])

      _ ->
        parse(tail, acc)
    end
  end

  defp parse(["u " <> rest | tail], acc) do
    case String.split(rest, " ", parts: 10) do
      [xy, _sub, _m1, _m2, _m3, _mw, _h1, _h2, _h3, path] ->
        parse(tail, [entry(xy, path) | acc])

      _ ->
        parse(tail, acc)
    end
  end

  defp parse(["?" <> rest | tail], acc) do
    path = String.trim_leading(rest, " ")

    parse(tail, [
      %{
        path: path,
        status: "??",
        index: "?",
        worktree: "?",
        orig_path: nil,
        untracked: true
      }
      | acc
    ])
  end

  defp parse([_ignored | tail], acc), do: parse(tail, acc)

  defp pop_orig([orig | tail]), do: {orig, tail}
  defp pop_orig([]), do: {nil, []}

  defp entry(<<index::binary-size(1), worktree::binary-size(1)>> = xy, path) do
    %{
      path: path,
      status: xy,
      index: index,
      worktree: worktree,
      orig_path: nil,
      untracked: false
    }
  end

  defp entry(xy, path) do
    %{
      path: path,
      status: xy,
      index: "",
      worktree: "",
      orig_path: nil,
      untracked: false
    }
  end
end
