defmodule Gitspace.Git.Publish do
  @moduledoc """
  Pushes one checkout's branch to a remote branch of the same name.

  The refspec is explicit (`HEAD:refs/heads/<branch>`), so a branch that
  happens to track a differently named upstream never pushes to that branch.
  `--set-upstream` then points the branch at the branch that was pushed.
  """

  alias Gitspace.Git
  alias Gitspace.Git.{Status}

  @type status :: :pushed | :up_to_date | :rejected | :would_push | :would_reject

  @type result :: %{
          status: status(),
          remote: String.t(),
          branch: String.t(),
          upstream: String.t(),
          commits: non_neg_integer(),
          dirty: non_neg_integer(),
          untracked: non_neg_integer(),
          output: String.t(),
          reason: String.t() | nil,
          hint: String.t() | nil,
          note: String.t() | nil,
          force: :force | :force_with_lease | nil
        }

  @type failure :: %{
          kind: :refused | :conflict | :error,
          message: String.t(),
          hint: String.t() | nil
        }

  @doc """
  Pushes the checked-out branch.

  Options: `:dry_run`, `:remote` (overrides remote selection) and `:force`
  (`:force` or `:force_with_lease`). The explicit refspec keeps the pushed
  branch equal to the local branch name even when forcing.
  """
  @spec run(Path.t(), keyword()) :: {:ok, result()} | {:error, failure()}
  def run(worktree, opts \\ []) do
    dry_run? = !!opts[:dry_run]
    force = opts[:force]

    with {:ok, status} <- Status.read(worktree),
         :ok <- ensure_branch(status),
         {:ok, remote} <- select_remote(worktree, status, opts[:remote]) do
      execute(worktree, status, remote, dry_run?, force)
    else
      {:error, %{kind: _} = failure} -> {:error, failure}
      {:error, other} -> {:error, failure_from_error(other)}
    end
  end

  defp ensure_branch(%Status{detached: true}) do
    {:error, failure(:refused, "detached HEAD", "check out a branch before pushing")}
  end

  defp ensure_branch(%Status{branch: nil}) do
    {:error, failure(:refused, "no branch checked out", "check out a branch before pushing")}
  end

  defp ensure_branch(_status), do: :ok

  defp select_remote(worktree, status, override) do
    remotes = remotes(worktree)

    cond do
      is_binary(override) and override not in remotes ->
        {:error,
         failure(
           :refused,
           "unknown remote: #{override}",
           "available: #{Enum.join(remotes, ", ")}"
         )}

      is_binary(override) ->
        {:ok, override}

      remotes == [] ->
        {:error,
         failure(
           :refused,
           "no git remote in this checkout",
           "adopt an upstream with `gitspace repo set-url` or add one with `git remote add`"
         )}

      true ->
        case upstream_remote(status.upstream) do
          nil -> prefer_remote(remotes)
          remote -> if remote in remotes, do: {:ok, remote}, else: prefer_remote(remotes)
        end
    end
  end

  defp prefer_remote(remotes) do
    cond do
      "origin" in remotes ->
        {:ok, "origin"}

      length(remotes) == 1 ->
        {:ok, hd(remotes)}

      true ->
        {:error,
         failure(
           :refused,
           "multiple remotes, refusing to guess",
           "use --remote with one of: #{Enum.join(remotes, ", ")}"
         )}
    end
  end

  defp remotes(worktree) do
    case Git.run(["remote"], cd: worktree) do
      {:ok, %{stdout: out}} -> out |> String.split("\n", trim: true) |> Enum.map(&String.trim/1)
      {:error, _} -> []
    end
  end

  defp upstream_remote(nil), do: nil

  defp upstream_remote(upstream) do
    case String.split(upstream, "/", parts: 2) do
      [remote, _branch] when remote != "" -> remote
      _ -> nil
    end
  end

  defp execute(worktree, status, remote, dry_run?, force) do
    branch = status.branch
    upstream = "#{remote}/#{branch}"
    refspec = "HEAD:refs/heads/#{branch}"

    args =
      ["push", "--porcelain", "--set-upstream"] ++
        force_args(force) ++
        if(dry_run?, do: ["--dry-run"], else: []) ++ [remote, refspec]

    commits = commits_not_on_remotes(worktree)

    case Git.run(args, cd: worktree, timeout: 300_000) do
      {:ok, result} ->
        {:ok, build(result, status, remote, upstream, commits, dry_run?, force)}

      {:error, result} ->
        output = result.stdout <> result.stderr

        if rejected?(output) do
          {:ok, build(result, status, remote, upstream, commits, dry_run?, force)}
        else
          {:error, failure(:error, error_line(output), "git push failed")}
        end
    end
  end

  defp force_args(:force), do: ["--force"]
  defp force_args(:force_with_lease), do: ["--force-with-lease"]
  defp force_args(nil), do: []

  defp build(result, status, remote, upstream, commits, dry_run?, force) do
    output = result.stdout <> result.stderr
    status_name = classify(output, dry_run?)

    %{
      status: status_name,
      remote: remote,
      branch: status.branch,
      upstream: upstream,
      commits: commits,
      dirty: status.dirty,
      untracked: status.untracked,
      output: output,
      reason: rejection_reason(output),
      hint: hint(status_name, output),
      note: note(status, upstream),
      force: force
    }
  end

  defp classify(output, dry_run?) do
    cond do
      rejected?(output) -> if dry_run?, do: :would_reject, else: :rejected
      up_to_date?(output) -> :up_to_date
      true -> if dry_run?, do: :would_push, else: :pushed
    end
  end

  defp rejected?(output) do
    String.contains?(output, "[rejected]") or String.contains?(output, "non-fast-forward") or
      String.contains?(output, "fetch first")
  end

  defp up_to_date?(output) do
    String.contains?(output, "[up to date]") or String.contains?(output, "Everything up-to-date")
  end

  defp rejection_reason(output) do
    output
    |> String.split("\n")
    |> Enum.find(&String.starts_with?(&1, "!"))
    |> case do
      nil -> nil
      line -> line |> String.split("\t") |> List.last() |> String.trim()
    end
  end

  defp hint(:rejected, output) do
    if String.contains?(output, "stale info") do
      "fetch the remote branch first so --force-with-lease has a current lease"
    else
      "fetch and integrate the remote commits first, then push again"
    end
  end

  defp hint(_status, _output), do: nil

  defp note(%Status{upstream: upstream}, upstream), do: nil

  defp note(%Status{upstream: current}, pushed) when is_binary(current) do
    "upstream #{current} did not match the pushed branch and is updated to #{pushed}"
  end

  defp note(_status, _pushed), do: nil

  defp commits_not_on_remotes(worktree) do
    case Git.run(["rev-list", "--count", "HEAD", "--not", "--remotes"], cd: worktree) do
      {:ok, %{stdout: out}} ->
        case Integer.parse(String.trim(out)) do
          {count, _} -> count
          :error -> 0
        end

      {:error, _} ->
        0
    end
  end

  defp failure(kind, message, hint), do: %{kind: kind, message: message, hint: hint}

  defp failure_from_error(%{stderr: stderr}) when is_binary(stderr) and stderr != "" do
    failure(:error, String.trim(stderr), nil)
  end

  defp failure_from_error(other), do: failure(:error, inspect(other), nil)

  defp error_line(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.reject(&String.starts_with?(&1, ["warning:", "hint:"]))
    |> List.last()
    |> case do
      nil -> "git push failed"
      line -> line |> String.replace_prefix("error: ", "") |> String.replace_prefix("fatal: ", "")
    end
  end
end
