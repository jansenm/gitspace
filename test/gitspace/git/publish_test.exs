defmodule Gitspace.Git.PublishTest do
  use ExUnit.Case, async: true

  alias Gitspace.Fixtures
  alias Gitspace.Git
  alias Gitspace.Git.{Publish, Status}

  setup do
    bare = remote_repo!()
    path = clone!(bare)
    %{bare: bare, path: path}
  end

  test "pushes the checked-out branch and sets the upstream", %{bare: bare, path: path} do
    commit!(path, "first")

    assert {:ok, result} = Publish.run(path)

    assert result.status == :pushed
    assert result.remote == "origin"
    assert result.upstream == "origin/main"
    assert result.commits == 1

    assert Status.read!(path).upstream == "origin/main"
    assert ref!(bare, "refs/heads/main") == head!(path)

    assert {:ok, again} = Publish.run(path)
    assert again.status == :up_to_date
  end

  test "a dry run reports what would happen without touching the remote", %{
    bare: bare,
    path: path
  } do
    commit!(path, "first")
    assert {:ok, _} = Publish.run(path)
    first = ref!(bare, "refs/heads/main")

    commit!(path, "second")

    assert {:ok, result} = Publish.run(path, dry_run: true)

    assert result.status == :would_push
    assert result.commits == 1
    assert ref!(bare, "refs/heads/main") == first
  end

  test "a rejected push reports the rejection", %{bare: bare, path: path} do
    commit!(path, "first")
    assert {:ok, _} = Publish.run(path)

    other = clone!(bare)
    commit!(other, "other")
    assert {:ok, _} = Publish.run(other)

    commit!(path, "local")

    assert {:ok, result} = Publish.run(path)
    assert result.status == :rejected
    assert result.reason =~ "fetch first" or result.reason =~ "non-fast-forward"
  end

  test "pushes to the same-named branch instead of a mismatched upstream", %{
    bare: bare,
    path: path
  } do
    commit!(path, "first")
    assert {:ok, _} = Publish.run(path)
    main = ref!(bare, "refs/heads/main")

    Git.run!(["checkout", "-b", "topic"], cd: path)
    Git.run!(["branch", "--set-upstream-to=origin/main", "topic"], cd: path)
    commit!(path, "topic work")

    assert Status.read!(path).upstream == "origin/main"

    assert {:ok, result} = Publish.run(path)

    assert result.status == :pushed
    assert result.upstream == "origin/topic"
    assert result.note =~ "origin/main"
    assert ref!(bare, "refs/heads/topic") == head!(path)
    assert ref!(bare, "refs/heads/main") == main
  end

  test "refuses a detached HEAD", %{path: path} do
    commit!(path, "first")
    Git.run!(["checkout", "--detach"], cd: path)

    assert {:error, failure} = Publish.run(path)
    assert failure.kind == :refused
    assert failure.message =~ "detached HEAD"
  end

  test "refuses a checkout without a remote" do
    path = Fixtures.source_repo!()
    commit!(path, "local")

    assert {:error, failure} = Publish.run(path)
    assert failure.kind == :refused
    assert failure.message =~ "no git remote"
  end

  test "honours an explicit remote", %{bare: bare, path: path} do
    backup = remote_repo!()
    Git.run!(["remote", "add", "backup", backup], cd: path)
    commit!(path, "first")

    assert {:ok, result} = Publish.run(path, remote: "backup")

    assert result.status == :pushed
    assert result.remote == "backup"
    assert ref!(backup, "refs/heads/main") == head!(path)

    assert {:error, _} =
             Git.run(["rev-parse", "--verify", "--quiet", "refs/heads/main"], cd: bare)
  end

  defp remote_repo! do
    dir = Fixtures.tmp_dir!("publish-remote")
    bare = Path.join(dir, "remote.git")
    Git.run!(["init", "--bare", "--initial-branch=main", bare])
    bare
  end

  defp clone!(bare) do
    dir = Fixtures.tmp_dir!("publish-clone")
    path = Path.join(dir, "work")
    Git.run!(["clone", bare, path])
    Fixtures.configure_user(path)
    path
  end

  defp commit!(path, message) do
    Fixtures.write(path, "#{System.unique_integer([:positive])}.txt", "#{message}\n")
    Fixtures.commit!(path, message)
  end

  defp ref!(bare, ref) do
    Git.run!(["rev-parse", "--verify", ref], cd: bare) |> String.trim()
  end

  defp head!(path) do
    Git.run!(["rev-parse", "HEAD"], cd: path) |> String.trim()
  end
end
