defmodule Gitspace.ScanTest do
  use Gitspace.IndexCase, async: false

  alias Gitspace.{Checkouts, Config, Fixtures, Git, Repos, Scan}
  alias Gitspace.Git.Worktree

  setup %{root: root} do
    source = Fixtures.source_repo!()
    scan_root = Path.join(root, "scan")
    File.mkdir_p!(scan_root)
    clone = Path.join(scan_root, "external")
    Git.run!(["clone", source, clone], timeout: 60_000)

    {:ok, scan_root: scan_root, clone: clone, source: source}
  end

  test "DISC-1 finds a clone and does not touch it", %{
    config: config,
    scan_root: scan_root,
    clone: clone
  } do
    before = snapshot(clone)

    assert {:ok, entries} = Scan.scan(config, [scan_root], max_depth: 3)
    entry = Enum.find(entries, &(&1.path == clone))

    assert entry.kind == "clone"
    assert entry.branch == "main"
    refute entry.indexed

    assert snapshot(clone) == before
  end

  test "DISC-3/4 link and unlink never modify the checkout", %{config: config, clone: clone} do
    before = snapshot(clone)

    assert {:ok, result} = Scan.link(config, clone)
    assert result.checkout.source == "external"
    assert result.checkout.path == clone
    refute result.reused

    assert File.dir?(clone)
    assert snapshot(clone) == before

    assert {:ok, _} = Scan.unlink(config, clone)
    assert File.dir?(clone)
    assert snapshot(clone) == before
    assert {:error, error} = Checkouts.get_by_path(clone)
    assert error.code == :not_found
  end

  test "DISC-1 detects bare mirrors and marks them indexed", %{config: config, source: source} do
    assert {:ok, _} = Repos.add(config, Fixtures.repo_url(source), name: "demo")

    assert {:ok, entries} = Scan.scan(config, [Config.repos_dir(config)], max_depth: 1)
    bare = Enum.find(entries, &(&1.kind == "bare" and &1.indexed_repo == "demo"))

    assert bare
    assert bare.indexed
    assert bare.indexed_repo == "demo"
  end

  test "link reuses a managed repository and refuses to unlink a managed checkout", %{
    config: config,
    source: source
  } do
    {:ok, repo} = Repos.add(config, Fixtures.repo_url(source), name: "demo")
    path = Path.join([config.projects_root, "demo", "main", "demo"])
    File.mkdir_p!(Path.dirname(path))
    {:ok, _} = Worktree.add(repo.bare_path, path, "origin/main", branch: "main")

    assert {:ok, result} = Scan.link(config, path)
    assert result.checkout.source == "managed"
    refute result.reused

    assert {:ok, second} = Scan.link(config, path)
    assert second.reused

    assert {:error, error} = Scan.unlink(config, path)
    assert error.exit_code == 5
  end

  defp snapshot(dir) do
    dir
    |> Path.join("**")
    |> Path.wildcard(match_dot: true)
    |> Enum.sort()
    |> Enum.map(fn path ->
      stat = File.stat!(path)
      {path, stat.mtime, stat.size}
    end)
  end
end
