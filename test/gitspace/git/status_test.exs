defmodule Gitspace.Git.StatusTest do
  use ExUnit.Case, async: true

  alias Gitspace.Fixtures
  alias Gitspace.Git.Status

  setup do
    source = Fixtures.source_repo!()
    bare = Fixtures.mirror!(source)
    %{source: source, bare: bare}
  end

  test "clean detached checkout", %{bare: bare} do
    path = Fixtures.worktree!(bare, "origin/main")
    status = Status.read!(path)

    assert status.dirty == 0
    assert status.untracked == 0
    assert status.detached
    assert status.branch == nil
    assert status.head =~ ~r/^[0-9a-f]{40}$/
  end

  test "counts modified tracked files", %{bare: bare} do
    path = Fixtures.worktree!(bare, "origin/main")
    File.write!(Path.join(path, "README.md"), "changed\n")

    assert Status.read!(path).dirty == 1
  end

  test "counts untracked files", %{bare: bare} do
    path = Fixtures.worktree!(bare, "origin/main")
    File.write!(Path.join(path, "new.txt"), "new\n")

    assert Status.read!(path).untracked == 1
  end

  test "reports branch, upstream and ahead", %{bare: bare} do
    path = Fixtures.worktree!(bare, "origin/main", detach: false, branch: "main")
    Fixtures.write(path, "change.txt", "change\n")
    Fixtures.commit!(path, "local work")

    status = Status.read!(path)

    assert status.branch == "main"
    assert status.upstream == "origin/main"
    assert status.ahead == 1
    assert status.behind == 0
  end

  test "reports behind after a fetch", %{source: source, bare: bare} do
    path = Fixtures.worktree!(bare, "origin/main", detach: false, branch: "main")

    Fixtures.write(source, "upstream.txt", "upstream\n")
    Fixtures.commit!(source, "upstream work")
    Gitspace.Git.Mirror.fetch!(bare)

    status = Status.read!(path)

    assert status.ahead == 0
    assert status.behind == 1
  end
end
