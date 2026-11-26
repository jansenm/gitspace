defmodule Gitspace.Git.Status do
  @moduledoc "Parses `git status --porcelain=v2 --branch -z` from a checkout."

  alias Gitspace.Git

  defstruct head: nil,
            branch: nil,
            upstream: nil,
            ahead: nil,
            behind: nil,
            dirty: 0,
            untracked: 0,
            detached: false

  @spec read(Path.t()) :: {:ok, %__MODULE__{}} | {:error, Git.result()}
  def read(worktree) do
    args = ["status", "--porcelain=v2", "--branch", "-z", "--untracked-files=normal"]

    case Git.run(args, cd: worktree) do
      {:ok, %{stdout: out}} -> {:ok, parse(out)}
      {:error, _} = error -> error
    end
  end

  @spec read!(Path.t()) :: %__MODULE__{}
  def read!(worktree) do
    {:ok, status} = read(worktree)
    status
  end

  @doc false
  def parse(output) do
    output
    |> String.split("\0", trim: true)
    |> Enum.reduce(%__MODULE__{}, &parse_record/2)
  end

  defp parse_record("# branch.oid (initial)", acc), do: %{acc | head: nil}
  defp parse_record("# branch.oid " <> oid, acc), do: %{acc | head: oid}
  defp parse_record("# branch.head (detached)", acc), do: %{acc | detached: true}

  defp parse_record("# branch.head " <> branch, acc),
    do: %{acc | branch: branch, detached: false}

  defp parse_record("# branch.upstream " <> upstream, acc), do: %{acc | upstream: upstream}

  defp parse_record("# branch.ab " <> ab, acc) do
    case Regex.run(~r/\+(\d+) -(\d+)/, ab) do
      [_, ahead, behind] ->
        %{acc | ahead: String.to_integer(ahead), behind: String.to_integer(behind)}

      _ ->
        acc
    end
  end

  defp parse_record("? " <> _path, acc), do: %{acc | untracked: acc.untracked + 1}
  defp parse_record("! " <> _path, acc), do: acc

  defp parse_record(record, acc) do
    case String.first(record) do
      "1" -> %{acc | dirty: acc.dirty + 1}
      "2" -> %{acc | dirty: acc.dirty + 1}
      "u" -> %{acc | dirty: acc.dirty + 1}
      _ -> acc
    end
  end

  def total_dirty(%__MODULE__{dirty: dirty, untracked: untracked}), do: dirty + untracked
end
