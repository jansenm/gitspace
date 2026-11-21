defmodule Gitspace.CLITest do
  use Gitspace.IndexCase, async: false

  alias Gitspace.{Config, Fixtures, Git, Index, Marker, Projects, Repos}
  alias Gitspace.Git.Worktree
  alias Gitspace.Index.Repository

  setup %{config: config} do
    :ok = Config.save(config)
    System.delete_env("GITSPACE_DATA")
    System.delete_env("GITSPACE_PROJECTS_ROOT")
    previous = System.get_env("GITSPACE_CONFIG")
    System.put_env("GITSPACE_CONFIG", config.path)

    on_exit(fn ->
      if previous do
        System.put_env("GITSPACE_CONFIG", previous)
      else
        System.delete_env("GITSPACE_CONFIG")
      end
    end)

    source = Fixtures.source_repo!()
    {:ok, repo} = Repos.add(config, Fixtures.repo_url(source), name: "demo")

    {:ok, _project} = Projects.create(config, "demo", repo: ["demo"])
    path = Path.join([config.projects_root, "demo", "JENKINS-123", "demo"])
    File.mkdir_p!(Path.dirname(path))
    {:ok, _} = Worktree.add(repo.bare_path, path, "origin/main", branch: "feature_JENKINS-123")

    Marker.write!(Path.dirname(path), %{
      "schema_version" => 1,
      "workspace" => "demo/JENKINS-123",
      "project" => "demo",
      "topic" => "JENKINS-123",
      "description" => "move the deploy job",
      "labels" => ["jira-123"],
      "members" => [
        %{
          "repo" => "demo",
          "ownership" => "owned",
          "rel_path" => "demo",
          "branch" => "feature_JENKINS-123"
        }
      ]
    })

    {:ok, _summary} = Index.reindex(config)

    {:ok, repo: repo, path: path, source: source}
  end

  test "INV-8/MACH-1 workspace status is a JSON envelope", %{path: path} do
    {output, 0} = cli(["status", "JENKINS-123", "--json"])
    data = Jason.decode!(output)

    assert data["ok"] == true
    assert data["schema_version"] == 1
    assert data["data"]["workspace"]["name"] == "demo/JENKINS-123"
    assert data["data"]["workspace"]["labels"] == ["jira-123"]
    assert [member] = data["data"]["workspace"]["members"]
    assert member["path"] == path
    assert member["ownership"] == "owned"
  end

  test "INV-4/MACH-1 ls filters and path resolve", %{path: path, repo: repo} do
    {output, 0} = cli(["ls", "--repo", "demo", "--json"])
    data = Jason.decode!(output)
    assert [checkout] = data["data"]["checkouts"]
    assert checkout["repo"] == "demo"
    assert checkout["workspace"] == "demo/JENKINS-123"
    assert checkout["mirror"] == repo.bare_path
    assert checkout["hash"] == Path.basename(repo.bare_path, ".git")

    {path_output, 0} = cli(["path", "demo/JENKINS-123:demo", "--json"])
    assert Jason.decode!(path_output)["data"]["path"] == path
  end

  test "ls is compact by default and --verbose adds hash and mirror", %{repo: repo} do
    {plain, 0} = cli(["ls"])
    assert plain =~ "PROJECT"
    assert plain =~ "TOPIC"
    assert plain =~ "MEMBER"
    refute plain =~ "PATH"
    refute plain =~ "MIRROR"
    refute plain =~ "HASH"
    assert plain |> String.split("\n", trim: true) |> Enum.all?(&(String.length(&1) <= 100))

    {verbose, 0} = cli(["ls", "--verbose"])
    hash = Path.basename(repo.bare_path, ".git")
    assert verbose =~ "HASH"
    assert verbose =~ "MIRROR"
    assert verbose =~ repo.bare_path
    assert verbose =~ String.slice(hash, 0, 12)
    refute verbose =~ "PATH"
  end

  test "MACH-2 unknown target is exit 3 with a stable code" do
    {output, 3} = cli(["status", "does-not-exist", "--json"])
    error = Jason.decode!(output)["error"]
    assert error["code"] == "not_found"
  end

  test "MACH-3 --json never prompts for confirmation" do
    {output, 6} = cli(["repo", "rm", "demo", "--json"])
    error = Jason.decode!(output)["error"]
    assert error["code"] == "confirmation_required"
  end

  test "ENV-2 setup refuses a sync-root checkout directory" do
    {output, 5} =
      cli([
        "setup",
        "--checkouts",
        "/data/mjansen/nextcloud/shared/work",
        "--json"
      ])

    error = Jason.decode!(output)["error"]
    assert error["code"] == "refused"
    assert error["message"] =~ "file-sync"
  end

  test "REC-1 reindex recovers a workspace after the index is deleted", %{config: config} do
    Repo.delete_all(Repository)
    assert [] = Repos.list(config)

    {output, 0} = cli(["reindex", "--json"])
    data = Jason.decode!(output)["data"]
    assert data["discovered_repositories"] == 1
    assert data["workspaces"] == 1

    {status_output, 0} = cli(["status", "JENKINS-123", "--json"])
    workspace = Jason.decode!(status_output)["data"]["workspace"]
    assert workspace["name"] == "demo/JENKINS-123"
    assert workspace["labels"] == ["jira-123"]
  end

  test "doctor reports a clean environment as JSON" do
    {output, 0} = cli(["doctor", "--json"])
    data = Jason.decode!(output)["data"]

    assert data["summary"]["fail"] == 0
    assert Enum.any?(data["checks"], &(&1["name"] == "git" and &1["status"] == "ok"))
    assert Enum.any?(data["checks"], &(&1["name"] == "index" and &1["status"] == "ok"))
  end

  test "repo shows help and repo ls includes the remote URI", %{source: source} do
    {help, 0} = cli(["repo"])
    assert help =~ "gitspace repo add"
    assert help =~ "gitspace repo rm"

    {output, 0} = cli(["repo", "ls"])
    assert output =~ "REMOTE"
    assert output =~ "demo"
    assert output =~ source
  end

  test "repo add reads remote URLs from an existing checkout", %{source: source} do
    clone = Path.join(Fixtures.tmp_dir!("cli-checkout"), "checkout")
    Git.run!(["clone", source, clone])
    Git.run!(["remote", "add", "upstream", "git@example.com:cli/config.git"], cd: clone)

    {output, 2} = cli(["repo", "add", clone, "--json"])
    error = Jason.decode!(output)["error"]
    assert error["code"] == "usage"
    assert error["hint"] =~ "--remote"
    assert Enum.any?(error["details"]["remotes"], &(&1["name"] == "upstream"))

    {created, 0} =
      cli([
        "repo",
        "add",
        clone,
        "--remote",
        "upstream",
        "--name",
        "upstream-cli",
        "--no-fetch",
        "--json"
      ])

    repo = Jason.decode!(created)["data"]["repo"]
    assert repo["slug"] == "upstream-cli"
    assert repo["remote_url"] == "git@example.com:cli/config.git"
    assert repo["remote_key"] == "example.com/cli/config"
  end

  test "repo alias changes the persistent alias", %{source: source} do
    {output, 0} = cli(["repo", "alias", "demo", "renamed"])
    assert output =~ "alias: renamed"

    {list, 0} = cli(["repo", "ls"])
    assert list =~ "REMOTE"
    assert list =~ source
    assert list =~ "renamed"
  end

  test "doctor warns on mirror index drift and --fix reconciles it", %{config: config} do
    File.rm!(Gitspace.MirrorIndex.path(config))

    {output, 0} = cli(["doctor", "--json"])
    data = Jason.decode!(output)["data"]
    mirrors = Enum.find(data["checks"], &(&1["name"] == "mirrors"))
    assert mirrors["status"] == "warn"
    assert mirrors["detail"] =~ "missing_from_text"

    {fixed, 0} = cli(["doctor", "--fix", "--json"])
    fixes = Jason.decode!(fixed)["data"]["fixes"]
    assert Enum.any?(fixes, &(&1["discovered"] == 1 and &1["issues"] == 0))
    assert File.exists?(Gitspace.MirrorIndex.path(config))

    {again, 0} = cli(["doctor", "--json"])
    again_data = Jason.decode!(again)["data"]
    assert Enum.find(again_data["checks"], &(&1["name"] == "mirrors"))["status"] == "ok"
  end

  defp cli(args) do
    {code, output} = ExUnit.CaptureIO.with_io(fn -> Gitspace.CLI.run(args) end)
    {output, code}
  end
end
