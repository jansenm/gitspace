defmodule Gitspace.Git.Mirror do
  @moduledoc """
  Creates and updates a bare mirror.

  `git clone --bare` writes no fetch refspec (verified on git 2.56), so the
  mirror is created explicitly. Remote branches live under
  `refs/remotes/origin/*`, like a normal clone, which keeps fetch safe while a
  local branch is checked out in a worktree.
  """

  alias Gitspace.Git

  @fetch_refspec "+refs/heads/*:refs/remotes/origin/*"

  @spec init!(Path.t(), String.t(), keyword()) :: Path.t()
  def init!(bare, url, opts \\ []) do
    File.mkdir_p!(Path.dirname(bare))

    Git.run!(["init", "--bare", "--initial-branch=main", bare])
    Git.run!(["remote", "add", "origin", url], cd: bare)
    Git.run!(["config", "remote.origin.fetch", @fetch_refspec], cd: bare)
    Git.run!(["config", "gc.auto", "0"], cd: bare)

    unless opts[:no_fetch], do: fetch!(bare, opts)

    bare
  end

  @spec fetch!(Path.t(), keyword()) :: binary()
  def fetch!(bare, opts \\ []) do
    output =
      Git.run!(["fetch", "--prune", "origin"],
        cd: bare,
        locks: true,
        timeout: Keyword.get(opts, :timeout, 300_000)
      )

    set_head!(bare)
    output
  end

  @spec set_head!(Path.t()) :: :ok
  def set_head!(bare) do
    case Git.run(["remote", "set-head", "origin", "--auto"], cd: bare) do
      {:ok, _} -> :ok
      {:error, _} -> :ok
    end
  end

  @spec default_branch(Path.t()) :: String.t() | nil
  def default_branch(bare) do
    case Git.run(["symbolic-ref", "--short", "refs/remotes/origin/HEAD"], cd: bare) do
      {:ok, %{stdout: out}} ->
        out
        |> String.trim()
        |> String.replace_prefix("origin/", "")

      {:error, _} ->
        nil
    end
  end
end
