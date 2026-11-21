defmodule Gitspace.Safety do
  @moduledoc """
  Detects work that exists nowhere else and anchors it before removal.

  These primitives are the reason the tool can delete a checkout safely.
  """

  alias Gitspace.Git
  alias Gitspace.Git.Refs
  alias Gitspace.Git.Status

  @type report :: %{
          head: String.t() | nil,
          branch: String.t() | nil,
          detached: boolean(),
          dirty: non_neg_integer(),
          untracked: non_neg_integer(),
          unpushed: non_neg_integer(),
          at_risk: boolean()
        }

  @spec detect(Path.t()) :: {:ok, report()} | {:error, term()}
  def detect(worktree) do
    with {:ok, status} <- Status.read(worktree) do
      unpushed = Refs.unpushed(worktree, status)

      report = %{
        head: status.head,
        branch: status.branch,
        detached: status.detached,
        dirty: status.dirty,
        untracked: status.untracked,
        unpushed: unpushed,
        at_risk: unpushed > 0 or status.dirty > 0 or status.untracked > 0
      }

      {:ok, report}
    end
  end

  @doc "Anchors HEAD in the mirror so `gc --prune=now` cannot lose it."
  @spec keep!(Path.t(), Path.t(), String.t()) :: {:ok, String.t(), String.t()}
  def keep!(bare, worktree, id) do
    sha = Git.run!(["rev-parse", "HEAD"], cd: worktree) |> String.trim()
    ref = "refs/gitspace/keep/#{sanitize_id(id)}/#{System.system_time(:second)}"
    anchor!(bare, ref, sha)
    {:ok, ref, sha}
  end

  @spec anchor!(Path.t(), String.t(), String.t()) :: :ok
  def anchor!(bare, ref, sha) do
    Git.run!(["update-ref", ref, sha], cd: bare, locks: true)
    :ok
  end

  @doc "Captures tracked changes without touching the working tree."
  @spec stash_create(Path.t()) :: {:ok, String.t()} | :none | {:error, term()}
  def stash_create(worktree) do
    case Git.run(["stash", "create"], cd: worktree, locks: true) do
      {:ok, %{stdout: out}} ->
        case String.trim(out) do
          "" -> :none
          sha -> {:ok, sha}
        end

      {:error, _} = error ->
        error
    end
  end

  @doc "Paths of untracked files, from porcelain v2 -z."
  @spec untracked(Path.t()) :: {:ok, [String.t()]} | {:error, term()}
  def untracked(worktree) do
    args = ["status", "--porcelain=v2", "-z", "--untracked-files=normal"]

    case Git.run(args, cd: worktree) do
      {:ok, %{stdout: out}} ->
        paths =
          out
          |> String.split("\0", trim: true)
          |> Enum.flat_map(fn
            "? " <> path -> [path]
            _ -> []
          end)

        {:ok, paths}

      {:error, _} = error ->
        error
    end
  end

  @doc "Compresses untracked files; Linux v1 uses the system `tar`."
  @spec archive_untracked!(Path.t(), Path.t(), [String.t()]) :: :ok | :empty
  def archive_untracked!(_worktree, _out, []), do: :empty

  def archive_untracked!(worktree, out, paths) do
    tar = System.find_executable("tar") || "tar"

    case System.cmd(tar, ["-czf", out, "-C", worktree | paths], stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {output, code} -> raise "tar failed (#{code}): #{output}"
    end
  end

  @spec bundle!(Path.t(), Path.t(), String.t()) :: :ok
  def bundle!(bare, out, ref) do
    Git.run!(["bundle", "create", out, ref], cd: bare, locks: true)
    :ok
  end

  @doc "The exact commands a user can run to recover an anchored commit."
  @spec restore_hint(String.t(), String.t()) :: String.t()
  def restore_hint(work, keep_ref) do
    "gitspace co <project>@#{keep_ref} --topic #{work}-recovered"
  end

  defp sanitize_id(id) do
    id
    |> String.replace(~r/[^A-Za-z0-9._-]+/, "-")
    |> String.trim("-")
  end
end
