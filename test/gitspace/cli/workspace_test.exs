defmodule Gitspace.CLI.WorkspaceTest do
  use Gitspace.IndexCase, async: false

  alias Gitspace.{Config, Fixtures, Git, Marker, Repos}

  setup %{config: config} do
    :ok = Config.save(config)

    previous = System.get_env("GITSPACE_CONFIG")
    System.put_env("GITSPACE_CONFIG", config.path)
    System.delete_env("GITSPACE_DATA")
    System.delete_env("GITSPACE_CHECKOUTS")

    on_exit(fn ->
      if previous do
        System.put_env("GITSPACE_CONFIG", previous)
      else
        System.delete_env("GITSPACE_CONFIG")
      end

      System.delete_env("GITSPACE_DATA")
      System.delete_env("GITSPACE_CHECKOUTS")
    end)

    source_a = Fixtures.source_repo!(branches: ["hotfix/timeout"], tags: ["v1.0.0"])
    source_b = Fixtures.source_repo!()

    {:ok, _repo_a} = Repos.add(config, source_a, name: "a")
    {:ok, _repo_b} = Repos.add(config, source_b, name: "b")

    {:ok, config: config, source_a: source_a}
  end

  test "CREATE-15 co --json returns work, path, ref, head and labels" do
    {output, 0} = cli(["co", "a@main", "--label", "one", "--label", "two", "--json"])
    data = Jason.decode!(output)

    assert data["ok"]
    assert data["schema_version"] == 1
    assert data["data"]["work"] == "main"
    assert data["data"]["path"] == Path.join([data_root(), "work", "main", "a"])
    assert data["data"]["ref"] == "main"
    assert data["data"]["branch"] == "main"
    assert data["data"]["labels"] == ["one", "two"]
    assert data["data"]["reused"] == false
    assert is_binary(data["data"]["head"])

    {again, 0} = cli(["co", "a@main", "--json"])
    assert Jason.decode!(again)["data"]["reused"] == true
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
    assert data["workspace"] == "MT-4711"
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
    assert workspace["name"] == "MT-4711"
    assert length(workspace["members"]) == 2
  end

  test "CREATE-8 --json does not prompt for an occupied branch and exits 4" do
    {_output, 0} = cli(["co", "a@main"])

    {output, 4} = cli(["workspace", "new", "occupied", "--own", "a@main", "--json"])
    error = Jason.decode!(output)["error"]

    assert error["code"] == "branch_occupied"
    assert error["details"]["branch"] == "main"
    assert error["hint"] =~ "--detach"
    refute File.exists?(Path.join([data_root(), "work", "occupied"]))
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
    assert error["details"]["workspace"] == "partial"
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
    assert actions["a"] == "reused"
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
    path = Path.join([data_root(), "work", "conflict", "a"])
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
    assert data["work"] == "later"
    assert data["branch"] == "later"
  end

  test "borrowed members keep their existing checkout" do
    {_output, 0} = cli(["co", "a@main"])

    {output, 0} = cli(["workspace", "new", "borrow", "--borrow", "a@main", "--json"])
    data = Jason.decode!(output)["data"]

    assert [member] = data["members"]
    assert member["ownership"] == "borrowed"
    assert member["path"] == Path.join([data_root(), "work", "main", "a"])
    assert member["branch"] == "main"
  end

  test "co --as and workspace --as choose top-level member names" do
    {co, 0} = cli(["co", "a@main", "--as", "checkout", "--json"])
    co_data = Jason.decode!(co)["data"]
    assert co_data["name"] == "checkout"
    assert co_data["path"] == Path.join([data_root(), "work", "main", "checkout"])

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
    assert member["path"] == Path.join([data_root(), "work", "aliased", "acme"])

    {path_output, 0} = cli(["path", "aliased:acme", "--json"])
    assert Jason.decode!(path_output)["data"]["path"] == member["path"]

    {output, 2} =
      cli(["workspace", "new", "bad-as", "--own", "a", "--as", "nope=acme", "--json"])

    assert Jason.decode!(output)["error"]["code"] == "usage"
  end

  test "WS-1/2 workspace status reports three members and member addressing resolves", %{
    config: config
  } do
    source_c = Fixtures.source_repo!()
    {:ok, _repo_c} = Repos.add(config, source_c, name: "c")

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
             Path.join([data_root(), "work", "main", "c"])
  end

  test "workspace ls reports active workspaces as JSON" do
    {_output, 0} = cli(["workspace", "new", "listed", "--own", "a", "--label", "x"])
    {output, 0} = cli(["workspace", "ls", "--json"])

    assert [workspace] = Jason.decode!(output)["data"]["workspaces"]
    assert workspace["name"] == "listed"
    assert workspace["labels"] == ["x"]
    assert workspace["members"] == 1

    {filtered, 0} = cli(["workspace", "ls", "--label", "nope", "--json"])
    assert Jason.decode!(filtered)["data"]["workspaces"] == []
  end

  test "help covers co and workspace" do
    {top, 0} = cli(["--help"])
    assert top =~ "co <repo>@<ref>"
    assert top =~ "workspace new|ls|status"

    {co, 0} = cli(["co", "--help"])
    assert co =~ "gitspace co <repo>@<ref>"

    {workspace, 0} = cli(["workspace", "--help"])
    assert workspace =~ "gitspace workspace new <name>"
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
