defmodule Gitspace.Git.Operation do
  @moduledoc """
  Detects a merge, rebase, cherry-pick or revert in progress from the git dir.

  The check is pure file I/O: worktrees point at their git dir through a
  `.git` file, which is resolved and inspected for the state directories and
  marker files git leaves behind. This keeps `ls` and the inbox cheap enough to
  report operations without a git subprocess per checkout.
  """

  @type kind :: :rebase | :merge | :cherry_pick | :revert

  @type t :: %{
          kind: kind(),
          branch: String.t() | nil,
          onto: String.t() | nil,
          step: non_neg_integer() | nil,
          total: non_neg_integer() | nil
        }

  @spec read(Path.t()) :: t() | nil
  def read(worktree) do
    case git_dir(worktree) do
      nil ->
        nil

      dir ->
        cond do
          File.dir?(Path.join(dir, "rebase-merge")) ->
            rebase(dir, "rebase-merge", "msgnum", "end")

          File.dir?(Path.join(dir, "rebase-apply")) ->
            rebase(dir, "rebase-apply", "next", "last")

          File.exists?(Path.join(dir, "MERGE_HEAD")) ->
            marker(:merge)

          File.exists?(Path.join(dir, "CHERRY_PICK_HEAD")) ->
            marker(:cherry_pick)

          File.exists?(Path.join(dir, "REVERT_HEAD")) ->
            marker(:revert)

          true ->
            nil
        end
    end
  end

  @spec rebase?(t() | nil) :: boolean()
  def rebase?(%{kind: :rebase}), do: true
  def rebase?(_), do: false

  @spec describe(t()) :: String.t()
  def describe(%{kind: :rebase} = operation) do
    "rebase in progress" <> progress(operation) <> onto(operation)
  end

  def describe(%{kind: :merge}), do: "merge in progress"
  def describe(%{kind: :cherry_pick}), do: "cherry-pick in progress"
  def describe(%{kind: :revert}), do: "revert in progress"

  defp progress(%{step: step, total: total})
       when is_integer(step) and is_integer(total) and total > 0 do
    " (#{step}/#{total})"
  end

  defp progress(_), do: ""

  defp onto(%{onto: onto}) when is_binary(onto), do: " onto #{String.slice(onto, 0, 12)}"
  defp onto(_), do: ""

  defp rebase(dir, state, step_file, total_file) do
    base = Path.join(dir, state)

    %{
      kind: :rebase,
      branch: read_head(base),
      onto: read_text(Path.join(base, "onto")),
      step: read_int(Path.join(base, step_file)),
      total: read_int(Path.join(base, total_file))
    }
  end

  defp read_head(base) do
    case read_text(Path.join(base, "head-name")) do
      "refs/heads/" <> branch -> branch
      other -> other
    end
  end

  defp marker(kind) do
    %{kind: kind, branch: nil, onto: nil, step: nil, total: nil}
  end

  defp read_text(path) do
    case File.read(path) do
      {:ok, body} ->
        case String.trim(body) do
          "" -> nil
          value -> value
        end

      {:error, _} ->
        nil
    end
  end

  defp read_int(path) do
    case read_text(path) do
      nil ->
        nil

      text ->
        case Integer.parse(text) do
          {value, _} -> value
          :error -> nil
        end
    end
  end

  defp git_dir(worktree) do
    dot_git = Path.join(worktree, ".git")

    cond do
      File.dir?(dot_git) ->
        dot_git

      File.regular?(dot_git) ->
        case File.read(dot_git) do
          {:ok, body} ->
            case Regex.run(~r/^gitdir:\s*(.+)$/m, body) do
              [_, path] -> path |> String.trim() |> Path.expand(worktree)
              _ -> nil
            end

          {:error, _} ->
            nil
        end

      true ->
        nil
    end
  end
end
