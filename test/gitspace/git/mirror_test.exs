defmodule Gitspace.Git.MirrorTest do
  use ExUnit.Case, async: true

  alias Gitspace.{Fixtures, Git}

  test "creates a bare mirror with origin-tracking refs" do
    source = Fixtures.source_repo!(branches: ["feature/x"])
    bare = Fixtures.mirror!(source)

    assert Git.run!(["rev-parse", "--is-bare-repository"], cd: bare) |> String.trim() == "true"

    refs = Git.run!(["for-each-ref", "--format=%(refname)"], cd: bare)

    assert refs =~ "refs/remotes/origin/main"
    assert refs =~ "refs/remotes/origin/feature/x"
    refute refs =~ "refs/heads/main"
  end

  test "detects the default branch" do
    source = Fixtures.source_repo!()
    bare = Fixtures.mirror!(source)

    assert Gitspace.Git.Mirror.default_branch(bare) == "main"
  end

  test "fetch updates origin/main without touching a local branch" do
    source = Fixtures.source_repo!()
    bare = Fixtures.mirror!(source)

    before = Git.run!(["rev-parse", "origin/main"], cd: bare) |> String.trim()

    Fixtures.write(source, "new.txt", "new\n")
    Fixtures.commit!(source, "second")
    Gitspace.Git.Mirror.fetch!(bare)

    after_fetch = Git.run!(["rev-parse", "origin/main"], cd: bare) |> String.trim()
    source_head = Git.run!(["rev-parse", "main"], cd: source) |> String.trim()

    assert after_fetch == source_head
    refute after_fetch == before
  end
end
