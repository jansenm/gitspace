defmodule Gitspace.CLI.ProjectTest do
  use Gitspace.IndexCase, async: false

  alias Gitspace.{Config, Fixtures, Projects, Repos}

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

    for name <- ["a", "b", "c", "vemags"] do
      source = Fixtures.source_repo!()
      {:ok, _} = Repos.add(config, Fixtures.repo_url(source), name: name)
    end

    {:ok, config: config}
  end

  test "project new, ls and show define a named set of repositories", %{config: config} do
    {created, 0} =
      cli([
        "project",
        "new",
        "vemags-project",
        "--repo",
        "a",
        "--repo",
        "b",
        "--description",
        "VEMAGS services",
        "--json"
      ])

    project = Jason.decode!(created)["data"]
    assert project["name"] == "vemags-project"
    assert project["path"] == Path.join([config.projects_root, "vemags-project"])
    assert Enum.map(project["members"], & &1["slug"]) == ["a", "b"]
    assert File.dir?(project["path"])
    assert File.exists?(Path.join(project["path"], ".gitspace-project.json"))

    {listed, 0} = cli(["project", "ls", "--json"])
    assert [project] = Jason.decode!(listed)["data"]["projects"]
    assert project["members"] == 2

    {shown, 0} = cli(["project", "show", "vemags-project", "--json"])
    assert Jason.decode!(shown)["data"]["description"] == "VEMAGS services"

    {_removed, 0} = cli(["project", "remove", "vemags-project", "b", "--json"])
    {shown, 0} = cli(["project", "show", "vemags-project", "--json"])
    assert Enum.map(Jason.decode!(shown)["data"]["members"], & &1["slug"]) == ["a"]

    {_added, 0} = cli(["project", "add", "vemags-project", "b", "--json"])
    {shown, 0} = cli(["project", "show", "vemags-project", "--json"])
    assert length(Jason.decode!(shown)["data"]["members"]) == 2
  end

  test "co checks out a project topic and --only narrows it", %{config: config} do
    {_project, 0} =
      cli(["project", "new", "vemags", "--repo", "a", "--repo", "b", "--json"])

    {created, 0} =
      cli(["co", "vemags", "--topic", "MT4711", "--json"])

    data = Jason.decode!(created)["data"]
    assert data["workspace"] == "vemags@MT4711"
    assert data["path"] == Path.join([config.projects_root, "vemags", "MT4711"])
    assert Enum.map(data["members"], & &1["repo"]) |> Enum.sort() == ["a", "b"]
    assert Enum.all?(data["members"], &(&1["branch"] == "feature/MT4711"))
    assert Enum.all?(data["members"], &File.dir?(&1["path"]))

    {path_output, 0} = cli(["path", "vemags@MT4711", "--json"])
    assert Jason.decode!(path_output)["data"]["path"] == data["path"]

    {again, 0} =
      cli(["co", "vemags", "--topic", "MT4711", "--only", "a", "--json"])

    again_data = Jason.decode!(again)["data"]
    actions = Map.new(again_data["members"], &{&1["repo"], &1["action"]})
    assert actions["a"] == "kept"
    assert actions["b"] == "kept"
  end

  test "adding a project member does not disturb existing checkouts" do
    {_project, 0} =
      cli(["project", "new", "vemags", "--repo", "a", "--json"])

    {_first, 0} =
      cli(["co", "vemags", "--topic", "MT4711", "--json"])

    {_added, 0} = cli(["project", "add", "vemags", "b", "--json"])

    {output, 0} =
      cli(["co", "vemags", "--topic", "MT4711", "--json"])

    actions = Map.new(Jason.decode!(output)["data"]["members"], &{&1["repo"], &1["action"]})
    assert actions["a"] == "kept"
    assert actions["b"] == "created"

    {_added, 0} = cli(["project", "add", "vemags", "c", "--json"])

    # Existing members are ignored even when the requested branch mode differs.
    {output, 0} = cli(["co", "vemags", "--topic", "MT4711", "--json"])
    members = Jason.decode!(output)["data"]["members"]
    actions = Map.new(members, &{&1["repo"], &1["action"]})
    assert actions["a"] == "kept"
    assert actions["b"] == "kept"
    assert actions["c"] == "created"

    c = Enum.find(members, &(&1["repo"] == "c"))
    assert c["branch"] == "feature/MT4711"
  end

  test "co supports --exclude and rejects --only with --exclude" do
    {_project, 0} =
      cli(["project", "new", "vemags", "--repo", "a", "--repo", "b", "--json"])

    {created, 0} =
      cli(["co", "vemags", "--topic", "partial", "--exclude", "b", "--json"])

    assert [member] = Jason.decode!(created)["data"]["members"]
    assert member["repo"] == "a"

    {output, 2} =
      cli([
        "co",
        "vemags",
        "--topic",
        "nope",
        "--only",
        "a",
        "--exclude",
        "b",
        "--json"
      ])

    assert Jason.decode!(output)["error"]["code"] == "usage"
  end

  test "a project and a repository may share a name" do
    {output, 0} =
      cli(["project", "new", "vemags", "--repo", "vemags", "--json"])

    project = Jason.decode!(output)["data"]
    assert project["name"] == "vemags"
    assert [member] = project["members"]
    assert member["slug"] == "vemags"

    {co, 0} = cli(["co", "vemags@main", "--topic", "dev", "--json"])
    data = Jason.decode!(co)["data"]
    assert data["workspace"] == "vemags@dev"
    assert [member] = data["members"]
    assert member["repo"] == "vemags"
  end

  test "project new --at uses the exact project directory" do
    parent = Fixtures.tmp_dir!("customer")
    path = Path.join(parent, "acme")

    {created, 0} =
      cli(["project", "new", "acme", "--at", path, "--json"])

    assert Jason.decode!(created)["data"]["path"] == path
    assert File.exists?(Path.join(path, ".gitspace-project.json"))

    {bad, 2} = cli(["project", "new", "other", "--at", parent, "--json"])
    assert Jason.decode!(bad)["error"]["code"] == "usage"

    {list, 0} = cli(["project", "ls"])
    assert list =~ path
  end

  test "repo add --project links the repository" do
    source = Fixtures.source_repo!()

    {output, 0} =
      cli([
        "repo",
        "add",
        Fixtures.repo_url(source),
        "--name",
        "new-repo",
        "--project",
        "grouped",
        "--no-fetch",
        "--json"
      ])

    assert Jason.decode!(output)["data"]["project"] == "grouped"

    {shown, 0} = cli(["project", "show", "grouped", "--json"])
    assert Enum.map(Jason.decode!(shown)["data"]["members"], & &1["slug"]) == ["new-repo"]

    {list, 0} = cli(["repo", "ls"])
    assert list =~ "PROJECT"
    assert list =~ "grouped"

    {remove, 5} = cli(["repo", "rm", "new-repo", "--force", "--yes", "--json"])
    assert Jason.decode!(remove)["error"]["code"] == "refused"
  end

  test "project edit changes and clears the description", %{config: config} do
    {_, 0} = cli(["project", "new", "vemags", "--description", "initial", "--json"])

    {output, 0} = cli(["project", "edit", "vemags", "--description", "changed", "--json"])
    data = Jason.decode!(output)["data"]
    assert data["description"] == "changed"

    {shown, 0} = cli(["project", "show", "vemags", "--json"])
    assert Jason.decode!(shown)["data"]["description"] == "changed"

    {output, 0} = cli(["project", "edit", "vemags", "--clear-description", "--json"])
    assert Jason.decode!(output)["data"]["description"] == nil

    assert {:ok, project} = Projects.get(config, "vemags")
    assert is_nil(project.description)

    {output, 2} =
      cli(["project", "edit", "vemags", "--description", "x", "--clear-description", "--json"])

    assert Jason.decode!(output)["error"]["code"] == "usage"
  end

  test "project rm refuses while workspaces exist" do
    {_project, 0} =
      cli(["project", "new", "vemags", "--repo", "a", "--json"])

    {_co, 0} = cli(["co", "vemags@main", "--topic", "dev", "--json"])

    {output, 5} = cli(["project", "rm", "vemags", "--json"])
    error = Jason.decode!(output)["error"]
    assert error["code"] == "refused"
    assert error["hint"] =~ "vemags@dev"

    {forced, 0} = cli(["project", "rm", "vemags", "--force", "--json"])
    assert Jason.decode!(forced)["data"]["workspaces_kept"] == 1
    assert File.dir?(Path.join([Config.load!().projects_root, "vemags", "dev", "a"]))
  end

  defp cli(args) do
    {code, output} = ExUnit.CaptureIO.with_io(fn -> Gitspace.CLI.run(args) end)
    {output, code}
  end
end
