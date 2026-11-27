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
      "workspace" => "demo@JENKINS-123",
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
    assert data["data"]["workspace"]["name"] == "demo@JENKINS-123"
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
    assert checkout["workspace"] == "demo@JENKINS-123"
    assert checkout["mirror"] == repo.bare_path
    assert checkout["hash"] == Path.basename(repo.bare_path, ".git")

    {path_output, 0} = cli(["path", "demo@JENKINS-123:demo", "--json"])
    assert Jason.decode!(path_output)["data"]["path"] == path
  end

  test "status resolves project/topic/member paths before repository aliases", %{
    config: config,
    path: path
  } do
    relative = Path.relative_to(path, config.projects_root)
    assert relative == "demo/JENKINS-123/demo"

    {output, 0} = cli(["status", relative, "--json"])
    data = Jason.decode!(output)["data"]

    assert data["checkout"]["path"] == path
    assert data["checkout"]["workspace"] == "demo@JENKINS-123"
    refute Map.has_key?(data, "repo")
  end

  test "status resolves project/topic/member from the index when the topic directory is slugged",
       %{
         config: config
       } do
    # topic `feature/x` is stored in the slugged directory `feature-x`, so the
    # literal path `demo/feature/x/demo` does not exist.
    {_output, 0} = cli(["co", "demo@main", "--topic", "feature/x"])

    path = Path.join([config.projects_root, "demo", "feature-x", "demo"])
    assert File.dir?(path)
    refute File.exists?(Path.join(config.projects_root, "demo/feature/x/demo"))

    {output, 0} = cli(["status", "demo/feature/x/demo", "--json"])
    data = Jason.decode!(output)["data"]

    assert data["checkout"]["path"] == path
    assert data["checkout"]["workspace"] == "demo@feature/x"
    refute Map.has_key?(data, "repo")
  end

  test "status project/topic/typo reports the missing member instead of a repo listing" do
    {output, 3} = cli(["status", "demo/JENKINS-123/nope", "--json"])
    error = Jason.decode!(output)["error"]

    assert error["code"] == "not_found"
    assert error["message"] =~ "member not found"
  end

  test "a layout-shaped target never falls back to a repository listing", %{} do
    # The last segment is the repository slug, but `demo/nope/demo` is not a
    # workspace path; it must not silently become `status repo:demo`.
    {output, 3} = cli(["status", "demo/nope/demo", "--json"])
    error = Jason.decode!(output)["error"]

    assert error["code"] == "not_found"
    assert error["message"] =~ "no workspace or member"
    assert error["hint"] =~ "repo:"
  end

  test "status still reports every checkout for an explicit repository target", %{
    path: path
  } do
    {output, 0} = cli(["status", "repo:demo", "--json"])
    data = Jason.decode!(output)["data"]

    assert data["repo"] == "demo"
    assert [checkout] = data["checkouts"]
    assert checkout["path"] == path
  end

  test "ls --refresh recomputes cached status without fetching", %{path: path} do
    Gitspace.Repo.update_all(Gitspace.Index.Checkout, set: [last_status_at: nil])
    File.write!(Path.join(path, "dirty.txt"), "x\n")

    {stale, 0} = cli(["ls", "--repo", "demo", "--json"])
    assert [before] = Jason.decode!(stale)["data"]["checkouts"]
    assert before["stale"]

    {fresh, 0} = cli(["ls", "--repo", "demo", "--refresh", "--json"])
    assert [refreshed] = Jason.decode!(fresh)["data"]["checkouts"]
    refute refreshed["stale"]
    assert refreshed["untracked"] == 1
  end

  test "status --refresh recomputes every indexed checkout", %{config: config} do
    Gitspace.Repo.update_all(Gitspace.Index.Checkout, set: [last_status_at: nil])

    {output, 0} = cli(["status", "--refresh", "--json"])
    assert Jason.decode!(output)["ok"]

    assert Enum.all?(Gitspace.Checkouts.list(config), & &1.last_status_at)
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
    assert workspace["name"] == "demo@JENKINS-123"
    assert workspace["labels"] == ["jira-123"]
  end

  test "doctor reports a clean environment as JSON" do
    {output, 0} = cli(["doctor", "--json"])
    data = Jason.decode!(output)["data"]

    assert data["summary"]["fail"] == 0
    assert Enum.any?(data["checks"], &(&1["name"] == "git" and &1["status"] == "ok"))
    assert Enum.any?(data["checks"], &(&1["name"] == "index" and &1["status"] == "ok"))
  end

  test "log reports outgoing and incoming commits", %{
    config: config,
    path: path,
    repo: repo,
    source: source
  } do
    Fixtures.configure_user(path)
    Fixtures.write(path, "outgoing.txt", "out\n")
    Fixtures.commit!(path, "outgoing work")

    {output, 0} = cli(["log", "demo@JENKINS-123:demo", "--json"])
    data = Jason.decode!(output)["data"]

    assert data["limit"] == 10
    assert data["directions"] == ["outgoing", "incoming"]
    assert [entry] = data["entries"]
    assert entry["handle"] == "demo@JENKINS-123:demo"
    assert entry["upstream"] == "origin/main"
    assert entry["outgoing"]["total"] == 1
    assert [commit] = entry["outgoing"]["commits"]
    assert commit["subject"] == "outgoing work"
    assert entry["incoming"]["total"] == 0

    Fixtures.write(source, "upstream.txt", "up\n")
    Fixtures.commit!(source, "upstream work")
    Gitspace.Git.Mirror.fetch!(repo.bare_path)

    {incoming, 0} = cli(["log", "demo@JENKINS-123:demo", "--json"])
    entry = Jason.decode!(incoming)["data"]["entries"] |> hd()

    assert entry["incoming"]["total"] == 1
    assert [%{"subject" => "upstream work"}] = entry["incoming"]["commits"]
    assert entry["outgoing"]["total"] == 1

    :ok = Config.save(%{config | log_max_commits: 1})
    {limited, 0} = cli(["log", "demo@JENKINS-123:demo", "--json"])
    limited_data = Jason.decode!(limited)["data"]

    assert limited_data["limit"] == 1
    assert hd(limited_data["entries"])["incoming"]["truncated"] == false

    {all, 0} = cli(["log", "demo@JENKINS-123:demo", "--all", "--json"])
    assert Jason.decode!(all)["data"]["limit"] == nil

    {fetched, 0} = cli(["log", "demo@JENKINS-123:demo", "--fetch", "--json"])
    assert Jason.decode!(fetched)["ok"]

    {conflict, 2} = cli(["log", "demo@JENKINS-123:demo", "--limit", "1", "--all", "--json"])
    assert Jason.decode!(conflict)["error"]["code"] == "usage"

    {text, 0} = cli(["log", "demo@JENKINS-123:demo"])
    assert text =~ "outgoing work"
    assert text =~ "upstream work"
  end

  test "log can target a repository and rejects projects", %{} do
    {output, 0} = cli(["log", "repo:demo", "--json"])
    assert [entry] = Jason.decode!(output)["data"]["entries"]
    assert entry["repo"] == "demo"

    {output, 2} = cli(["log", "demo", "--json"])
    assert Jason.decode!(output)["error"]["code"] == "usage"

    {output, 2} = cli(["log", "repo:demo", "--limit", "0", "--json"])
    assert Jason.decode!(output)["error"]["code"] == "usage"
  end

  test "status --long lists files and --diff shows the capped patch", %{path: path} do
    File.write!(Path.join(path, "README.md"), "# changed\n")
    File.write!(Path.join(path, "untracked.txt"), "new\n")

    {output, 0} = cli(["status", "demo@JENKINS-123:demo", "--long", "--json"])
    changes = Jason.decode!(output)["data"]["changes"]

    assert Enum.any?(changes, &(&1["path"] == "README.md" and &1["status"] == ".M"))
    assert Enum.any?(changes, &(&1["path"] == "untracked.txt" and &1["status"] == "??"))

    {diff, 0} = cli(["status", "demo@JENKINS-123:demo", "-v", "--json"])
    patch = Jason.decode!(diff)["data"]["diff"]

    assert patch["unstaged"] =~ "README.md"
    assert patch["unstaged"] =~ "+# changed"
    assert patch["truncated"] == false

    {truncated, 0} =
      cli(["status", "demo@JENKINS-123:demo", "-v", "--diff-lines", "1", "--json"])

    capped = Jason.decode!(truncated)["data"]["diff"]
    assert capped["truncated"] == true
    assert capped["unstaged"] =~ "truncated"

    {text, 0} = cli(["status", "demo@JENKINS-123:demo", "-l"])
    assert text =~ "files:"
    assert text =~ "README.md"
    assert text =~ "untracked.txt"
  end

  test "status detail flags need one checkout target" do
    {output, 2} = cli(["status", "--long", "--json"])
    assert Jason.decode!(output)["error"]["code"] == "usage"

    {output, 2} = cli(["status", "demo@JENKINS-123", "--long", "--json"])
    assert Jason.decode!(output)["error"]["code"] == "usage"
  end

  test "push publishes the checked-out branch", %{path: path, source: source} do
    Fixtures.configure_user(path)
    Fixtures.write(path, "push.txt", "push\n")
    Fixtures.commit!(path, "push work")

    {output, 0} = cli(["push", "demo@JENKINS-123:demo", "--json"])
    data = Jason.decode!(output)["data"]

    assert data["dry_run"] == false
    assert [entry] = data["entries"]
    assert entry["status"] == "pushed"
    assert entry["remote"] == "origin"
    assert entry["upstream"] == "origin/feature_JENKINS-123"
    assert entry["commits"] == 1

    ref =
      Gitspace.Git.run!(["rev-parse", "--verify", "refs/heads/feature_JENKINS-123"], cd: source)

    assert String.trim(ref) != ""

    {again, 0} = cli(["push", "demo@JENKINS-123:demo", "--json"])
    assert hd(Jason.decode!(again)["data"]["entries"])["status"] == "up_to_date"

    {workspace, 0} = cli(["push", "demo@JENKINS-123", "--json"])
    assert [entry] = Jason.decode!(workspace)["data"]["entries"]
    assert entry["handle"] == "demo@JENKINS-123:demo"
  end

  test "push dry-run does not update the remote", %{path: path, source: source} do
    Fixtures.configure_user(path)
    Fixtures.write(path, "first.txt", "1\n")
    Fixtures.commit!(path, "first")
    {_, 0} = cli(["push", "demo@JENKINS-123:demo", "--json"])
    before = Gitspace.Git.run!(["rev-parse", "refs/heads/feature_JENKINS-123"], cd: source)

    Fixtures.write(path, "second.txt", "2\n")
    Fixtures.commit!(path, "second")

    {output, 0} = cli(["push", "demo@JENKINS-123:demo", "--dry-run", "--json"])
    entry = Jason.decode!(output)["data"]["entries"] |> hd()

    assert entry["status"] == "would_push"
    assert entry["commits"] == 1

    after_push = Gitspace.Git.run!(["rev-parse", "refs/heads/feature_JENKINS-123"], cd: source)
    assert String.trim(after_push) == String.trim(before)
  end

  test "push force flags are explicit and exclusive", %{path: path, source: source} do
    Fixtures.configure_user(path)
    Fixtures.write(path, "first.txt", "1\n")
    Fixtures.commit!(path, "first")

    {output, 2} =
      cli(["push", "demo@JENKINS-123:demo", "--force", "--force-with-lease", "--json"])

    assert Jason.decode!(output)["error"]["code"] == "usage"

    {output, 0} = cli(["push", "demo@JENKINS-123:demo", "--force-with-lease", "--json"])
    entry = Jason.decode!(output)["data"]["entries"] |> hd()
    assert entry["status"] == "pushed"
    assert entry["force"] == "force_with_lease"

    Gitspace.Git.run!(["commit", "--amend", "-m", "rewritten"], cd: path)

    {output, 0} = cli(["push", "demo@JENKINS-123:demo", "--force", "--json"])
    entry = Jason.decode!(output)["data"]["entries"] |> hd()
    assert entry["status"] == "pushed"
    assert entry["force"] == "force"

    remote =
      Gitspace.Git.run!(["rev-parse", "refs/heads/feature_JENKINS-123"], cd: source)
      |> String.trim()

    local = Gitspace.Git.run!(["rev-parse", "HEAD"], cd: path) |> String.trim()
    assert remote == local
  end

  test "push refuses detached checkouts and projects", %{path: path} do
    Gitspace.Git.run!(["checkout", "--detach"], cd: path)

    {output, 5} = cli(["push", "demo@JENKINS-123:demo", "--json"])
    assert Jason.decode!(output)["error"]["code"] == "refused"

    {output, 2} = cli(["push", "demo", "--json"])
    assert Jason.decode!(output)["error"]["code"] == "usage"
  end

  test "rebase rebases every worktree onto its upstream", %{
    path: path,
    repo: repo,
    source: source
  } do
    Fixtures.configure_user(path)

    Fixtures.write(source, "upstream.txt", "up\n")
    Fixtures.commit!(source, "upstream work")
    Gitspace.Git.Mirror.fetch!(repo.bare_path)

    Fixtures.write(path, "local.txt", "local\n")
    Fixtures.commit!(path, "local work")

    {output, 0} = cli(["rebase", "--json"])
    data = Jason.decode!(output)["data"]

    assert data["mode"] == "start"
    assert [entry] = data["entries"]
    assert entry["status"] == "rebased"
    assert entry["upstream"] == "origin/main"
    assert entry["commits"] == 1
    assert Gitspace.Git.Operation.read(path) == nil

    {again, 0} = cli(["rebase", "--json"])
    entry = Jason.decode!(again)["data"]["entries"] |> hd()
    assert entry["status"] == "up_to_date"
  end

  test "a not-yet-pushed branch is reported up to date in text and JSON", %{
    path: path
  } do
    Git.run!(["config", "branch.feature_JENKINS-123.remote", "origin"], cd: path)

    Git.run!(
      ["config", "branch.feature_JENKINS-123.merge", "refs/heads/feature_JENKINS-123"],
      cd: path
    )

    {json, 0} = cli(["rebase", "demo@JENKINS-123:demo", "--json"])
    entry = Jason.decode!(json)["data"]["entries"] |> hd()
    assert entry["status"] == "up_to_date"
    assert entry["hint"] =~ "does not exist"

    {text, 0} = cli(["rebase", "demo@JENKINS-123:demo"])
    assert text =~ "result:   up to date"
    assert text =~ "does not exist"
  end

  test "base shows, sets and clears the recorded rebase base", %{path: path} do
    {shown, 0} = cli(["base", "demo@JENKINS-123", "--json"])
    [entry] = Jason.decode!(shown)["data"]["entries"]
    assert entry["branch"] == "feature_JENKINS-123"
    assert entry["base"] == "origin/main"
    assert entry["source"] == "upstream"

    {set, 0} = cli(["base", "demo@JENKINS-123:demo", "origin/main", "--json"])
    [entry] = Jason.decode!(set)["data"]["entries"]
    assert entry["source"] == "recorded"

    assert Git.run!(["config", "--get", "branch.feature_JENKINS-123.gitspace-base"], cd: path)
           |> String.trim() == "origin/main"

    {text, 0} = cli(["base", "demo@JENKINS-123"])
    assert text =~ "feature_JENKINS-123"
    assert text =~ "origin/main"
    assert text =~ "recorded"

    {cleared, 0} = cli(["base", "demo@JENKINS-123", "--clear", "--json"])
    [entry] = Jason.decode!(cleared)["data"]["entries"]
    assert entry["source"] == "upstream"

    assert {:error, _} =
             Git.run(["config", "--get", "branch.feature_JENKINS-123.gitspace-base"], cd: path)
  end

  test "base reports a missing checkout without crashing", %{path: path} do
    File.rm_rf!(path)

    {output, 0} = cli(["base", "demo@JENKINS-123", "--json"])
    [entry] = Jason.decode!(output)["data"]["entries"]

    assert entry["source"] == "checkout missing"
    assert entry["base"] == nil
  end

  test "base refuses an unknown ref without writing", %{path: path} do
    {output, 3} = cli(["base", "demo@JENKINS-123", "origin/nope", "--json"])
    assert Jason.decode!(output)["error"]["code"] == "not_found"

    assert {:error, _} =
             Git.run(["config", "--get", "branch.feature_JENKINS-123.gitspace-base"], cd: path)
  end

  test "base applies to every checkout of a repo target", %{path: path} do
    {output, 0} = cli(["base", "repo:demo", "origin/main", "--json"])
    [entry] = Jason.decode!(output)["data"]["entries"]
    assert entry["handle"] == "demo"
    assert entry["source"] == "recorded"

    assert {:ok, _} =
             Git.run(["config", "--get", "branch.feature_JENKINS-123.gitspace-base"], cd: path)
  end

  test "a rebase conflict is visible in status, ls and the inbox", %{
    path: path,
    repo: repo,
    source: source
  } do
    Fixtures.configure_user(path)

    Fixtures.write(source, "README.md", "# remote\n")
    Fixtures.commit!(source, "remote change")
    Gitspace.Git.Mirror.fetch!(repo.bare_path)

    Fixtures.write(path, "README.md", "# local\n")
    Fixtures.commit!(path, "local change")

    {conflict, 4} = cli(["rebase", "--json"])
    error = Jason.decode!(conflict)["error"]

    assert error["code"] == "conflict"
    assert [entry] = error["details"]["entries"]
    assert entry["status"] == "conflict"
    assert entry["files"] == ["README.md"]

    {status, 0} = cli(["status", "demo@JENKINS-123:demo", "--json"])
    checkout = Jason.decode!(status)["data"]["checkout"]
    assert checkout["operation"]["kind"] == "rebase"
    assert Enum.any?(checkout["risk"]["reasons"], &String.starts_with?(&1, "rebase in progress"))

    {ls, 0} = cli(["ls", "--json"])
    row = Jason.decode!(ls)["data"]["checkouts"] |> hd()
    assert Enum.any?(row["risk"]["reasons"], &String.starts_with?(&1, "rebase in progress"))

    {inbox, 0} = cli(["--json"])
    assert Enum.any?(Jason.decode!(inbox)["data"]["needs"], &(&1["name"] == "demo@JENKINS-123"))

    File.write!(Path.join(path, "README.md"), "# resolved\n")
    Gitspace.Git.run!(["add", "README.md"], cd: path)

    {continued, 0} = cli(["rebase", "--continue", "demo@JENKINS-123:demo", "--json"])
    entry = Jason.decode!(continued)["data"]["entries"] |> hd()
    assert entry["status"] == "rebased"
    assert Gitspace.Git.Operation.read(path) == nil
  end

  test "batch abort needs confirmation", %{path: path, repo: repo, source: source} do
    Fixtures.configure_user(path)

    Fixtures.write(source, "README.md", "# remote\n")
    Fixtures.commit!(source, "remote change")
    Gitspace.Git.Mirror.fetch!(repo.bare_path)

    Fixtures.write(path, "README.md", "# local\n")
    Fixtures.commit!(path, "local change")

    {_, 4} = cli(["rebase", "--json"])

    {refused, 6} = cli(["rebase", "--abort", "--json"])
    assert Jason.decode!(refused)["error"]["code"] == "confirmation_required"

    {aborted, 0} = cli(["rebase", "--abort", "--yes", "--json"])
    entry = Jason.decode!(aborted)["data"]["entries"] |> hd()
    assert entry["status"] == "aborted"
    assert Gitspace.Git.Operation.read(path) == nil
  end

  test "batch abort rolls back completed rebases", %{path: path, repo: repo, source: source} do
    Fixtures.configure_user(path)

    Fixtures.write(source, "upstream.txt", "up\n")
    Fixtures.commit!(source, "upstream work")
    Gitspace.Git.Mirror.fetch!(repo.bare_path)

    Fixtures.write(path, "local.txt", "local\n")
    Fixtures.commit!(path, "local work")
    original = head(path)

    {_, 0} = cli(["rebase", "--json"])
    refute head(path) == original

    {output, 0} = cli(["rebase", "--abort", "--yes", "--json"])
    entry = Jason.decode!(output)["data"]["entries"] |> hd()

    assert entry["status"] == "rolled_back"
    assert entry["new_head"] == original
    assert head(path) == original

    assert Gitspace.Git.run!(["log", "-1", "--format=%s"], cd: path) |> String.trim() ==
             "local work"
  end

  test "rollback skips a worktree whose head moved", %{path: path, repo: repo, source: source} do
    Fixtures.configure_user(path)

    Fixtures.write(source, "upstream.txt", "up\n")
    Fixtures.commit!(source, "upstream work")
    Gitspace.Git.Mirror.fetch!(repo.bare_path)
    Fixtures.write(path, "local.txt", "local\n")
    Fixtures.commit!(path, "local work")

    {_, 0} = cli(["rebase", "--json"])

    Fixtures.write(path, "later.txt", "later\n")
    Fixtures.commit!(path, "later work")
    later = head(path)

    {output, 0} = cli(["rebase", "--abort", "--yes", "--json"])
    entry = Jason.decode!(output)["data"]["entries"] |> hd()

    assert entry["status"] == "skipped"
    assert entry["reason"] =~ "HEAD moved"
    assert head(path) == later
  end

  test "abort rolls back a rebase that was continued earlier", %{
    path: path,
    repo: repo,
    source: source
  } do
    Fixtures.configure_user(path)

    Fixtures.write(source, "README.md", "# remote\n")
    Fixtures.commit!(source, "remote change")
    Gitspace.Git.Mirror.fetch!(repo.bare_path)

    Fixtures.write(path, "README.md", "# local\n")
    Fixtures.commit!(path, "local change")
    original = head(path)

    {_, 4} = cli(["rebase", "--json"])

    File.write!(Path.join(path, "README.md"), "# resolved\n")
    Gitspace.Git.run!(["add", "README.md"], cd: path)
    {_, 0} = cli(["rebase", "--continue", "demo@JENKINS-123:demo", "--json"])
    refute head(path) == original

    {output, 0} = cli(["rebase", "--abort", "--yes", "--json"])
    entry = Jason.decode!(output)["data"]["entries"] |> hd()

    assert entry["status"] == "rolled_back"
    assert head(path) == original

    assert Gitspace.Git.run!(["log", "-1", "--format=%s"], cd: path) |> String.trim() ==
             "local change"
  end

  test "targeted abort rolls back without confirmation", %{path: path, repo: repo, source: source} do
    Fixtures.configure_user(path)

    Fixtures.write(source, "upstream.txt", "up\n")
    Fixtures.commit!(source, "upstream work")
    Gitspace.Git.Mirror.fetch!(repo.bare_path)
    Fixtures.write(path, "local.txt", "local\n")
    Fixtures.commit!(path, "local work")
    original = head(path)

    {_, 0} = cli(["rebase", "--json"])
    refute head(path) == original

    {output, 0} = cli(["rebase", "--abort", "demo@JENKINS-123:demo", "--json"])
    entry = Jason.decode!(output)["data"]["entries"] |> hd()

    assert entry["status"] == "rolled_back"
    assert head(path) == original
  end

  test "rebase refuses a dirty worktree per entry", %{path: path} do
    File.write!(Path.join(path, "dirty.txt"), "dirty\n")

    {output, 5} = cli(["rebase", "demo@JENKINS-123:demo", "--json"])
    error = Jason.decode!(output)["error"]

    assert error["code"] == "refused"
    assert [entry] = error["details"]["entries"]
    assert entry["status"] == "failed"
    assert entry["error"] =~ "not clean"
  end

  test "batch continue with nothing in progress is a no-op", %{} do
    {output, 0} = cli(["rebase", "--continue", "--json"])
    assert Jason.decode!(output)["data"]["entries"] == []
  end

  test "repo fetch --all reports each repository inline", %{} do
    {output, 0} = cli(["repo", "fetch", "--all"])
    assert output =~ "fetching demo ... ok"
    assert output =~ "fetched 1 repositories"

    {json, 0} = cli(["repo", "fetch", "--all", "--json"])
    refute json =~ "fetching"
    assert Jason.decode!(json)["data"]["fetched"] == ["demo"]
    assert Jason.decode!(json)["data"]["inline"] == false
  end

  test "repo shows help and repo ls includes the remote URI", %{source: source, repo: repo} do
    {help, 0} = cli(["repo"])
    assert help =~ "gitspace repo add"
    assert help =~ "gitspace repo rm"
    assert help =~ "gitspace repo ls [--verbose]"

    {output, 0} = cli(["repo", "ls"])
    assert output =~ "REMOTE"
    assert output =~ "demo"
    assert output =~ source
    refute output =~ "HASH"
    refute output =~ "MIRROR"
    refute output =~ repo.bare_path

    {verbose, 0} = cli(["repo", "ls", "--verbose"])
    assert verbose =~ "HASH"
    assert verbose =~ "MIRROR"
    assert verbose =~ repo.bare_path
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

  test "repo set-url updates the fetch URL and the index", %{
    config: config,
    repo: repo,
    source: source
  } do
    {output, 0} = cli(["--json", "repo", "set-url", "demo", source])
    data = Jason.decode!(output)["data"]

    assert data["target"] == "fetch"
    assert data["url"] == source
    assert data["previous"] == [repo.remote_url]

    assert {:ok, updated} = Repos.get(config, "demo")
    assert updated.remote_url == source

    assert Git.run!(["config", "--get", "remote.origin.url"], cd: updated.bare_path)
           |> String.trim() == source

    {list, 0} = cli(["repo", "ls"])
    assert list =~ source
  end

  test "repo set-url --push leaves the fetch URL alone", %{
    config: config,
    repo: repo,
    source: source
  } do
    {output, 0} = cli(["--json", "repo", "set-url", "demo", source, "--push"])
    data = Jason.decode!(output)["data"]

    assert data["target"] == "push"
    assert data["previous"] == []

    assert Git.run!(["config", "--get", "remote.origin.pushurl"], cd: repo.bare_path)
           |> String.trim() == source

    assert {:ok, unchanged} = Repos.get(config, "demo")
    assert unchanged.remote_url == repo.remote_url
  end

  test "repo set-url changes host and path while keeping the identity", %{
    config: config,
    repo: repo
  } do
    moved = "git@example.com:other/repo.git"

    {output, 0} = cli(["--json", "repo", "set-url", "demo", moved])
    data = Jason.decode!(output)["data"]

    assert data["target"] == "fetch"
    assert data["url"] == moved

    assert {:ok, updated} = Repos.get(config, "demo")
    assert updated.remote_url == moved
    assert updated.remote_key == repo.remote_key
    assert updated.bare_path == repo.bare_path

    assert Git.run!(["config", "--get", "remote.origin.url"], cd: repo.bare_path)
           |> String.trim() == moved
  end

  test "doctor --fix renders the keep fix without a repo key", %{config: _config} do
    {output, 0} = cli(["doctor", "--fix"])
    assert output =~ "pruned keep refs"
  end

  test "repo branches lists refs, marks checkouts and filters", %{config: _config} do
    {output, 0} = cli(["repo", "branches", "demo"])
    assert output =~ "branches demo"
    assert output =~ "feature_JENKINS-123"
    assert output =~ "checked out:"
    assert output =~ "default"

    {glob, 0} = cli(["repo", "branches", "demo", "--match", "feature_*"])
    assert glob =~ "feature_JENKINS-123"
    refute glob =~ " main "

    {regex, 0} = cli(["repo", "branches", "demo", "--regex", "^feature_"])
    assert regex =~ "feature_JENKINS-123"

    {none, 0} = cli(["repo", "branches", "demo", "--match", "nope*"])
    assert none =~ "(none)"

    {2, error} =
      ExUnit.CaptureIO.with_io(:stderr, fn ->
        Gitspace.CLI.run(["repo", "branches", "demo", "--match", "*", "--regex", "."])
      end)

    assert error =~ "--match and --regex are mutually exclusive"
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

  defp head(path) do
    Gitspace.Git.run!(["rev-parse", "HEAD"], cd: path) |> String.trim()
  end

  defp cli(args) do
    {code, output} = ExUnit.CaptureIO.with_io(fn -> Gitspace.CLI.run(args) end)
    {output, code}
  end
end
