defmodule Gitspace.ReposTest do
  use Gitspace.IndexCase, async: false

  alias Gitspace.{Checkouts, Fixtures, Repos}
  alias Gitspace.Git.Worktree
  alias Gitspace.Index.Repository

  test "adds a mirror, fetches it and lists it", %{config: config} do
    source = Fixtures.source_repo!()

    assert {:ok, repo} = Repos.add(config, source, name: "demo")
    assert repo.slug == "demo"
    assert repo.default_branch == "main"
    assert File.dir?(repo.bare_path)
    assert repo.last_fetched_at

    assert [%{repo: found, checkouts: 0}] = Repos.list(config)
    assert found.slug == "demo"
  end

  test "the same remote under another name is a conflict", %{config: config} do
    source = Fixtures.source_repo!()
    assert {:ok, _} = Repos.add(config, source, name: "demo")

    assert {:error, error} = Repos.add(config, source, name: "other")
    assert error.code == :conflict
    assert error.exit_code == 4
  end

  test "sync imports worktrees and marks vanished ones missing", %{config: config} do
    source = Fixtures.source_repo!()
    {:ok, repo} = Repos.add(config, source, name: "demo")

    path = Path.join([config.checkouts_dir, "demo", "demo"])
    File.mkdir_p!(Path.dirname(path))
    {:ok, _} = Worktree.add(repo.bare_path, path, "origin/main", branch: "main")

    assert {:ok, summary} = Repos.sync(config, repo)
    assert summary.imported == 1

    assert [checkout] = Checkouts.list(config, repo: "demo")
    assert checkout.path == path
    assert checkout.source == "managed"

    File.rm_rf!(path)
    assert {:ok, summary} = Repos.sync(config, repo)
    assert summary.missing == 1

    assert [checkout] = Checkouts.list(config, repo: "demo")
    assert checkout.state == "missing"
  end

  test "remove refuses while used, then unindexes with force", %{config: config} do
    source = Fixtures.source_repo!()
    {:ok, repo} = Repos.add(config, source, name: "demo")

    path = Path.join([config.checkouts_dir, "demo", "demo"])
    File.mkdir_p!(Path.dirname(path))
    {:ok, _} = Worktree.add(repo.bare_path, path, "origin/main", branch: "main")
    {:ok, _} = Repos.sync(config, repo)

    assert {:error, error} = Repos.remove(config, "demo")
    assert error.exit_code == 5

    assert {:ok, result} = Repos.remove(config, "demo", force: true)
    assert result.removed_checkouts == 1
    assert File.dir?(path)
    assert [] = Checkouts.list(config, repo: "demo")
  end

  test "discover rebuilds mirror rows from the filesystem", %{config: config} do
    source = Fixtures.source_repo!()
    {:ok, _} = Repos.add(config, source, name: "demo")

    Repo.delete_all(Repository)
    assert [] = Repos.list(config)

    assert %{discovered: 1, issues: []} = Repos.discover(config)
    assert {:ok, repo} = Repos.get(config, "demo")
    assert repo.state == "managed"
    assert File.dir?(repo.bare_path)
  end
end
