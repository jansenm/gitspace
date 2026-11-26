defmodule Gitspace.CLI.WorkspaceRmTest do
  use Gitspace.IndexCase, async: false

  alias Gitspace.{Config, Fixtures, Git, Projects, Repos, Workspaces}

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

    for name <- ["a", "b"] do
      source = Fixtures.source_repo!()
      {:ok, _} = Repos.add(config, Fixtures.repo_url(source), name: name)
    end

    {_, 0} = cli(["project", "new", "vemags", "--repo", "a", "--repo", "b"])
    {_, 0} = cli(["co", "vemags@main", "--topic", "dev", "--json"])

    {:ok, config: config}
  end

  test "reports the branches that remain after removal", %{config: config} do
    {dry, 0} = cli(["workspace", "rm", "vemags@dev", "--dry-run", "--json"])
    planned = Jason.decode!(dry)["data"]

    assert Enum.sort_by(planned["branches"], & &1["repo"]) == [
             %{"repo" => "a", "name" => "feature/dev"},
             %{"repo" => "b", "name" => "feature/dev"}
           ]

    {output, 0} = cli(["workspace", "rm", "vemags@dev", "--yes"])
    assert output =~ "branches kept"
    assert output =~ "a:feature/dev"
    assert output =~ "b:feature/dev"

    for name <- ["a", "b"] do
      assert {:ok, repo} = Repos.get(config, name)

      assert Git.run!(["rev-parse", "--verify", "refs/heads/feature/dev"], cd: repo.bare_path)
             |> String.trim() != ""
    end
  end

  test "dry-run reports the plan without changing anything", %{config: config} do
    {output, 0} = cli(["workspace", "rm", "vemags@dev", "--dry-run", "--json"])
    data = Jason.decode!(output)["data"]

    assert data["dry_run"]
    assert Enum.map(data["removed"], & &1["action"]) == ["would remove", "would remove"]
    assert Enum.sort(Enum.map(data["removed"], & &1["name"])) == ["a", "b"]
    assert File.dir?(Path.join([config.projects_root, "vemags", "dev", "a"]))
    assert {:ok, _} = Workspaces.get(config, "vemags@dev")
  end

  test "removes one member and keeps the workspace", %{config: config} do
    {output, 0} = cli(["workspace", "rm", "vemags@dev:a", "--yes", "--json"])
    data = Jason.decode!(output)["data"]

    assert [member] = data["removed"]
    assert member["name"] == "a"
    refute File.exists?(Path.join([config.projects_root, "vemags", "dev", "a"]))
    assert File.dir?(Path.join([config.projects_root, "vemags", "dev", "b"]))

    assert {:ok, workspace} = Workspaces.get(config, "vemags@dev")
    assert Enum.map(workspace.members, & &1.name) == ["b"]

    marker = Gitspace.Marker.read!(Path.join([config.projects_root, "vemags", "dev"]))
    assert Enum.map(marker["members"], & &1["name"]) == ["b"]
  end

  test "removing the last member tombstones the workspace", %{config: config} do
    {_, 0} = cli(["workspace", "rm", "vemags@dev:a", "--yes"])
    {output, 0} = cli(["workspace", "rm", "vemags@dev:b", "--yes", "--json"])
    data = Jason.decode!(output)["data"]

    assert data["tombstoned"]
    assert data["directory_removed"]
    refute File.exists?(Path.join([config.projects_root, "vemags", "dev"]))
    assert {:error, _} = Workspaces.get(config, "vemags@dev")
    assert Workspaces.list(config) == []

    assert Enum.any?(Projects.list(config), &(&1.name == "vemags"))

    assert {:error, _} =
             Projects.get(config, "vemags") |> then(fn _ -> {:error, :still_there} end)
  end

  test "removes a whole workspace but keeps the project", %{config: config} do
    dir = Path.join([config.projects_root, "vemags", "dev"])
    {output, 0} = cli(["workspace", "rm", "vemags@dev", "--yes", "--json"])
    data = Jason.decode!(output)["data"]

    assert data["tombstoned"]
    refute File.exists?(dir)
    assert {:ok, _} = Projects.get(config, "vemags")
    assert Workspaces.list(config) == []
  end

  test "borrowed members are unlinked, not deleted", %{config: config} do
    {_, 0} = cli(["co", "a@main", "--topic", "holder", "--as-is", "--json"])

    {_, 0} =
      cli([
        "workspace",
        "new",
        "vemags@borrow",
        "--own",
        "b",
        "--borrow",
        "a@main",
        "--json"
      ])

    borrowed_path = Path.join([config.projects_root, "a", "holder", "a"])

    {output, 0} = cli(["workspace", "rm", "vemags@borrow:a", "--yes", "--json"])
    data = Jason.decode!(output)["data"]

    assert [member] = data["removed"]
    assert member["action"] == "unlinked"
    assert data["branches"] == []
    assert File.dir?(borrowed_path)
    assert {:ok, workspace} = Workspaces.get(config, "vemags@borrow")
    assert Enum.map(workspace.members, & &1.name) == ["b"]
  end

  test "refuses risky members, then archives and removes with --force", %{config: config} do
    dirty = Path.join([config.projects_root, "vemags", "dev", "a", "notes.txt"])
    File.write!(dirty, "important\n")

    {output, 5} = cli(["workspace", "rm", "vemags@dev", "--yes", "--json"])
    error = Jason.decode!(output)["error"]
    assert error["code"] == "refused"
    assert error["hint"] =~ "--force"
    assert File.exists?(dirty)

    {output, 0} = cli(["workspace", "rm", "vemags@dev", "--force", "--yes", "--json"])
    data = Jason.decode!(output)["data"]

    assert data["tombstoned"]
    refute File.exists?(dirty)
    assert File.dir?(Path.join(config.data_dir, "trash"))

    trash_files =
      Path.wildcard(Path.join([config.data_dir, "trash", "**", "*"]), match_dot: true)
      |> Enum.map(&Path.basename/1)

    assert "info.json" in trash_files
    assert "untracked.tar.gz" in trash_files
  end

  test "requires confirmation in non-interactive mode" do
    {output, 6} = cli(["workspace", "rm", "vemags@dev", "--json"])
    assert Jason.decode!(output)["error"]["code"] == "confirmation_required"
  end

  test "unknown members are exit 3" do
    {output, 3} = cli(["workspace", "rm", "vemags@dev:nope", "--yes", "--json"])
    assert Jason.decode!(output)["error"]["code"] == "not_found"
  end

  defp cli(args) do
    {code, output} = ExUnit.CaptureIO.with_io(fn -> Gitspace.CLI.run(args) end)
    {output, code}
  end
end
