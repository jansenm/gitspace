defmodule Gitspace.Git.Rebase do
  @moduledoc """
  Starts, continues and aborts a non-interactive rebase onto the upstream.

  A rebase is only started on a clean, attached checkout with a resolvable
  upstream. Conflicts are left in place for the user to resolve; the CLI turns
  them into a per-worktree result and keeps going with the remaining worktrees.
  """

  alias Gitspace.Git
  alias Gitspace.Git.{Operation, Refs, Status}

  @editors [{"GIT_EDITOR", "true"}, {"GIT_SEQUENCE_EDITOR", "true"}]

  @type status :: :rebased | :up_to_date | :conflict | :aborted

  @type result :: %{
          status: status(),
          branch: String.t() | nil,
          upstream: String.t() | nil,
          old_head: String.t() | nil,
          new_head: String.t() | nil,
          commits: non_neg_integer() | nil,
          step: non_neg_integer() | nil,
          total: non_neg_integer() | nil,
          files: [String.t()],
          output: String.t(),
          hint: String.t() | nil
        }

  @type failure :: %{
          kind: :refused | :conflict | :error,
          message: String.t(),
          hint: String.t() | nil
        }

  @spec start(Path.t()) :: {:ok, result()} | {:error, failure()}
  def start(worktree) do
    with {:ok, status} <- Status.read(worktree),
         :ok <- ensure_clean(status),
         :ok <- ensure_branch(status),
         :ok <- ensure_no_operation(worktree),
         {:ok, upstream} <- ensure_upstream(worktree, status) do
      old_head = head(worktree)
      commits = count(worktree, ["#{upstream}..HEAD"])

      case rebase(worktree, ["rebase", upstream]) do
        {:ok, output} ->
          new_head = head(worktree)

          {:ok,
           %{
             status: if(new_head == old_head, do: :up_to_date, else: :rebased),
             branch: status.branch,
             upstream: upstream,
             old_head: old_head,
             new_head: new_head,
             commits: commits,
             step: nil,
             total: nil,
             files: [],
             output: output,
             hint: nil
           }}

        {:conflict, output, operation} ->
          {:ok,
           conflict(worktree, output, operation, %{
             branch: status.branch,
             upstream: upstream,
             old_head: old_head,
             commits: commits
           })}

        {:error, output} ->
          {:error, failure(:error, last_line(output), "git rebase failed")}
      end
    end
  end

  @spec continue(Path.t()) :: {:ok, result()} | {:error, failure()}
  def continue(worktree) do
    with {:ok, operation} <- ensure_rebase(worktree) do
      case rebase(worktree, ["rebase", "--continue"]) do
        {:ok, output} ->
          {:ok,
           %{
             status: :rebased,
             branch: operation.branch,
             upstream: operation.onto,
             old_head: nil,
             new_head: head(worktree),
             commits: nil,
             step: nil,
             total: nil,
             files: [],
             output: output,
             hint: nil
           }}

        {:conflict, output, next_operation} ->
          {:ok,
           conflict(worktree, output, next_operation, %{
             branch: operation.branch,
             upstream: operation.onto,
             old_head: nil,
             commits: nil
           })}

        {:error, output} ->
          {:error, failure(:error, last_line(output), "git rebase --continue failed")}
      end
    end
  end

  @spec abort(Path.t()) :: {:ok, result()} | {:error, failure()}
  def abort(worktree) do
    with {:ok, operation} <- ensure_rebase(worktree) do
      case Git.run(["rebase", "--abort"], cd: worktree, env: @editors) do
        {:ok, output} ->
          {:ok,
           %{
             status: :aborted,
             branch: operation.branch,
             upstream: operation.onto,
             old_head: nil,
             new_head: head(worktree),
             commits: nil,
             step: nil,
             total: nil,
             files: [],
             output: output.stdout <> output.stderr,
             hint: nil
           }}

        {:error, result} ->
          {:error,
           failure(:error, last_line(result.stdout <> result.stderr), "git rebase --abort failed")}
      end
    end
  end

  defp conflict(worktree, output, operation, context) do
    %{
      status: :conflict,
      branch: context.branch,
      upstream: context.upstream,
      old_head: context.old_head,
      new_head: nil,
      commits: context.commits,
      step: operation.step,
      total: operation.total,
      files: conflict_files(worktree),
      output: output,
      hint:
        "resolve the conflicts, stage them with git add, then run " <>
          "`gitspace rebase --continue <target>`; or `gitspace rebase --abort <target>`"
    }
  end

  defp rebase(worktree, args) do
    case Git.run(args, cd: worktree, env: @editors, timeout: 300_000) do
      {:ok, result} ->
        {:ok, result.stdout <> result.stderr}

      {:error, result} ->
        output = result.stdout <> result.stderr

        case Operation.read(worktree) do
          %{kind: :rebase} = operation -> {:conflict, output, operation}
          _ -> {:error, output}
        end
    end
  end

  defp ensure_clean(%Status{dirty: dirty, untracked: untracked})
       when dirty > 0 or untracked > 0 do
    {:error,
     failure(:refused, "working tree is not clean", "commit or stash changes before rebasing")}
  end

  defp ensure_clean(_status), do: :ok

  defp ensure_branch(%Status{detached: true}) do
    {:error, failure(:refused, "detached HEAD", "check out a branch before rebasing")}
  end

  defp ensure_branch(%Status{branch: nil}) do
    {:error, failure(:refused, "no branch checked out", "check out a branch before rebasing")}
  end

  defp ensure_branch(_status), do: :ok

  defp ensure_no_operation(worktree) do
    case Operation.read(worktree) do
      nil ->
        :ok

      operation ->
        {:error,
         failure(:refused, Operation.describe(operation), "finish or abort it before rebasing")}
    end
  end

  defp ensure_rebase(worktree) do
    case Operation.read(worktree) do
      %{kind: :rebase} = operation ->
        {:ok, operation}

      nil ->
        {:error, failure(:refused, "no rebase in progress", nil)}

      operation ->
        {:error,
         failure(:refused, Operation.describe(operation), "only a rebase can be continued here")}
    end
  end

  defp ensure_upstream(worktree, status) do
    case Refs.upstream_ref(worktree, status) do
      nil ->
        if is_binary(status.upstream) do
          {:error,
           failure(:refused, "upstream #{status.upstream} does not exist yet",
             hint: "push the branch first with `gitspace push`"
           )}
        else
          {:error,
           failure(:refused, "no upstream configured",
             hint: "push the branch first with `gitspace push`"
           )}
        end

      upstream ->
        {:ok, upstream}
    end
  end

  defp conflict_files(worktree) do
    case Git.run(["diff", "--name-only", "--diff-filter=U"], cd: worktree) do
      {:ok, %{stdout: out}} -> String.split(out, "\n", trim: true)
      {:error, _} -> []
    end
  end

  defp head(worktree) do
    case Git.run(["rev-parse", "HEAD"], cd: worktree) do
      {:ok, %{stdout: out}} -> String.trim(out)
      {:error, _} -> nil
    end
  end

  defp count(worktree, args) do
    case Git.run(["rev-list", "--count" | args], cd: worktree) do
      {:ok, %{stdout: out}} ->
        case Integer.parse(String.trim(out)) do
          {count, _} -> count
          :error -> 0
        end

      {:error, _} ->
        0
    end
  end

  defp last_line(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.reject(&String.starts_with?(&1, ["warning:", "hint:"]))
    |> List.last()
    |> case do
      nil -> "git rebase failed"
      line -> line |> String.replace_prefix("error: ", "") |> String.replace_prefix("fatal: ", "")
    end
  end

  defp failure(kind, message, hint), do: %{kind: kind, message: message, hint: hint}
end
