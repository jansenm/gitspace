defmodule Gitspace.Git.Mirror do
  @moduledoc """
  Creates and updates a bare mirror.

  Mirrors normally start with `git init --bare`, a remote and a fetch. When an
  existing checkout is available, the mirror can instead be cloned with
  `--reference <checkout> --dissociate`, borrowing its local objects and then
  disconnecting from it. Remote branches live under `refs/remotes/origin/*`,
  like a normal clone, which keeps fetch safe while a local branch is checked
  out in a worktree.
  """

  alias Gitspace.Git

  @fetch_refspec "+refs/heads/*:refs/remotes/origin/*"

  @spec init!(Path.t(), String.t(), keyword()) :: Path.t()
  def init!(bare, url, opts \\ []) do
    File.mkdir_p!(Path.dirname(bare))

    case opts[:reference] do
      nil -> init_plain!(bare, url, opts)
      reference -> init_from_reference!(bare, url, reference)
    end

    bare
  end

  @doc "Creates an empty local mirror with no origin; `refs/heads/*` is canonical."
  @spec init_local!(Path.t(), String.t()) :: Path.t()
  def init_local!(bare, branch) do
    File.mkdir_p!(Path.dirname(bare))
    Git.run!(["init", "--bare", "--initial-branch=#{branch}", bare])
    Git.run!(["config", "gc.auto", "0"], cd: bare)
    bare
  end

  defp init_plain!(bare, url, opts) do
    Git.run!(["init", "--bare", "--initial-branch=main", bare])
    Git.run!(["remote", "add", "origin", url], cd: bare)
    Git.run!(["config", "remote.origin.fetch", @fetch_refspec], cd: bare)
    Git.run!(["config", "gc.auto", "0"], cd: bare)

    unless opts[:no_fetch], do: fetch!(bare, opts)
  end

  defp init_from_reference!(bare, url, reference) do
    Git.run!(["clone", "--bare", "--reference", reference, "--dissociate", url, bare])

    default = default_branch_from_head(bare)

    bare
    |> local_branches()
    |> Enum.each(fn {branch, sha} ->
      Git.run!(["update-ref", "refs/remotes/origin/#{branch}", sha], cd: bare)
      Git.run!(["update-ref", "-d", "refs/heads/#{branch}"], cd: bare)
    end)

    Git.run!(["config", "remote.origin.fetch", @fetch_refspec], cd: bare)
    Git.run!(["config", "gc.auto", "0"], cd: bare)
    set_origin_head(bare, default)
  end

  defp local_branches(bare) do
    case Git.run(
           ["for-each-ref", "--format=%(refname:strip=2) %(objectname)", "refs/heads"],
           cd: bare
         ) do
      {:ok, %{stdout: out}} ->
        out
        |> String.split("\n", trim: true)
        |> Enum.map(fn line ->
          [branch, sha] = String.split(line, " ", parts: 2)
          {branch, sha}
        end)

      {:error, _} ->
        []
    end
  end

  defp default_branch_from_head(bare) do
    case Git.run(["symbolic-ref", "--short", "HEAD"], cd: bare) do
      {:ok, %{stdout: out}} ->
        case String.trim(out) do
          "" -> nil
          branch -> branch
        end

      {:error, _} ->
        nil
    end
  end

  defp set_origin_head(_bare, nil), do: :ok

  defp set_origin_head(bare, branch) do
    case Git.run(
           ["symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/#{branch}"],
           cd: bare
         ) do
      {:ok, _} -> :ok
      {:error, _} -> :ok
    end
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
