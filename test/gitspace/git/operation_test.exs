defmodule Gitspace.Git.OperationTest do
  use ExUnit.Case, async: true

  alias Gitspace.Fixtures
  alias Gitspace.Git.Operation

  setup do
    source = Fixtures.source_repo!()
    bare = Fixtures.mirror!(source)
    path = Fixtures.worktree!(bare, "origin/main")
    %{path: path}
  end

  test "a clean checkout has no operation", %{path: path} do
    assert Operation.read(path) == nil
  end

  test "reads rebase progress from a worktree git dir", %{path: path} do
    git_dir = git_dir(path)
    state = Path.join(git_dir, "rebase-merge")
    File.mkdir_p!(state)
    File.write!(Path.join(state, "head-name"), "refs/heads/feature/x\n")
    File.write!(Path.join(state, "onto"), "0123456789abcdef0123456789abcdef01234567\n")
    File.write!(Path.join(state, "msgnum"), "2\n")
    File.write!(Path.join(state, "end"), "5\n")

    assert %{kind: :rebase} = operation = Operation.read(path)
    assert operation.branch == "feature/x"
    assert operation.step == 2
    assert operation.total == 5
    assert Operation.describe(operation) =~ "rebase in progress (2/5)"
    assert Operation.rebase?(operation)
  end

  test "detects a merge marker", %{path: path} do
    File.write!(Path.join(git_dir(path), "MERGE_HEAD"), "0123456789abcdef\n")

    assert %{kind: :merge} = operation = Operation.read(path)
    assert Operation.describe(operation) == "merge in progress"
  end

  defp git_dir(path) do
    dot_git = Path.join(path, ".git")

    if File.dir?(dot_git) do
      dot_git
    else
      [_, dir] = Regex.run(~r/^gitdir:\s*(.+)$/m, File.read!(dot_git))
      dir |> String.trim() |> Path.expand(path)
    end
  end
end
