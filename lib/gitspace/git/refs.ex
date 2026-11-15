defmodule Gitspace.Git.Refs do
  @moduledoc "Upstream, ahead/behind and the crucial 'exists nowhere else' count."

  alias Gitspace.Git
  alias Gitspace.Git.Status

  @spec upstream(Path.t()) :: {:ok, String.t()} | :none
  def upstream(worktree) do
    args = ["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}"]

    case Git.run(args, cd: worktree) do
      {:ok, %{stdout: out}} ->
        case String.trim(out) do
          "" -> :none
          ref -> {:ok, ref}
        end

      {:error, _} ->
        :none
    end
  end

  @doc """
  Number of commits that would be lost if this checkout were removed.

  - with an upstream: commits ahead of the upstream
  - a local branch without upstream: commits not on any remote or tag
  - detached HEAD: commits not reachable from any branch, remote or tag
  """
  @spec unpushed(Path.t(), %Status{}) :: non_neg_integer()
  def unpushed(worktree, %Status{} = status) do
    cond do
      status.detached ->
        count(["HEAD", "--not", "--branches", "--remotes", "--tags"], worktree)

      upstream = status.upstream || upstream_name(worktree) ->
        count(["#{upstream}..HEAD"], worktree)

      true ->
        count(["HEAD", "--not", "--remotes", "--tags"], worktree)
    end
  end

  defp upstream_name(worktree) do
    case upstream(worktree) do
      {:ok, ref} -> ref
      :none -> nil
    end
  end

  defp count(args, worktree) do
    case Git.run(["rev-list", "--count" | args], cd: worktree) do
      {:ok, %{stdout: out}} ->
        case Integer.parse(String.trim(out)) do
          {n, _} -> n
          :error -> 0
        end

      {:error, _} ->
        0
    end
  end
end
