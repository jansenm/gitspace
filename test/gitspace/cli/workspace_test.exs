defmodule Gitspace.CLI.WorkspaceTest do
  use Gitspace.IndexCase, async: false

  alias Gitspace.{Config, Fixtures, Git, Marker, Repos}

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

    source_a = Fixtures.source_repo!(branches: ["hotfix/timeout"], tags: ["v1.0.0"])
    source_b = Fixtures.source_repo!()

    {:ok, _repo_a} = Repos.add(config, Fixtures.repo_url(source_a), name: "a")
    {:ok, _repo_b} = Repos.add(config, Fixtures.repo_url(source_b), name: "b")

    {:ok, config: config, source_a: source_a}
  end

  test "CREATE-15 co --json returns work, path, ref, head and labels" do
    {output, 0} = cli(["co", "a@main", "--label", "one", "--label", "two", "--json"])
    data = Jason.decode!(output)

    assert data["ok"]
    assert data["schema_version"] == 1
    assert data["data"]["work"] == "a@main"

    assert data["data"]["members"] |> hd() |> Map.get("path") ==
             Path.join([data_root(), "work", "a", "main", "a"])

    assert data["data"]["ref"] == "main"
    assert data["data"]["branch"] == "main"
    assert data["data"]["labels"] == ["one", "two"]
    assert data["data"]["reused"] == false
    assert is_binary(data["data"]["head"])

    {again, 0} = cli(["co", "a@main", "--json"])
    assert Jason.decode!(again)["data"]["reused"] == true
  end

  test "co configures a new topic branch to push to its same-named remote branch" do
    {output, 0} = cli(["co", "a@main", "--topic", "tracked", "--json"])
    member = Jason.decode!(output)["data"]["members"] |> hd()

    path = member["path"]
    branch = member["branch"]
    assert branch == "feature/tracked"

    assert Git.run!(["config", "--get", "branch.#{branch}.remote"], cd: path) |> String.trim() ==
             "origin"

    assert Git.run!(["config", "--get", "branch.#{branch}.merge"], cd: path) |> String.trim() ==
             "refs/heads/#{branch}"

    assert {:ok, _} = Git.run(["-c", "push.default=simple", "push"], cd: path)

    status = Git.Status.read!(path)
    assert status.upstream == "origin/feature/tracked"
    assert status.ahead == 0
  end

  test "workspace new dry-run writes nothing, then creates and reports status" do
    dry_args = [
      "workspace",
      "new",
      "MT-4711",
      "--own",
      "a",
      "--own",
      "b",
      "--label",
      "jira",
      "--description",
      "update dependencies",
      "--dry-run",
      "--json"
    ]

    {output, 0} = cli(dry_args)
    data = Jason.decode!(output)["data"]

    assert data["dry_run"] == true
    assert data["created"] == true
    assert data["workspace"] == "a@MT-4711"
    assert data["labels"] == ["jira"]
    assert Enum.map(data["members"], & &1["action"]) == ["create", "create"]
    refute File.exists?(data["marker_path"])
    refute File.exists?(data["path"])

    {created, 0} = cli(List.delete(dry_args, "--dry-run"))
    created_data = Jason.decode!(created)["data"]

    assert created_data["created"] == true
    assert created_data["dry_run"] == false
    assert File.exists?(created_data["marker_path"])
    assert Enum.all?(created_data["members"], &(&1["action"] == "created"))

    {status, 0} = cli(["workspace", "status", "MT-4711", "--json"])
    workspace = Jason.decode!(status)["data"]["workspace"]
    assert workspace["name"] == "a@MT-4711"
    assert length(workspace["members"]) == 2
  end

  test "CREATE-8 --json does not prompt for an occupied branch and exits 4" do
    {_output, 0} = cli(["co", "a@main"])

    {output, 4} = cli(["workspace", "new", "occupied", "--own", "a@main", "--as-is", "--json"])
    error = Jason.decode!(output)["error"]

    assert error["code"] == "branch_occupied"
    assert error["details"]["branch"] == "main"
    assert error["hint"] =~ "--detach"
    refute File.exists?(Path.join([data_root(), "work", "a", "occupied"]))
  end

  test "CREATE-11 partial creation exits 7 and a re-run completes" do
    {output, 7} =
      cli([
        "workspace",
        "new",
        "partial",
        "--own",
        "a",
        "--own",
        "b@missing-ref",
        "--json"
      ])

    error = Jason.decode!(output)["error"]
    assert error["code"] == "partial"
    assert error["details"]["workspace"] == "a@partial"
    assert [member] = error["details"]["members"]
    assert member["repo"] == "a"
    assert [failure] = error["details"]["failures"]
    assert failure["repo"] == "b"
    assert failure["code"] == "not_found"

    marker = Marker.read!(error["details"]["path"])
    assert Enum.map(marker["members"], & &1["repo"]) == ["a"]

    {completed, 0} =
      cli(["workspace", "new", "partial", "--own", "a", "--own", "b", "--json"])

    data = Jason.decode!(completed)["data"]
    actions = Map.new(data["members"], &{&1["repo"], &1["action"]})
    assert actions["a"] == "kept"
    assert actions["b"] == "created"
  end

  test "CREATE-9 duplicate members and --branch with --borrow exit 2" do
    {output, 2} = cli(["workspace", "new", "dup", "--own", "a", "--own", "a", "--json"])
    assert Jason.decode!(output)["error"]["code"] == "usage"

    {output, 2} =
      cli(["workspace", "new", "borrow-branch", "--borrow", "a", "--branch", "x", "--json"])

    assert Jason.decode!(output)["error"]["code"] == "usage"
  end

  test "CREATE-10 a path conflict exits 4 and leaves the path untouched" do
    path = Path.join([data_root(), "work", "a", "conflict", "a"])
    File.mkdir_p!(path)
    File.write!(Path.join(path, "keep.txt"), "do not overwrite")

    {output, 4} = cli(["workspace", "new", "conflict", "--own", "a", "--json"])
    error = Jason.decode!(output)["error"]

    assert error["code"] == "conflict"
    assert File.read!(Path.join(path, "keep.txt")) == "do not overwrite"
  end

  test "co requires a ref and rejects --branch with --detach" do
    {output, 2} = cli(["co", "a", "--json"])
    assert Jason.decode!(output)["error"]["code"] == "usage"

    {output, 2} = cli(["co", "a@main", "--branch", "x", "--detach", "--json"])
    assert Jason.decode!(output)["error"]["code"] == "usage"
  end

  test "co reports an unknown repository as not_found" do
    {output, 3} = cli(["co", "nope@main", "--json"])
    assert Jason.decode!(output)["error"]["code"] == "not_found"
  end

  test "CREATE-14 --fetch updates a warm mirror for a missing ref", %{source_a: source_a} do
    Git.run!(["branch", "later"], cd: source_a)

    {output, 3} = cli(["co", "a@later", "--json"])
    assert Jason.decode!(output)["error"]["code"] == "not_found"
    assert Jason.decode!(output)["error"]["hint"] =~ "fetch"

    {created, 0} = cli(["co", "a@later", "--fetch", "--json"])
    data = Jason.decode!(created)["data"]
    assert data["work"] == "a@later"
    assert data["branch"] == "later"
  end

  test "borrowed members keep their existing checkout" do
    {_output, 0} = cli(["co", "a@main"])

    {output, 0} = cli(["workspace", "new", "borrow", "--borrow", "a@main", "--json"])
    data = Jason.decode!(output)["data"]

    assert [member] = data["members"]
    assert member["ownership"] == "borrowed"
    assert member["path"] == Path.join([data_root(), "work", "a", "main", "a"])
    assert member["branch"] == "main"
  end

  test "co --as and workspace --as choose top-level member names" do
    {co, 0} = cli(["co", "a@main", "--as", "checkout", "--json"])
    co_data = Jason.decode!(co)["data"]
    assert co_data["name"] == "checkout"

    assert hd(co_data["members"])["path"] ==
             Path.join([data_root(), "work", "a", "main", "checkout"])

    {created, 0} =
      cli([
        "workspace",
        "new",
        "aliased",
        "--own",
        "b",
        "--as",
        "b=acme",
        "--json"
      ])

    data = Jason.decode!(created)["data"]
    assert [member] = data["members"]
    assert member["name"] == "acme"
    assert member["path"] == Path.join([data_root(), "work", "b", "aliased", "acme"])

    {path_output, 0} = cli(["path", "b@aliased:acme", "--json"])
    assert Jason.decode!(path_output)["data"]["path"] == member["path"]

    {output, 2} =
      cli(["workspace", "new", "bad-as", "--own", "a", "--as", "nope=acme", "--json"])

    assert Jason.decode!(output)["error"]["code"] == "usage"
  end

  test "co --topic names the workspace and derives the owned branch" do
    {output, 0} =
      cli(["co", "a@main", "--topic", "JENKINS-42", "--json"])

    data = Jason.decode!(output)["data"]
    assert data["work"] == "a@JENKINS-42"
    assert data["ref"] == "main"
    assert data["branch"] == "feature/JENKINS-42"
    assert hd(data["members"])["path"] == Path.join([data_root(), "work", "a", "JENKINS-42", "a"])

    {again, 0} =
      cli(["co", "a@main", "--topic", "JENKINS-42", "--json"])

    assert Jason.decode!(again)["data"]["reused"] == true

    {conflict, 2} =
      cli(["co", "a@main", "--topic", "JENKINS-42", "--only", "a", "--exclude", "a", "--json"])

    assert Jason.decode!(conflict)["error"]["code"] == "usage"
  end

  test "workspace add only extends an existing workspace" do
    {output, 3} = cli(["workspace", "add", "a@alias", "--own", "a", "--json"])
    error = Jason.decode!(output)["error"]
    assert error["code"] == "not_found"
    assert error["hint"] =~ "workspace new"

    {_, 0} = cli(["workspace", "new", "a@alias", "--own", "a", "--json"])

    {output, 0} = cli(["workspace", "add", "a@alias", "--own", "b", "--json"])
    data = Jason.decode!(output)["data"]

    assert data["workspace"] == "a@alias"
    assert Enum.sort(Enum.map(data["members"], & &1["name"])) == ["a", "b"]
    assert Enum.all?(data["members"], &(&1["branch"] == "feature/alias"))

    {output, 2} = cli(["workspace", "add", "a@alias", "--json"])
    assert Jason.decode!(output)["error"]["code"] == "usage"
  end

  test "workspace new project@topic needs no --project or --branch" do
    {output, 0} =
      cli(["workspace", "new", "a@4711", "--own", "a@main", "--json"])

    data = Jason.decode!(output)["data"]
    assert data["workspace"] == "a@4711"
    assert data["project"] == "a"
    assert data["topic"] == "4711"

    assert [member] = data["members"]
    assert member["branch"] == "feature/4711"
    assert member["ref"] == "main"
    assert member["path"] == Path.join([data_root(), "work", "a", "4711", "a"])
  end

  test "a slashed topic needs no project flag when the project is inferred" do
    {output, 0} =
      cli(["workspace", "new", "4711/sub", "--own", "a@main", "--json"])

    data = Jason.decode!(output)["data"]
    assert data["workspace"] == "a@4711/sub"
    assert data["topic"] == "4711/sub"

    assert [member] = data["members"]
    assert member["branch"] == "feature/4711/sub"
    assert member["path"] == Path.join([data_root(), "work", "a", "4711-sub", "a"])
  end

  test "workspace new --as-is checks the ref out unchanged" do
    {output, 0} =
      cli(["workspace", "new", "a@plain", "--own", "a@main", "--as-is", "--json"])

    assert [member] = Jason.decode!(output)["data"]["members"]
    assert member["branch"] == "main"

    {output, 2} =
      cli([
        "workspace",
        "new",
        "a@plain2",
        "--own",
        "a@main",
        "--as-is",
        "--branch",
        "x",
        "--json"
      ])

    assert Jason.decode!(output)["error"]["code"] == "usage"
  end

  test "workspace new rejects --project and reserved '@'" do
    {output, 2} =
      cli(["workspace", "new", "a@4711", "--project", "a", "--own", "a", "--json"])

    assert Jason.decode!(output)["error"]["code"] == "usage"

    {output, 2} =
      cli(["workspace", "new", "a@b@c", "--own", "a", "--json"])

    assert Jason.decode!(output)["error"]["code"] == "usage"

    {output, 2} = cli(["project", "new", "a@b", "--json"])
    assert Jason.decode!(output)["error"]["code"] == "usage"
  end

  test "bare topic lookup is a suffix match, not a LIKE pattern" do
    {_output, 0} = cli(["co", "a@main", "--topic", "feature_x", "--json"])

    {output, 0} = cli(["workspace", "status", "feature_x", "--json"])
    assert Jason.decode!(output)["data"]["workspace"]["name"] == "a@feature_x"

    {output, 3} = cli(["workspace", "status", "featureX", "--json"])
    assert Jason.decode!(output)["error"]["code"] == "not_found"
  end

  test "co --new-branch is gone" do
    {output, 2} =
      cli(["co", "a@main", "--topic", "x", "--new-branch", "--json"])

    assert Jason.decode!(output)["error"]["code"] == "usage"
  end

  test "label add/rm/set/ls updates the marker and the index", %{config: config} do
    {_, 0} = cli(["co", "a@main", "--label", "one", "--json"])
    dir = Path.join([config.projects_root, "a", "main"])

    {output, 0} = cli(["workspace", "label", "add", "a@main", "two", "three", "--json"])
    assert Jason.decode!(output)["data"]["labels"] == ["one", "two", "three"]

    marker = Marker.read!(dir)
    assert marker["labels"] == ["one", "two", "three"]

    {output, 0} = cli(["workspace", "label", "rm", "a@main", "two", "--json"])
    assert Jason.decode!(output)["data"]["labels"] == ["one", "three"]

    {output, 0} = cli(["workspace", "label", "set", "a@main", "solo", "--json"])
    assert Jason.decode!(output)["data"]["labels"] == ["solo"]

    {output, 0} = cli(["workspace", "label", "set", "a@main", "--json"])
    assert Jason.decode!(output)["data"]["labels"] == []

    {output, 0} = cli(["workspace", "label", "ls", "a@main", "--json"])
    assert Jason.decode!(output)["data"]["labels"] == []
    assert Marker.read!(dir)["labels"] == []

    {output, 2} = cli(["workspace", "label", "add", "a@main", " ", "--json"])
    assert Jason.decode!(output)["error"]["code"] == "usage"
  end

  test "workspace edit changes and clears the description", %{config: config} do
    {_, 0} = cli(["co", "a@main", "--label", "keep", "--json"])
    dir = Path.join([config.projects_root, "a", "main"])

    {output, 0} = cli(["workspace", "edit", "a@main", "--description", "changed", "--json"])
    data = Jason.decode!(output)["data"]
    assert data["description"] == "changed"
    assert data["labels"] == ["keep"]
    assert Marker.read!(dir)["description"] == "changed"
    assert Marker.read!(dir)["labels"] == ["keep"]

    {output, 0} =
      cli(["workspace", "edit", "a@main", "--clear-description", "--json"])

    data = Jason.decode!(output)["data"]
    assert data["description"] == nil
    assert Marker.read!(dir)["description"] == nil
    assert Marker.read!(dir)["labels"] == ["keep"]

    {output, 2} =
      cli(["workspace", "edit", "a@main", "--description", "x", "--clear-description", "--json"])

    assert Jason.decode!(output)["error"]["code"] == "usage"
  end

  test "WS-1/2 workspace status reports three members and member addressing resolves", %{
    config: config
  } do
    source_c = Fixtures.source_repo!()
    {:ok, _repo_c} = Repos.add(config, Fixtures.repo_url(source_c), name: "c")

    {_output, 0} = cli(["co", "c@main"])

    {_output, 0} =
      cli([
        "workspace",
        "new",
        "three",
        "--own",
        "a",
        "--own",
        "b",
        "--borrow",
        "c@main"
      ])

    {output, 0} = cli(["workspace", "status", "three", "--json"])
    workspace = Jason.decode!(output)["data"]["workspace"]

    assert length(workspace["members"]) == 3
    assert workspace["owned"] == 2
    assert workspace["borrowed"] == 1

    Enum.each(workspace["members"], fn member ->
      assert is_binary(member["path"])
      assert is_binary(member["state"])
      assert Map.has_key?(member, "branch")
      assert Map.has_key?(member, "dirty")
      assert Map.has_key?(member, "ahead")
      assert Map.has_key?(member, "behind")
      assert Map.has_key?(member, "unpushed")
    end)

    {path_output, 0} = cli(["path", "three:c", "--json"])

    assert Jason.decode!(path_output)["data"]["path"] ==
             Path.join([data_root(), "work", "c", "main", "c"])
  end

  test "workspace ls reports active workspaces as JSON" do
    {_output, 0} = cli(["workspace", "new", "listed", "--own", "a", "--label", "x"])
    {output, 0} = cli(["workspace", "ls", "--json"])

    assert [workspace] = Jason.decode!(output)["data"]["workspaces"]
    assert workspace["name"] == "a@listed"
    assert workspace["labels"] == ["x"]
    assert workspace["members"] == 1

    {filtered, 0} = cli(["workspace", "ls", "--label", "nope", "--json"])
    assert Jason.decode!(filtered)["data"]["workspaces"] == []
  end

  test "help covers co and workspace" do
    {top, 0} = cli(["--help"])
    assert top =~ "checkout <project>[@<ref>]"
    assert top =~ "workspace new|add|label|ls|edit|rm"

    {co, 0} = cli(["co", "--help"])
    assert co =~ "gitspace checkout <project>[@<ref>]"
    assert co =~ "--as-is"
    assert co =~ "MT4711"

    {workspace, 0} = cli(["workspace", "--help"])
    assert workspace =~ "gitspace workspace new [<project>@]<topic>"
    assert workspace =~ "gitspace workspace add <workspace>"
    assert workspace =~ "gitspace workspace label add|rm|set|ls"
    assert workspace =~ "BORROWED MEMBERS"
  end

  defp cli(args) do
    {code, output} = ExUnit.CaptureIO.with_io(fn -> Gitspace.CLI.run(args) end)
    {output, code}
  end

  defp data_root do
    config = Gitspace.Config.load!()
    Path.dirname(config.data_dir)
  end
end
