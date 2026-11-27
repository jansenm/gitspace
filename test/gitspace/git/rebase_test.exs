defmodule Gitspace.Git.RebaseTest do
  use ExUnit.Case, async: true

  alias Gitspace.Fixtures
  alias Gitspace.Git
  alias Gitspace.Git.{Operation, Rebase}

  setup do
    bare = remote_repo!()
    path = clone!(bare)
    %{bare: bare, path: path}
  end

  test "rebases onto the upstream and reports up to date afterwards", %{bare: bare, path: path} do
    commit!(path, "base.txt", "base\n", "base")
    push!(path)

    other = clone!(bare)
    commit!(other, "remote.txt", "remote\n", "remote change")
    push!(other)

    commit!(path, "local.txt", "local\n", "local change")
    Git.run!(["fetch", "origin"], cd: path)

    assert {:ok, result} = Rebase.start(path)

    assert result.status == :rebased
    assert result.upstream == "origin/main"
    assert result.commits == 1
    assert result.old_head != result.new_head
    assert Operation.read(path) == nil

    subjects = Git.run!(["log", "--format=%s", "-2"], cd: path)
    assert subjects =~ "local change"
    assert subjects =~ "remote change"

    assert {:ok, again} = Rebase.start(path)
    assert again.status == :up_to_date
  end

  test "a conflict is left in progress and can be aborted", %{bare: bare, path: path} do
    commit!(path, "shared.txt", "base\n", "base")
    push!(path)

    other = clone!(bare)
    commit!(other, "shared.txt", "remote\n", "remote change")
    push!(other)

    commit!(path, "shared.txt", "local\n", "local change")
    Git.run!(["fetch", "origin"], cd: path)

    assert {:ok, result} = Rebase.start(path)
    assert result.status == :conflict
    assert result.files == ["shared.txt"]
    assert is_integer(result.step)
    assert is_integer(result.total)
    assert %{kind: :rebase} = Operation.read(path)

    assert {:ok, aborted} = Rebase.abort(path)
    assert aborted.status == :aborted
    assert Operation.read(path) == nil
    assert File.read!(Path.join(path, "shared.txt")) == "local\n"
  end

  test "continue finishes a resolved conflict", %{bare: bare, path: path} do
    commit!(path, "shared.txt", "base\n", "base")
    push!(path)

    other = clone!(bare)
    commit!(other, "shared.txt", "remote\n", "remote change")
    push!(other)

    commit!(path, "shared.txt", "local\n", "local change")
    Git.run!(["fetch", "origin"], cd: path)

    assert {:ok, %{status: :conflict}} = Rebase.start(path)

    File.write!(Path.join(path, "shared.txt"), "resolved\n")
    Git.run!(["add", "shared.txt"], cd: path)

    assert {:ok, result} = Rebase.continue(path)
    assert result.status == :rebased
    assert Operation.read(path) == nil
  end

  test "rebases a derived branch onto its recorded base, not its push target", %{
    bare: bare,
    path: path
  } do
    commit!(path, "base.txt", "base\n", "base")
    push!(path)

    Git.run!(["checkout", "-b", "feature"], cd: path)
    Git.run!(["config", "branch.feature.remote", "origin"], cd: path)
    Git.run!(["config", "branch.feature.merge", "refs/heads/feature"], cd: path)
    Git.run!(["config", "branch.feature.gitspace-base", "origin/main"], cd: path)

    other = clone!(bare)
    commit!(other, "remote.txt", "remote\n", "remote change")
    push!(other)

    commit!(path, "local.txt", "local\n", "local change")
    Git.run!(["fetch", "origin"], cd: path)

    assert {:ok, result} = Rebase.start(path)

    assert result.status == :rebased
    assert result.upstream == "origin/main"
    assert result.commits == 1
    assert Git.run!(["log", "--format=%s"], cd: path) =~ "remote change"
  end

  test "treats a configured push target that does not exist yet as up to date", %{path: path} do
    commit!(path, "base.txt", "base\n", "base")
    push!(path)

    Git.run!(["checkout", "-b", "feature"], cd: path)
    commit!(path, "local.txt", "local\n", "local change")
    Git.run!(["config", "branch.feature.remote", "origin"], cd: path)
    Git.run!(["config", "branch.feature.merge", "refs/heads/feature"], cd: path)

    assert {:ok, result} = Rebase.start(path)

    assert result.status == :up_to_date
    assert result.upstream == "origin/feature"
    assert result.hint =~ "does not exist"
    assert Operation.read(path) == nil
  end

  test "ignores a recorded base that no longer resolves", %{path: path} do
    commit!(path, "base.txt", "base\n", "base")
    push!(path)

    Git.run!(["checkout", "-b", "feature"], cd: path)
    Git.run!(["config", "branch.feature.remote", "origin"], cd: path)
    Git.run!(["config", "branch.feature.merge", "refs/heads/feature"], cd: path)
    Git.run!(["config", "branch.feature.gitspace-base", "origin/gone"], cd: path)

    assert {:ok, result} = Rebase.start(path)
    assert result.status == :up_to_date
    assert result.upstream == "origin/feature"
  end

  test "refuses a dirty tree", %{path: path} do
    commit!(path, "base.txt", "base\n", "base")
    push!(path)
    File.write!(Path.join(path, "base.txt"), "dirty\n")

    assert {:error, failure} = Rebase.start(path)
    assert failure.kind == :refused
    assert failure.message =~ "not clean"
  end

  test "refuses a detached HEAD", %{path: path} do
    commit!(path, "base.txt", "base\n", "base")
    push!(path)
    Git.run!(["checkout", "--detach"], cd: path)

    assert {:error, failure} = Rebase.start(path)
    assert failure.kind == :refused
    assert failure.message =~ "detached"
  end

  test "refuses when there is no upstream" do
    path = Fixtures.source_repo!()
    commit!(path, "base.txt", "base\n", "base")

    assert {:error, failure} = Rebase.start(path)
    assert failure.kind == :refused
    assert failure.message =~ "no upstream"
    assert is_binary(failure.hint)
  end

  test "continue and abort require a rebase in progress", %{path: path} do
    assert {:error, failure} = Rebase.continue(path)
    assert failure.message =~ "no rebase in progress"

    assert {:error, failure} = Rebase.abort(path)
    assert failure.message =~ "no rebase in progress"
  end

  defp remote_repo! do
    dir = Fixtures.tmp_dir!("rebase-remote")
    bare = Path.join(dir, "remote.git")
    Git.run!(["init", "--bare", "--initial-branch=main", bare])
    bare
  end

  defp clone!(bare) do
    dir = Fixtures.tmp_dir!("rebase-clone")
    path = Path.join(dir, "work")
    Git.run!(["clone", bare, path])
    Fixtures.configure_user(path)
    path
  end

  defp commit!(path, file, content, message) do
    Fixtures.write(path, file, content)
    Fixtures.commit!(path, message)
  end

  defp push!(path) do
    Git.run!(["push", "--set-upstream", "origin", "HEAD"], cd: path)
  end
end
