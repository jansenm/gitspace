defmodule Gitspace.Git.Worktree do
  @moduledoc "Worktree creation, listing and removal, parsed from porcelain output."

  alias Gitspace.Git

  defstruct [:path, :head, :branch, :detached, :bare, :locked, :prunable]

  @spec add(Path.t(), Path.t(), String.t(), keyword()) ::
          {:ok, Git.result()} | {:error, Git.result()}
  def add(bare, path, ref, opts \\ []) do
    unless Path.type(path) == :absolute do
      raise ArgumentError, "worktree paths must be absolute, got: #{inspect(path)}"
    end

    args =
      ["worktree", "add"] ++
        if(opts[:detach], do: ["--detach"], else: []) ++
        if(opts[:branch], do: ["-b", opts[:branch]], else: []) ++
        [path, ref]

    Git.run(args, cd: bare, locks: true)
  end

  @spec remove(Path.t(), Path.t(), keyword()) :: {:ok, Git.result()} | {:error, Git.result()}
  def remove(bare, path, opts \\ []) do
    args = ["worktree", "remove"] ++ if(opts[:force], do: ["--force"], else: []) ++ [path]
    Git.run(args, cd: bare, locks: true)
  end

  @spec prune(Path.t(), keyword()) :: {:ok, Git.result()} | {:error, Git.result()}
  def prune(bare, opts \\ []) do
    args = ["worktree", "prune"] ++ if(opts[:dry_run], do: ["--dry-run", "-v"], else: [])
    Git.run(args, cd: bare, locks: true)
  end

  @spec list(Path.t()) :: {:ok, [%__MODULE__{}]} | {:error, Git.result()}
  def list(bare) do
    case Git.run(["worktree", "list", "--porcelain", "-z"], cd: bare) do
      {:ok, %{stdout: out}} -> {:ok, parse(out)}
      {:error, _} = error -> error
    end
  end

  @spec list!(Path.t()) :: [%__MODULE__{}]
  def list!(bare) do
    {:ok, worktrees} = list(bare)
    worktrees
  end

  @doc false
  def parse(output) do
    output
    |> String.split("\0\0", trim: true)
    |> Enum.map(&parse_record/1)
  end

  defp parse_record(record) do
    [first | fields] = String.split(record, "\0", trim: true)
    "worktree " <> path = first
    Enum.reduce(fields, %__MODULE__{path: path}, &parse_field/2)
  end

  defp parse_field("HEAD " <> sha, acc), do: %{acc | head: sha}
  defp parse_field("branch " <> ref, acc), do: %{acc | branch: ref}
  defp parse_field("detached", acc), do: %{acc | detached: true}
  defp parse_field("bare", acc), do: %{acc | bare: true}
  defp parse_field("locked", acc), do: %{acc | locked: true}
  defp parse_field("locked " <> reason, acc), do: %{acc | locked: reason}
  defp parse_field("prunable", acc), do: %{acc | prunable: true}
  defp parse_field("prunable " <> reason, acc), do: %{acc | prunable: reason}
  defp parse_field(_unknown, acc), do: acc

  def branch_name(%__MODULE__{branch: nil}), do: nil
  def branch_name(%__MODULE__{branch: "refs/heads/" <> name}), do: name
end
