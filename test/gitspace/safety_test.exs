defmodule Gitspace.SafetyTest do
  use ExUnit.Case, async: true

  alias Gitspace.{Fixtures, Safety}
  alias Gitspace.Git
  alias Gitspace.Git.{Status, Worktree}

  setup do
    source = Fixtures.source_repo!()
    bare = Fixtures.mirror!(source)
    %{bare: bare}
  end

  test "detect reports a detached unpushed commit", %{bare: bare} do
    path = Fixtures.worktree!(bare, "origin/main")
    Fixtures.write(path, "agent.txt", "agent\n")
    Fixtures.commit!(path, "agent work")

    assert {:ok, report} = Safety.detect(path)
    assert report.detached
    assert report.unpushed == 1
    assert report.at_risk
  end

  test "keep ref survives worktree removal and gc", %{bare: bare} do
    path = Fixtures.worktree!(bare, "origin/main")
    Fixtures.write(path, "agent.txt", "agent\n")
    Fixtures.commit!(path, "agent work")

    assert {:ok, ref, sha} = Safety.keep!(bare, path, "wt-1")
    assert ref =~ "refs/gitspace/keep/wt-1/"

    assert {:ok, _} = Worktree.remove(bare, path, force: true)
    Git.run!(["gc", "--prune=now"], cd: bare, locks: true)

    assert {:ok, _} = Git.run(["cat-file", "-e", sha], cd: bare)
  end

  test "stash create preserves tracked changes without touching the tree", %{bare: bare} do
    path = Fixtures.worktree!(bare, "origin/main")
    File.write!(Path.join(path, "README.md"), "changed\n")

    assert {:ok, sha} = Safety.stash_create(path)
    assert Git.run!(["show", "#{sha}:README.md"], cd: path) == "changed\n"
    assert Status.read!(path).dirty == 1
  end

  test "untracked files round-trip through a tar", %{bare: bare} do
    path = Fixtures.worktree!(bare, "origin/main")
    Fixtures.write(path, "a.txt", "a\n")
    Fixtures.write(path, "b.txt", "b\n")

    assert {:ok, paths} = Safety.untracked(path)
    assert Enum.sort(paths) == ["a.txt", "b.txt"]

    out = Path.join(Fixtures.tmp_dir!("trash"), "untracked.tgz")
    assert :ok = Safety.archive_untracked!(path, out, paths)

    dest = Fixtures.tmp_dir!("extract")

    assert :ok =
             :erl_tar.extract(String.to_charlist(out), [
               :compressed,
               {:cwd, String.to_charlist(dest)}
             ])

    assert File.read!(Path.join(dest, "a.txt")) == "a\n"
    assert File.read!(Path.join(dest, "b.txt")) == "b\n"
  end

  test "bundle from a keep ref verifies", %{bare: bare} do
    path = Fixtures.worktree!(bare, "origin/main")
    Fixtures.write(path, "agent.txt", "agent\n")
    Fixtures.commit!(path, "agent work")

    assert {:ok, ref, _sha} = Safety.keep!(bare, path, "wt-2")

    out = Path.join(Fixtures.tmp_dir!("bundle"), "safety.bundle")
    assert :ok = Safety.bundle!(bare, out, ref)

    assert {:ok, result} = Git.run(["bundle", "verify", out], cd: bare)
    assert String.contains?(result.stdout <> result.stderr, "complete history")
  end
end
