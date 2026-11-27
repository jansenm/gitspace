defmodule Gitspace.Git.History do
  @moduledoc """
  Outgoing and incoming commits between a checkout and its upstream.

  `outgoing` is what a push would send. `incoming` is what a rebase would
  integrate: the branch's recorded base when it has one, otherwise its
  upstream, otherwise `origin/<default>` when that ref exists. A branch whose
  configured upstream does not exist yet is reported as not comparable.
  """

  alias Gitspace.Git
  alias Gitspace.Git.{Refs, Status}

  @format "%H%x09%h%x09%an%x09%aI%x09%s"

  @type commit :: %{
          sha: String.t(),
          short: String.t(),
          author: String.t(),
          date: String.t(),
          subject: String.t()
        }

  @type side :: %{
          enabled: boolean(),
          base: String.t() | nil,
          total: non_neg_integer(),
          commits: [commit()],
          truncated: boolean()
        }

  @type t :: %{
          branch: String.t() | nil,
          detached: boolean(),
          upstream: String.t() | nil,
          outgoing: side(),
          incoming: side()
        }

  @doc """
  Reads divergence for one checkout.

  Options: `:limit` (positive integer or nil for all), `:directions`
  (`[:outgoing, :incoming]` by default) and `:default_branch` (used for the
  incoming side when no upstream is configured).
  """
  @spec read(Path.t(), keyword()) :: {:ok, t()} | {:error, term()}
  def read(worktree, opts \\ []) do
    with {:ok, status} <- Status.read(worktree) do
      limit = Keyword.get(opts, :limit)
      directions = Keyword.get(opts, :directions, [:outgoing, :incoming])
      default_branch = Keyword.get(opts, :default_branch)
      upstream = Refs.upstream_ref(worktree, status)

      outgoing =
        read_side(
          worktree,
          Refs.unpushed_range(worktree, status),
          upstream,
          limit,
          :outgoing in directions
        )

      incoming_ref = incoming_ref(worktree, status, default_branch)

      incoming =
        read_side(
          worktree,
          if(incoming_ref, do: ["HEAD..#{incoming_ref}"], else: nil),
          incoming_ref,
          limit,
          :incoming in directions
        )

      {:ok,
       %{
         branch: status.branch,
         detached: status.detached,
         upstream: upstream,
         outgoing: outgoing,
         incoming: incoming
       }}
    end
  end

  defp read_side(_worktree, _args, base, _limit, false) do
    %{enabled: false, base: base, total: 0, commits: [], truncated: false}
  end

  defp read_side(_worktree, nil, _base, _limit, true) do
    %{enabled: true, base: nil, total: 0, commits: [], truncated: false}
  end

  defp read_side(worktree, args, base, limit, true) do
    commits = log(worktree, args, limit)
    total = total(worktree, args, commits, limit)

    %{
      enabled: true,
      base: base,
      total: total,
      commits: commits,
      truncated: total > length(commits)
    }
  end

  defp incoming_ref(worktree, status, default_branch) do
    case Refs.rebase_base(worktree, status) do
      {:ok, ref} -> ref
      {:missing, _ref} -> nil
      :none -> default_remote_ref(worktree, default_branch)
    end
  end

  defp default_remote_ref(_worktree, default_branch)
       when not is_binary(default_branch) or default_branch == "",
       do: nil

  defp default_remote_ref(worktree, default_branch) do
    ref = "origin/" <> default_branch

    if ref_exists?(worktree, "refs/remotes/" <> ref), do: ref, else: nil
  end

  defp ref_exists?(worktree, ref) do
    case Git.run(["rev-parse", "--verify", "--quiet", ref <> "^{commit}"], cd: worktree) do
      {:ok, %{stdout: out}} -> String.trim(out) != ""
      {:error, _} -> false
    end
  end

  defp total(_worktree, _args, commits, nil), do: length(commits)

  defp total(worktree, args, commits, limit) do
    if length(commits) < limit do
      length(commits)
    else
      max(count(worktree, args), length(commits))
    end
  end

  defp count(worktree, args) do
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

  defp log(worktree, args, limit) do
    limit_args = if is_integer(limit), do: ["-n", Integer.to_string(limit)], else: []

    case Git.run(["log", "--format=#{@format}" | limit_args] ++ args, cd: worktree) do
      {:ok, %{stdout: out}} -> out |> String.split("\n", trim: true) |> Enum.flat_map(&parse/1)
      {:error, _} -> []
    end
  end

  defp parse(line) do
    case String.split(line, "\t", parts: 5) do
      [sha, short, author, date, subject] ->
        [%{sha: sha, short: short, author: author, date: date, subject: subject}]

      _ ->
        []
    end
  end
end
