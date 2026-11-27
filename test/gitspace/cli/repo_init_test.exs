defmodule Gitspace.CLI.RepoInitTest do
  use Gitspace.IndexCase, async: false

  alias Gitspace.{Checkouts, Config, Fixtures, Git, Projects, Repos, Workspaces}

  setup %{config: config} do
    :ok = Config.save(config)
    previous = System.get_env("GITSPACE_CONFIG")
    System.put_env("GITSPACE_CONFIG", config.path)
    System.delete_env("GITSPACE_DATA")
    System.delete_env("GITSPACE_PROJECTS_ROOT")

    on_exit(fn ->
      if previous do
        System.put_env("GITSPACE_CONFIG", previous)
      else
        System.delete_env("GITSPACE_CONFIG")
      end

      System.delete_env("GITSPACE_DATA")
      System.delete_env("GITSPACE_PROJECTS_ROOT")
    end)

    {:ok, config: config}
  end

  test "repo init creates a local mirror, project and first checkout", %{config: config} do
    {output, 0} = cli(["repo", "init", "demo", "--json"])
    data = Jason.decode!(output)["data"]

    assert data["repo"]["origin_kind"] == "local"
    assert data["repo"]["remote_url"] == ""
    assert data["identity"] =~ ~r/^local:/
    assert data["branch"] == "main"
    assert data["workspace"] == "demo@main"

    path = data["checkout"]
    assert File.dir?(path)
    assert {:ok, branch} = Git.run(["symbolic-ref", "--short", "HEAD"], cd: path)
    assert String.trim(branch.stdout) == "main"
    assert {:error, _} = Git.run(["rev-parse", "HEAD"], cd: path)

    assert {:ok, workspace} = Workspaces.get(config, "demo@main")
    assert [member] = workspace.members
    assert member.checkout.branch == "main"
    assert member.checkout.head_sha == nil

    assert {:ok, project} = Projects.get(config, "demo")
    assert project.source == "implicit"

    {ls, 0} = cli(["repo", "ls"])
    assert ls =~ "LOCAL"

    {fetch, 0} = cli(["repo", "fetch", "demo", "--json"])
    assert Jason.decode!(fetch)["ok"]
  end

  test "the first commit makes the branch real and co derives from it", %{config: _config} do
    {output, 0} = cli(["repo", "init", "demo", "--json"])
    path = Jason.decode!(output)["data"]["checkout"]

    Fixtures.configure_user(path)
    Fixtures.write(path, "README.md", "# demo\n")
    Fixtures.commit!(path, "initial")

    {:ok, head} = Git.run(["rev-parse", "--verify", "refs/heads/main"], cd: path)
    assert String.trim(head.stdout) != ""

    {co, 0} = cli(["co", "demo@main", "--topic", "MT1", "--json"])
    data = Jason.decode!(co)["data"]
    assert data["workspace"] == "demo@MT1"

    assert [member] = data["members"]
    assert member["branch"] == "feature/MT1"
    assert member["head"] == String.trim(head.stdout)
  end

  test "repo init honours --branch and --topic", %{config: _config} do
    {output, 0} =
      cli(["repo", "init", "demo", "--branch", "devel", "--topic", "dev", "--json"])

    data = Jason.decode!(output)["data"]
    assert data["branch"] == "devel"
    assert data["workspace"] == "demo@dev"

    path = data["checkout"]
    {:ok, branch} = Git.run(["symbolic-ref", "--short", "HEAD"], cd: path)
    assert String.trim(branch.stdout) == "devel"
  end

  test "repo rm bundles local refs before deleting the mirror", %{config: config} do
    {output, 0} = cli(["repo", "init", "demo", "--json"])
    path = Jason.decode!(output)["data"]["checkout"]

    Fixtures.configure_user(path)
    Fixtures.write(path, "README.md", "# demo\n")
    Fixtures.commit!(path, "initial")

    {removed, 0} = cli(["repo", "rm", "demo", "--force", "--yes", "--json"])
    data = Jason.decode!(removed)["data"]

    assert data["bundle"]
    assert File.exists?(data["bundle"])
    assert File.dir?(path)
    assert {:error, _} = Repos.get(config, "demo")
    assert {:error, _} = Projects.get(config, "demo")
  end

  test "repo init rejects a duplicate name", %{config: _config} do
    {_, 0} = cli(["repo", "init", "demo", "--json"])

    {output, 4} = cli(["repo", "init", "demo", "--json"])
    assert Jason.decode!(output)["error"]["code"] == "conflict"
  end

  test "repo import seeds a local mirror and links the source clone", %{config: config} do
    source = Fixtures.source_repo!()
    {:ok, source_head} = Git.run(["rev-parse", "HEAD"], cd: source)

    {output, 0} = cli(["repo", "import", source, "--name", "demo", "--json"])
    data = Jason.decode!(output)["data"]

    assert data["repo"]["origin_kind"] == "local"
    assert data["repo"]["remote_url"] == ""
    assert data["linked"]
    assert data["branch"] == "main"

    assert {:ok, repo} = Repos.get(config, "demo")
    assert repo.remote_key =~ ~r/^local:/

    {:ok, mirror_head} = Git.run(["rev-parse", "refs/heads/main"], cd: repo.bare_path)
    assert String.trim(mirror_head.stdout) == String.trim(source_head.stdout)

    {:ok, remotes} = Git.run(["remote"], cd: repo.bare_path)
    assert String.trim(remotes.stdout) == ""

    assert {:ok, checkout} = Checkouts.get_by_path(source)
    assert checkout.repository_id == repo.id
    assert checkout.source == "external"

    # Idempotent: the source is reused, the mirror is not rebuilt.
    {again, 0} = cli(["repo", "import", source, "--name", "demo", "--json"])
    assert Jason.decode!(again)["data"]["repo"]["id"] == data["repo"]["id"]

    # The mirror is usable for a checkout.
    {co, 0} = cli(["co", "demo@main", "--json"])
    assert Jason.decode!(co)["data"]["workspace"] == "demo@main"
  end

  test "repo import can skip linking and reports divergence through the source", %{
    config: _config
  } do
    source = Fixtures.source_repo!()
    Fixtures.write(source, "notes.txt", "not imported\n")

    {output, 0} =
      cli(["repo", "import", source, "--name", "demo", "--no-link", "--json"])

    assert Jason.decode!(output)["data"]["linked"] == false
    assert {:error, _} = Checkouts.get_by_path(source)

    {again, 0} = cli(["repo", "import", source, "--name", "demo", "--json"])
    assert Jason.decode!(again)["data"]["linked"] == true
    assert {:ok, _checkout} = Checkouts.get_by_path(source)
    assert File.exists?(Path.join(source, "notes.txt"))
  end

  test "repo import refuses a checkout with a remote", %{config: _config} do
    source = Fixtures.source_repo!()
    clone = Path.join(Fixtures.tmp_dir!("import-remote"), "clone")
    Git.run!(["clone", source, clone])

    {output, 2} = cli(["repo", "import", clone, "--name", "demo", "--json"])
    assert Jason.decode!(output)["error"]["message"] =~ "has a remote"
  end

  test "repo import refuses a linked worktree and a bare repository", %{config: config} do
    source = Fixtures.source_repo!()
    bare = Fixtures.mirror!(source)
    worktree = Path.join(Fixtures.tmp_dir!("import-worktree"), "checkout")
    {:ok, _} = Gitspace.Git.Worktree.add(bare, worktree, "origin/main", detach: true)

    {worktree_out, 2} = cli(["repo", "import", worktree, "--json"])
    assert Jason.decode!(worktree_out)["error"]["message"] =~ "linked worktree"

    {bare_out, 2} = cli(["repo", "import", bare, "--json"])
    assert Jason.decode!(bare_out)["error"]["message"] =~ "bare repository"

    assert {:error, _} = Repos.get(config, "checkout")
  end

  test "repo add points a checkout without a remote at repo import", %{config: config} do
    source = Fixtures.source_repo!()

    {output, 2} = cli(["repo", "add", source, "--json"])
    assert Jason.decode!(output)["error"]["hint"] =~ "repo import"
    assert {:error, _} = Repos.get(config, Path.basename(source))
  end

  test "a committed local workspace is not at risk", %{config: config} do
    {output, 0} = cli(["repo", "init", "demo", "--json"])
    path = Jason.decode!(output)["data"]["checkout"]

    Fixtures.configure_user(path)
    Fixtures.write(path, "README.md", "# demo\n")
    Fixtures.commit!(path, "initial")

    {status, 0} = cli(["workspace", "status", "demo@main", "--refresh", "--json"])
    workspace = Jason.decode!(status)["data"]["workspace"]
    assert [member] = workspace["members"]
    assert member["unpushed"] == 0
    assert member["branch"] == "main"

    {removed, 0} = cli(["workspace", "rm", "demo@main", "--yes", "--json"])
    assert Jason.decode!(removed)["data"]["tombstoned"]

    assert {:ok, repo} = Repos.get(config, "demo")
    assert {:ok, _ref} = Git.run(["rev-parse", "refs/heads/main"], cd: repo.bare_path)
  end

  test "repo init --path uses an explicit project directory", %{config: config} do
    parent = Fixtures.tmp_dir!("explicit-project")
    path = Path.join(parent, "demo")
    File.mkdir_p!(parent)

    {output, 0} = cli(["repo", "init", "demo", "--path", path, "--json"])
    data = Jason.decode!(output)["data"]

    assert data["path"] == Path.join(path, "main")
    assert data["checkout"] == Path.join([path, "main", "demo"])

    assert {:ok, project} = Projects.get(config, "demo")
    assert project.source == "explicit"
    assert project.path == path
  end

  test "repo set-url adopts an upstream for a local repository", %{config: config} do
    {output, 0} = cli(["repo", "init", "demo", "--json"])
    first = Jason.decode!(output)["data"]
    source = Fixtures.source_repo!()
    url = Fixtures.repo_url(source)

    {set, 0} = cli(["repo", "set-url", "demo", url, "--json"])
    assert Jason.decode!(set)["data"]["url"] == url
    assert Jason.decode!(set)["data"]["fetched"] == true

    assert {:ok, repo} = Repos.get(config, "demo")
    assert repo.origin_kind == "remote"
    assert repo.remote_url == url
    assert repo.remote_key == first["identity"]
    assert repo.bare_path == first["repo"]["bare_path"]

    {fetch, 0} = cli(["repo", "fetch", "demo", "--json"])
    assert Jason.decode!(fetch)["ok"]

    {list, 0} = cli(["repo", "ls"])
    assert list =~ url
  end

  test "repo import without --name keeps the directory basename across a reindex", %{
    config: config
  } do
    source = Fixtures.source_repo!()
    name = Path.basename(source)

    {output, 0} = cli(["repo", "import", source, "--json"])
    assert Jason.decode!(output)["data"]["repo"]["slug"] == name

    assert {:ok, repo} = Repos.get(config, name)
    assert {:ok, _} = Git.run(["config", "--unset", "gitspace.alias"], cd: repo.bare_path)

    assert {:ok, _} =
             Git.run(["config", "--unset", "gitspace.alias-source"], cd: repo.bare_path)

    {_, 0} = cli(["doctor", "reindex", "--json"])

    assert {:ok, repo} = Repos.get(config, name)
    assert repo.slug == name
    refute repo.slug == "local"
  end

  test "reindex recovers a local repository that was renamed to local", %{config: config} do
    source = Fixtures.source_repo!()
    name = Path.basename(source)

    {_, 0} = cli(["repo", "import", source, "--json"])
    assert {:ok, repo} = Repos.get(config, name)

    assert {:ok, _} = Git.run(["config", "--unset", "gitspace.alias"], cd: repo.bare_path)

    assert {:ok, _} =
             Git.run(["config", "--unset", "gitspace.alias-source"], cd: repo.bare_path)

    assert {:ok, renamed} =
             repo
             |> Ecto.Changeset.change(slug: "local", alias_source: "auto")
             |> Repo.update()

    {_, 0} = cli(["doctor", "reindex", "--json"])

    assert {:ok, recovered} = Repos.get(config, name)
    assert recovered.id == renamed.id
    assert recovered.slug == name
  end

  defp cli(args) do
    {code, output} = ExUnit.CaptureIO.with_io(fn -> Gitspace.CLI.run(args) end)
    {output, code}
  end
end
