defmodule Gitspace.ReposTest do
  use Gitspace.IndexCase, async: false

  alias Gitspace.{Checkouts, Config, Fixtures, Git, Layout, MirrorIndex, Repos}
  alias Gitspace.Git.Worktree
  alias Gitspace.Index.Repository

  test "adds a mirror, fetches it and lists it", %{config: config} do
    source = Fixtures.source_repo!()

    assert {:ok, repo} = Repos.add(config, Fixtures.repo_url(source), name: "demo")
    assert repo.slug == "demo"
    assert repo.default_branch == "main"
    assert File.dir?(repo.bare_path)
    assert repo.last_fetched_at

    assert [%{repo: found, checkouts: 0}] = Repos.list(config)
    assert found.slug == "demo"
  end

  test "the same remote under another name is a conflict", %{config: config} do
    source = Fixtures.source_repo!()
    assert {:ok, _} = Repos.add(config, Fixtures.repo_url(source), name: "demo")

    assert {:error, error} = Repos.add(config, Fixtures.repo_url(source), name: "other")
    assert error.code == :conflict
    assert error.exit_code == 4
  end

  test "colliding basenames get group-qualified aliases and hashed mirrors", %{config: config} do
    root = Fixtures.tmp_dir!("collisions")
    first = source_named!(root, "one/config")
    second = source_named!(root, "two/config")

    assert {:ok, first_repo} = Repos.add(config, Fixtures.repo_url(first))
    assert first_repo.slug == "config"
    assert File.dir?(first_repo.bare_path)
    assert Path.basename(first_repo.bare_path) =~ ~r/^[0-9a-f]{64}\.git$/

    assert {:ok, second_repo} = Repos.add(config, Fixtures.repo_url(second))
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
    assert index =~ "identity"
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

    assert {:ok, _} = Repos.add(config, Fixtures.repo_url(first), name: "one-config")
    assert {:ok, _} = Repos.add(config, Fixtures.repo_url(second), name: "config")

    assert {:error, opt_out} = Repos.add(config, Fixtures.repo_url(third), name: "config")
    assert opt_out.code == :conflict

    aliases = Repos.list(config) |> Enum.map(& &1.repo.slug) |> Enum.sort()
    assert aliases == ["config", "one-config"]

    assert {:ok, _} = Repos.add(config, Fixtures.repo_url(third), name: "three-config")
    aliases = Repos.list(config) |> Enum.map(& &1.repo.slug) |> Enum.sort()
    assert aliases == ["config", "one-config", "three-config"]
  end

  test "sync imports worktrees and marks vanished ones missing", %{config: config} do
    source = Fixtures.source_repo!()
    {:ok, repo} = Repos.add(config, Fixtures.repo_url(source), name: "demo")

    path = Path.join([config.projects_root, "demo", "main", "demo"])
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
    {:ok, repo} = Repos.add(config, Fixtures.repo_url(source), name: "demo")

    path = Path.join([config.projects_root, "demo", "main", "demo"])
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
    {:ok, _} = Repos.add(config, Fixtures.repo_url(source), name: "demo")

    Repo.delete_all(Repository)
    assert [] = Repos.list(config)

    assert %{discovered: 1, issues: []} = Repos.discover(config)
    assert {:ok, repo} = Repos.get(config, "demo")
    assert repo.state == "managed"
    assert File.dir?(repo.bare_path)
  end

  test "audit and discover reconcile remotes.txt with mirror directories", %{config: config} do
    source = Fixtures.source_repo!()
    assert {:ok, repo} = Repos.add(config, Fixtures.repo_url(source), name: "demo")

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
    assert {:ok, repo} = Repos.add(config, Fixtures.repo_url(source), name: "demo")

    Git.run!(["config", "--unset", "remote.origin.url"], cd: repo.bare_path)

    assert %{issues: issues} = Repos.discover(config)
    refute Enum.any?(issues, &(&1.kind == :missing_remote))

    assert {:ok, found} = Repos.get(config, "demo")
    assert found.remote_url == Fixtures.repo_url(source)
    assert found.origin_kind == "local"
    assert found.remote_key == Layout.normalize_remote(source)
    assert found.bare_path == repo.bare_path
  end

  test "explicit aliases survive index deletion via mirror metadata", %{config: config} do
    source = Fixtures.source_repo!()
    assert {:ok, _repo} = Repos.add(config, Fixtures.repo_url(source), name: "before")
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
    assert {:ok, repo} = Repos.add(config, Fixtures.repo_url(source), name: "demo")

    renamed = Path.join(Config.repos_dir(config), String.duplicate("a", 64) <> ".git")
    File.rename!(repo.bare_path, renamed)

    assert {:ok, summary} = Gitspace.Index.reindex(config)
    assert Enum.any?(summary.issues, &(&1.kind == :hash_mismatch))
  end

  test "add from a checkout uses its single remote", %{config: config} do
    source = Fixtures.source_repo!()
    clone = clone_checkout!(source, "single-remote")

    assert {:ok, repo} = Repos.add(config, clone, no_fetch: true)
    assert repo.remote_url == source
    assert repo.remote_key == Layout.normalize_remote(source)

    assert repo.bare_path ==
             Path.join(Config.repos_dir(config), Layout.remote_hash(repo.remote_key) <> ".git")
  end

  test "add from a checkout seeds the mirror via reference and dissociates", %{config: config} do
    source = Fixtures.source_repo!()
    clone = clone_checkout!(source, "reference")

    assert {:ok, repo} = Repos.add(config, clone)
    assert repo.remote_url == source
    assert repo.default_branch == "main"
    assert repo.last_fetched_at
    refute File.exists?(Path.join(repo.bare_path, "objects/info/alternates"))

    assert {:ok, branches} =
             Git.run(["for-each-ref", "--format=%(refname)", "refs/heads"], cd: repo.bare_path)

    assert String.trim(branches.stdout) == ""

    assert {:ok, head} =
             Git.run(["symbolic-ref", "--short", "refs/remotes/origin/HEAD"], cd: repo.bare_path)

    assert String.trim(head.stdout) == "origin/main"
    assert {:ok, _} = Git.run(["cat-file", "-e", "refs/remotes/origin/main"], cd: repo.bare_path)

    File.rm_rf!(clone)
    File.rm_rf!(source)
    assert {:ok, _} = Git.run(["cat-file", "-e", "refs/remotes/origin/main"], cd: repo.bare_path)
  end

  test "multiple checkout remotes require --remote and list candidates", %{config: config} do
    source = Fixtures.source_repo!()
    clone = clone_checkout!(source, "multi-remote")
    Git.run!(["remote", "add", "upstream", "git@example.com:other/config.git"], cd: clone)

    assert {:error, error} = Repos.add(config, clone)
    assert error.code == :usage
    assert error.message =~ "multiple remotes"
    assert error.hint =~ "--remote"
    assert Enum.map(error.details.remotes, & &1.name) |> Enum.sort() == ["origin", "upstream"]

    assert {:error, missing} = Repos.add(config, clone, remote: "nope")
    assert missing.code == :usage
    assert missing.message =~ "no remote named nope"

    assert {:ok, repo} = Repos.add(config, clone, remote: "upstream", no_fetch: true)
    assert repo.remote_url == "git@example.com:other/config.git"
    assert repo.remote_key == "example.com/other/config"
  end

  test "relative checkout remotes resolve against the checkout root", %{config: config} do
    source = Fixtures.source_repo!()
    clone = clone_checkout!(source, "relative-remote")
    relative = Path.relative_to(source, clone)

    Git.run!(["remote", "set-url", "origin", relative], cd: clone)

    assert {:ok, repo} = Repos.add(config, clone, no_fetch: true)
    assert repo.remote_url == source
  end

  test "a local checkout without remotes is refused", %{config: config} do
    source = Fixtures.source_repo!()

    assert {:error, error} = Repos.add(config, source)
    assert error.code == :usage
    assert error.message =~ "no remotes"
    assert error.hint =~ "repo import"

    assert {:error, with_remote} = Repos.add(config, source, remote: "origin")
    assert with_remote.code == :usage
    assert with_remote.message =~ "no remotes"
  end

  test "set_remote_url switches https to ssh without changing the canonical key", %{
    config: config
  } do
    https = "https://example.com/acme/config.git"
    ssh = "git@example.com:acme/config.git"

    assert {:ok, repo} = Repos.add(config, https, name: "remote-url", no_fetch: true)
    assert repo.remote_key == "example.com/acme/config"

    assert {:ok, result} = Repos.set_remote_url(config, repo, ssh)
    assert result.target == "fetch"
    assert result.previous == [https]
    assert result.url == ssh

    assert {:ok, updated} = Repos.get(config, "remote-url")
    assert updated.remote_url == ssh
    assert updated.remote_key == repo.remote_key
    assert updated.bare_path == repo.bare_path

    assert Git.run!(["config", "--get", "remote.origin.url"], cd: repo.bare_path)
           |> String.trim() == ssh

    assert {:ok, pushed} = Repos.set_remote_url(config, repo, ssh, push: true)
    assert pushed.target == "push"
    assert pushed.previous == []

    assert Git.run!(["config", "--get", "remote.origin.pushurl"], cd: repo.bare_path)
           |> String.trim() == ssh

    assert {:ok, after_push} = Repos.get(config, "remote-url")
    assert after_push.remote_url == ssh
  end

  test "set_remote_url may change host and path without rekeying", %{config: config} do
    original = "https://example.com/acme/config.git"
    moved = "https://gitlab.com/team/renamed.git"

    assert {:ok, repo} = Repos.add(config, original, name: "moving", no_fetch: true)
    assert repo.remote_key == "example.com/acme/config"

    assert {:ok, result} = Repos.set_remote_url(config, repo, moved)
    assert result.previous == [original]
    assert result.url == moved

    assert {:ok, updated} = Repos.get(config, "moving")
    assert updated.remote_key == repo.remote_key
    assert updated.bare_path == repo.bare_path
    assert updated.remote_url == moved

    assert Git.run!(["config", "--get", "gitspace.remote-key"], cd: repo.bare_path)
           |> String.trim() == repo.remote_key

    Gitspace.Index.stop()
    File.rm_rf!(Config.db_path(config))

    assert {:ok, _summary} = Gitspace.Index.reindex(config)
    assert {:ok, found} = Repos.get(config, repo.remote_key)
    assert found.remote_key == repo.remote_key
    assert found.bare_path == repo.bare_path
    assert found.remote_url == moved
  end

  test "set_remote_url refuses an address that belongs to another repository", %{config: config} do
    one = "https://example.com/acme/one.git"
    two = "https://example.com/acme/two.git"

    assert {:ok, repo} = Repos.add(config, one, name: "one", no_fetch: true)
    assert {:ok, _} = Repos.add(config, two, name: "two", no_fetch: true)

    assert {:error, error} = Repos.set_remote_url(config, repo, two)
    assert error.code == :conflict
    assert error.details.other == "two"

    assert {:ok, unchanged} = Repos.get(config, "one")
    assert unchanged.remote_url == one
  end

  test "a push URL may point at another repository", %{config: config} do
    one = "https://example.com/acme/one.git"
    two = "https://example.com/acme/two.git"

    assert {:ok, repo} = Repos.add(config, one, name: "one", no_fetch: true)
    assert {:ok, _} = Repos.add(config, two, name: "two", no_fetch: true)

    assert {:ok, result} = Repos.set_remote_url(config, repo, two, push: true)
    assert result.target == "push"
  end

  test "adding the current address after a URL change is a conflict", %{config: config} do
    assert {:ok, repo} =
             Repos.add(config, "https://example.com/acme/one.git", name: "one", no_fetch: true)

    moved = "https://gitlab.com/team/renamed.git"
    assert {:ok, _} = Repos.set_remote_url(config, repo, moved)

    assert {:error, error} = Repos.add(config, moved, name: "again", no_fetch: true)
    assert error.code == :conflict
    assert error.details.alias == "one"
  end

  test "discover pins an origin-derived identity into the mirror", %{config: config} do
    source = Fixtures.source_repo!()
    assert {:ok, repo} = Repos.add(config, Fixtures.repo_url(source), name: "legacy")
    Git.run!(["config", "--unset", "gitspace.remote-key"], cd: repo.bare_path)

    assert %{discovered: 1, issues: []} = Repos.discover(config)

    assert Git.run!(["config", "--get", "gitspace.remote-key"], cd: repo.bare_path)
           |> String.trim() == repo.remote_key
  end

  test "discover recovers an origin-less mirror from its pinned identity", %{config: config} do
    source = Fixtures.source_repo!()
    assert {:ok, repo} = Repos.add(config, Fixtures.repo_url(source), name: "pinned")
    Git.run!(["config", "--unset", "remote.origin.url"], cd: repo.bare_path)

    Gitspace.Index.stop()
    File.rm_rf!(Config.db_path(config))

    assert {:ok, _summary} = Gitspace.Index.reindex(config)

    assert {:ok, found} = Repos.get(config, repo.remote_key)
    assert found.remote_key == repo.remote_key
    assert found.bare_path == repo.bare_path
    assert found.origin_kind == "local"
  end

  test "set_remote_url refuses multiple fetch URLs and leaves them untouched", %{config: config} do
    https = "https://example.com/acme/config.git"
    ssh = "git@example.com:acme/config.git"

    assert {:ok, repo} = Repos.add(config, https, name: "multi-url", no_fetch: true)
    Git.run!(["config", "--add", "remote.origin.url", ssh], cd: repo.bare_path)

    assert {:error, error} =
             Repos.set_remote_url(config, repo, "ssh://git@example.com/acme/config.git")

    assert error.code == :conflict
    assert error.details.urls == [https, ssh]

    assert Git.run!(["config", "--get-all", "remote.origin.url"], cd: repo.bare_path)
           |> String.split("\n", trim: true) == [https, ssh]
  end

  test "a remote basename with '@' needs an explicit name", %{config: config} do
    url = "https://example.com/acme/api@v2.git"

    assert {:error, error} = Repos.add(config, url, no_fetch: true)
    assert error.code == :usage

    assert {:ok, repo} = Repos.add(config, url, name: "api-v2", no_fetch: true)
    assert repo.slug == "api-v2"
  end

  test "an explicit alias may not contain '@'", %{config: config} do
    source = Fixtures.source_repo!()

    assert {:error, error} =
             Repos.add(config, Fixtures.repo_url(source), name: "a@b", no_fetch: true)

    assert error.code == :usage
  end

  defp clone_checkout!(source, label) do
    clone = Path.join(Fixtures.tmp_dir!(label), "checkout")
    Git.run!(["clone", source, clone])
    clone
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
