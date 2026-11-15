defmodule Gitspace.Git.RefsTest do
  use ExUnit.Case, async: true

  alias Gitspace.Fixtures
  alias Gitspace.Git.{Refs, Status}

  setup do
    source = Fixtures.source_repo!()
    bare = Fixtures.mirror!(source)
    %{bare: bare}
  end

  test "clean detached HEAD has nothing unpushed", %{bare: bare} do
    path = Fixtures.worktree!(bare, "origin/main")
    status = Status.read!(path)

    assert Refs.unpushed(path, status) == 0
  end

  test "a detached commit exists nowhere else", %{bare: bare} do
    path = Fixtures.worktree!(bare, "origin/main")
    Fixtures.write(path, "agent.txt", "agent\n")
    Fixtures.commit!(path, "agent work")

    status = Status.read!(path)

    assert status.detached
    assert Refs.unpushed(path, status) == 1
  end

  test "a branch ahead of its upstream has unpushed commits", %{bare: bare} do
    path = Fixtures.worktree!(bare, "origin/main", detach: false, branch: "main")
    Fixtures.write(path, "local.txt", "local\n")
    Fixtures.commit!(path, "local work")

    status = Status.read!(path)

    assert status.upstream == "origin/main"
    assert Refs.unpushed(path, status) == 1
  end
end
