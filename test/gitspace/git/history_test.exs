defmodule Gitspace.Git.HistoryTest do
  use ExUnit.Case, async: true

  alias Gitspace.Fixtures
  alias Gitspace.Git
  alias Gitspace.Git.History

  setup do
    source = Fixtures.source_repo!()
    bare = Fixtures.mirror!(source)
    %{source: source, bare: bare}
  end

  test "outgoing commits are ahead of the upstream", %{bare: bare} do
    path = Fixtures.worktree!(bare, "origin/main", detach: false, branch: "main")
    Fixtures.write(path, "local.txt", "local\n")
    Fixtures.commit!(path, "local work")

    assert {:ok, history} = History.read(path)

    assert history.upstream == "origin/main"
    assert history.outgoing.total == 1
    assert [%{subject: "local work"}] = history.outgoing.commits
    refute history.outgoing.truncated
    assert history.incoming.total == 0
  end

  test "incoming commits are behind the upstream", %{source: source, bare: bare} do
    path = Fixtures.worktree!(bare, "origin/main", detach: false, branch: "main")

    Fixtures.write(source, "upstream.txt", "upstream\n")
    Fixtures.commit!(source, "upstream work")
    Git.Mirror.fetch!(bare)

    assert {:ok, history} = History.read(path)

    assert history.incoming.total == 1
    assert [%{subject: "upstream work"}] = history.incoming.commits
    assert history.outgoing.total == 0
  end

  test "a limit truncates the list but keeps the total", %{bare: bare} do
    path = Fixtures.worktree!(bare, "origin/main", detach: false, branch: "main")

    for i <- 1..3 do
      Fixtures.write(path, "file#{i}.txt", "#{i}\n")
      Fixtures.commit!(path, "commit #{i}")
    end

    assert {:ok, history} = History.read(path, limit: 2)

    assert history.outgoing.total == 3
    assert length(history.outgoing.commits) == 2
    assert history.outgoing.truncated
  end

  test "a nil limit shows everything", %{bare: bare} do
    path = Fixtures.worktree!(bare, "origin/main", detach: false, branch: "main")

    for i <- 1..3 do
      Fixtures.write(path, "file#{i}.txt", "#{i}\n")
      Fixtures.commit!(path, "commit #{i}")
    end

    assert {:ok, history} = History.read(path, limit: nil)

    assert length(history.outgoing.commits) == 3
    refute history.outgoing.truncated
  end

  test "directions can be switched off", %{bare: bare} do
    path = Fixtures.worktree!(bare, "origin/main", detach: false, branch: "main")

    assert {:ok, history} = History.read(path, directions: [:outgoing])

    assert history.outgoing.enabled
    refute history.incoming.enabled
  end

  test "a derived branch compares incoming with its recorded base", %{source: source, bare: bare} do
    path = Fixtures.worktree!(bare, "origin/main", detach: false, branch: "feature")
    Git.run!(["config", "branch.feature.remote", "origin"], cd: path)
    Git.run!(["config", "branch.feature.merge", "refs/heads/feature"], cd: path)
    Git.run!(["config", "branch.feature.gitspace-base", "origin/main"], cd: path)

    Fixtures.write(source, "upstream.txt", "upstream\n")
    Fixtures.commit!(source, "upstream work")
    Git.Mirror.fetch!(bare)

    assert {:ok, history} = History.read(path)

    assert history.incoming.base == "origin/main"
    assert [%{subject: "upstream work"}] = history.incoming.commits
  end

  test "a branch without upstream falls back to origin/<default> for incoming", %{bare: bare} do
    path = Fixtures.worktree!(bare, "origin/main")
    Git.run!(["checkout", "-B", "topic"], cd: path)

    assert {:ok, history} = History.read(path, default_branch: "main")

    assert history.upstream == nil
    assert history.incoming.base == "origin/main"
  end
end
