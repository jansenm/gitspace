defmodule Gitspace.Git.Refs do
  @moduledoc "Upstream, ahead/behind and the crucial 'exists nowhere else' count."

  alias Gitspace.{Git, Layout}
  alias Gitspace.Git.{Status, Worktree}

  @type ref_info :: %{
          kind: :local_branch | :remote_branch | :tag | :commit,
          name: String.t(),
          branch: String.t() | nil,
          start: String.t(),
          sha: String.t()
        }

  @doc """
  Classifies and resolves a user-supplied ref in a mirror.

  Local branches win over remote branches, then tags, then a commit-ish. The
  returned `branch` is the local branch name a checkout would use, or `nil`
  when the ref is only usable detached.
  """
  @spec resolve(Path.t(), String.t()) :: {:ok, ref_info()} | {:error, :not_found | :invalid_ref}
  def resolve(bare, ref) when is_binary(ref) do
    ref = String.trim(ref)

    if not Layout.valid_ref?(ref) do
      {:error, :invalid_ref}
    else
      case strip_origin(ref) do
        ^ref ->
          cond do
            info = local_info(bare, ref) -> {:ok, info}
            info = remote_info(bare, ref) -> {:ok, info}
            info = tag_info(bare, ref) -> {:ok, info}
            true -> commit_info(bare, ref)
          end

        remote_name ->
          case remote_info(bare, remote_name) do
            nil -> commit_info(bare, ref)
            info -> {:ok, info}
          end
      end
    end
  end

  @doc "Resolves the repository's default branch, preferring the remote-tracking ref."
  @spec resolve_default(Path.t(), String.t()) ::
          {:ok, ref_info()} | {:error, :not_found | :invalid_ref}
  def resolve_default(bare, default) do
    case resolve(bare, "origin/" <> default) do
      {:ok, info} -> {:ok, info}
      {:error, :invalid_ref} -> {:error, :invalid_ref}
      {:error, :not_found} -> resolve(bare, default)
    end
  end

  @doc "The worktree currently holding a local branch, if any."
  @spec branch_checked_out(Path.t(), String.t()) :: %Worktree{} | nil
  def branch_checked_out(bare, branch) do
    case Worktree.list(bare) do
      {:ok, entries} -> Enum.find(entries, &(&1.branch == "refs/heads/#{branch}"))
      {:error, _} -> nil
    end
  end

  @spec local_branch?(Path.t(), String.t()) :: boolean()
  def local_branch?(bare, branch), do: commit_sha(bare, "refs/heads/#{branch}") != nil

  defp local_info(bare, name) do
    case commit_sha(bare, "refs/heads/#{name}") do
      nil ->
        nil

      sha ->
        %{kind: :local_branch, name: name, branch: name, start: "refs/heads/#{name}", sha: sha}
    end
  end

  defp remote_info(bare, name) do
    case commit_sha(bare, "refs/remotes/origin/#{name}") do
      nil ->
        nil

      sha ->
        %{
          kind: :remote_branch,
          name: name,
          branch: name,
          start: "refs/remotes/origin/#{name}",
          sha: sha
        }
    end
  end

  defp tag_info(bare, name) do
    case commit_sha(bare, "refs/tags/#{name}") do
      nil ->
        nil

      sha ->
        %{kind: :tag, name: name, branch: nil, start: "refs/tags/#{name}", sha: sha}
    end
  end

  defp commit_info(bare, ref) do
    case commit_sha(bare, ref) do
      nil -> {:error, :not_found}
      sha -> {:ok, %{kind: :commit, name: ref, branch: nil, start: sha, sha: sha}}
    end
  end

  defp commit_sha(bare, rev) do
    case Git.run(["rev-parse", "--verify", "--quiet", rev <> "^{commit}"], cd: bare) do
      {:ok, %{stdout: out}} ->
        case String.trim(out) do
          "" -> nil
          sha -> sha
        end

      {:error, _} ->
        nil
    end
  end

  defp strip_origin("origin/" <> rest), do: rest
  defp strip_origin(ref), do: ref

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
