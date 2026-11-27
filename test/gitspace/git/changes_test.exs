defmodule Gitspace.Git.ChangesTest do
  use ExUnit.Case, async: true

  alias Gitspace.Fixtures
  alias Gitspace.Git
  alias Gitspace.Git.Changes

  setup do
    source = Fixtures.source_repo!()
    bare = Fixtures.mirror!(source)
    path = Fixtures.worktree!(bare, "origin/main")
    %{path: path}
  end

  test "lists modified, staged and untracked paths", %{path: path} do
    File.write!(Path.join(path, "README.md"), "# changed\n")
    File.write!(Path.join(path, "untracked.txt"), "new\n")
    Fixtures.write(path, "staged.txt", "staged\n")
    Git.run!(["add", "staged.txt"], cd: path)

    assert {:ok, entries} = Changes.entries(path)

    assert Enum.any?(entries, &(&1.path == "README.md" and &1.status == ".M"))
    assert Enum.any?(entries, &(&1.path == "staged.txt" and &1.status == "A."))
    assert Enum.any?(entries, &(&1.path == "untracked.txt" and &1.untracked))
  end

  test "keeps the source path of a rename", %{path: path} do
    Git.run!(["mv", "README.md", "RENAMED.md"], cd: path)

    assert {:ok, entries} = Changes.entries(path)
    assert [%{path: "RENAMED.md", orig_path: "README.md"}] = Enum.filter(entries, & &1.orig_path)
  end

  test "diffs staged and unstaged changes separately and caps them", %{path: path} do
    File.write!(Path.join(path, "README.md"), "# staged\n")
    Git.run!(["add", "README.md"], cd: path)
    File.write!(Path.join(path, "README.md"), "# unstaged\n")

    assert {:ok, diff} = Changes.diff(path)
    assert diff.staged =~ "+# staged"
    assert diff.unstaged =~ "+# unstaged"
    refute diff.truncated

    assert {:ok, capped} = Changes.diff(path, max_lines: 1)
    assert capped.truncated
    assert capped.staged =~ "truncated" or capped.unstaged =~ "truncated"
  end
end
