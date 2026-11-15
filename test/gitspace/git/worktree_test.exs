defmodule Gitspace.Git.WorktreeTest do
  use ExUnit.Case, async: true

  alias Gitspace.{Fixtures, Git}

  setup do
    source = Fixtures.source_repo!()
    bare = Fixtures.mirror!(source)
    %{source: source, bare: bare}
  end

  test "adds a detached worktree at origin/main", %{bare: bare} do
    path = Fixtures.worktree!(bare, "origin/main")

    assert File.dir?(path)
    assert Git.run!(["rev-parse", "--abbrev-ref", "HEAD"], cd: path) |> String.trim() == "HEAD"
  end

  test "adds a tracking branch", %{bare: bare} do
    path = Fixtures.worktree!(bare, "origin/main", detach: false, branch: "main")

    assert Git.run!(["rev-parse", "--abbrev-ref", "HEAD"], cd: path) |> String.trim() == "main"

    assert Git.run!(["rev-parse", "--abbrev-ref", "@{u}"], cd: path) |> String.trim() ==
             "origin/main"
  end

  test "refuses a second worktree on the same branch", %{bare: bare} do
    Fixtures.worktree!(bare, "origin/main", detach: false, branch: "main")

    path = Path.join(Fixtures.tmp_dir!("wt"), "second")

    assert {:error, result} = Gitspace.Git.Worktree.add(bare, path, "main")
    assert result.stderr =~ "already used by worktree"
  end

  test "lists the bare entry and the worktrees", %{bare: bare} do
    path = Fixtures.worktree!(bare, "origin/main")
    worktrees = Gitspace.Git.Worktree.list!(bare)

    assert Enum.any?(worktrees, & &1.bare)
    assert Enum.any?(worktrees, &(&1.path == path and &1.detached))
  end

  test "marks a deleted directory as prunable", %{bare: bare} do
    path = Fixtures.worktree!(bare, "origin/main")
    File.rm_rf!(path)

    worktrees = Gitspace.Git.Worktree.list!(bare)
    entry = Enum.find(worktrees, &(&1.path == path))

    assert entry
    assert is_binary(entry.prunable)
    assert entry.prunable =~ "non-existent"
  end

  test "refuses dirty removal without force", %{bare: bare} do
    path = Fixtures.worktree!(bare, "origin/main")
    File.write!(Path.join(path, "dirty.txt"), "x")

    assert {:error, _} = Gitspace.Git.Worktree.remove(bare, path)
    assert {:ok, _} = Gitspace.Git.Worktree.remove(bare, path, force: true)
    refute File.dir?(path)
  end
end
