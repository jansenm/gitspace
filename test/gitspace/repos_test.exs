defmodule Gitspace.ReposTest do
  use Gitspace.IndexCase, async: false

  alias Gitspace.{Checkouts, Config, Fixtures, Git, Layout, MirrorIndex, Repos}
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

  test "colliding basenames get group-qualified aliases and hashed mirrors", %{config: config} do
    root = Fixtures.tmp_dir!("collisions")
    first = source_named!(root, "one/config")
    second = source_named!(root, "two/config")

    assert {:ok, first_repo} = Repos.add(config, first)
    assert first_repo.slug == "config"
    assert File.dir?(first_repo.bare_path)
    assert Path.basename(first_repo.bare_path) =~ ~r/^[0-9a-f]{64}\.git$/

    assert {:ok, second_repo} = Repos.add(config, second)
    assert second_repo.slug == "two-config"

    assert {:ok, first_repo} = Repos.get(config, first)
    assert first_repo.slug == "one-config"

    aliases = Repos.list(config) |> Enum.map(& &1.repo.slug) |> Enum.sort()
    assert aliases == ["one-config", "two-config"]

    assert {:error, ambiguous} = Repos.get(config, "config")
    assert ambiguous.code == :ambiguous

    assert {:ok, _} = Repos.get(config, "one/config")
    assert {:ok, _} = Repos.get(config, first)

    assert File.exists?(MirrorIndex.path(config))
    index = File.read!(MirrorIndex.path(config))
    assert index =~ "canonical-remote"
    assert index =~ "/one/config"
    assert index =~ "/two/config"
    assert index =~ "one-config"
    assert index =~ "two-config"
  end

  test "an explicit basename alias opts out of disambiguation", %{config: config} do
    root = Fixtures.tmp_dir!("explicit-alias")
    first = source_named!(root, "one/config")
    second = source_named!(root, "two/config")
    third = source_named!(root, "three/config")

    assert {:ok, _} = Repos.add(config, first, name: "one-config")
    assert {:ok, _} = Repos.add(config, second, name: "config")

    assert {:error, opt_out} = Repos.add(config, third, name: "config")
    assert opt_out.code == :conflict

    aliases = Repos.list(config) |> Enum.map(& &1.repo.slug) |> Enum.sort()
    assert aliases == ["config", "one-config"]

    assert {:ok, _} = Repos.add(config, third, name: "three-config")
    aliases = Repos.list(config) |> Enum.map(& &1.repo.slug) |> Enum.sort()
    assert aliases == ["config", "one-config", "three-config"]
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

  test "audit and discover reconcile remotes.txt with mirror directories", %{config: config} do
    source = Fixtures.source_repo!()
    assert {:ok, repo} = Repos.add(config, source, name: "demo")

    assert %{mirrors: 1, issues: []} = Repos.audit_mirrors(config)

    File.rm!(MirrorIndex.path(config))
    audit = Repos.audit_mirrors(config)
    assert Enum.any?(audit.issues, &(&1.kind == :missing_from_text))

    assert %{discovered: 1, issues: []} = Repos.discover(config)
    assert %{issues: []} = Repos.audit_mirrors(config)

    renamed = Path.join(Config.repos_dir(config), String.duplicate("0", 64) <> ".git")
    File.rename!(repo.bare_path, renamed)

    audit = Repos.audit_mirrors(config)
    assert Enum.any?(audit.issues, &(&1.kind == :hash_mismatch))
    assert Enum.any?(audit.issues, &(&1.kind == :missing_mirror))

    assert %{issues: issues} = Repos.discover(config)
    assert Enum.any?(issues, &(&1.kind == :hash_mismatch))

    assert {:ok, moved} = Repos.get(config, "demo")
    assert moved.bare_path == renamed
    text = File.read!(MirrorIndex.path(config))
    assert text =~ Layout.remote_hash(Layout.normalize_remote(source))
  end

  test "discovery keeps the stored remote when a mirror has no origin", %{config: config} do
    source = Fixtures.source_repo!()
    assert {:ok, repo} = Repos.add(config, source, name: "demo")

    Git.run!(["config", "--unset", "remote.origin.url"], cd: repo.bare_path)

    assert %{issues: issues} = Repos.discover(config)
    assert Enum.any?(issues, &(&1.kind == :missing_remote))

    assert {:ok, found} = Repos.get(config, "demo")
    assert found.remote_url == source
    assert found.remote_key == Layout.normalize_remote(source)
    assert found.bare_path == repo.bare_path
  end

  test "explicit aliases survive index deletion via mirror metadata", %{config: config} do
    source = Fixtures.source_repo!()
    assert {:ok, _repo} = Repos.add(config, source, name: "before")
    assert {:ok, renamed} = Repos.set_alias(config, "before", "stable")
    assert renamed.alias_source == "explicit"

    Gitspace.Index.stop()
    File.rm_rf!(Config.db_path(config))

    assert {:ok, _summary} = Gitspace.Index.reindex(config)
    assert {:ok, found} = Repos.get(config, "stable")
    assert found.remote_key == Layout.normalize_remote(source)
    assert found.alias_source == "explicit"
  end

  test "reindex surfaces mirror hash mismatches as issues", %{config: config} do
    source = Fixtures.source_repo!()
    assert {:ok, repo} = Repos.add(config, source, name: "demo")

    renamed = Path.join(Config.repos_dir(config), String.duplicate("a", 64) <> ".git")
    File.rename!(repo.bare_path, renamed)

    assert {:ok, summary} = Gitspace.Index.reindex(config)
    assert Enum.any?(summary.issues, &(&1.kind == :hash_mismatch))
  end

  defp source_named!(root, relative) do
    dir = Path.join(root, relative)
    File.mkdir_p!(dir)
    Git.run!(["init", "--initial-branch=main", dir])
    Fixtures.configure_user(dir)
    Fixtures.write(dir, "README.md", "# named fixture\n")
    Fixtures.commit!(dir, "initial")
    dir
  end
end
