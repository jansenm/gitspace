defmodule Gitspace.CLI.ConfigBundleTest do
  use Gitspace.IndexCase, async: false

  alias Gitspace.{Config, Fixtures, Layout, Projects, Repos}

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

    source = Fixtures.source_repo!()
    {:ok, _} = Repos.add(config, Fixtures.repo_url(source), name: "demo")
    {:ok, _} = Projects.create(config, "demo", repo: ["demo"])

    {:ok, config: config, source: source}
  end

  test "config export prints a bundle", %{} do
    {output, 0} = cli(["config", "export"])
    bundle = Jason.decode!(output)

    assert bundle["app"] == "gitspace"
    assert bundle["schema_version"] == 1
    assert Enum.map(bundle["repos"], & &1["alias"]) == ["demo"]
    assert Enum.map(bundle["projects"], & &1["name"]) == ["demo"]
  end

  test "config export rejects --json", %{} do
    {output, 2} = cli(["config", "export", "--json"])

    assert Jason.decode!(output)["error"]["code"] == "usage"
  end

  test "config import plans, creates and is idempotent", %{config: config} do
    other = Fixtures.source_repo!()
    url = Fixtures.repo_url(other)
    key = Layout.normalize_remote(url)

    bundle = %{
      "app" => "gitspace",
      "schema_version" => 1,
      "repos" => [
        %{
          "alias" => "imported",
          "origin_kind" => "remote",
          "remote_url" => url,
          "remote_key" => key,
          "default_branch" => "main"
        }
      ],
      "projects" => [
        %{"name" => "imported-project", "members" => ["imported"]}
      ]
    }

    path = Path.join(config.data_dir, "bundle.json")
    File.write!(path, Jason.encode!(bundle))

    {plan, 0} = cli(["config", "import", path, "--dry-run", "--json"])
    plan_data = Jason.decode!(plan)["data"]
    assert plan_data["dry_run"]
    assert {:error, _} = Repos.get(config, "imported")
    assert {:error, _} = Projects.get(config, "imported-project")

    {refused, 6} = cli(["config", "import", path, "--json"])
    assert Jason.decode!(refused)["error"]["code"] == "confirmation_required"

    {output, 0} = cli(["config", "import", path, "--yes", "--no-fetch", "--json"])
    data = Jason.decode!(output)["data"]
    assert [%{"alias" => "imported", "action" => "create"}] = data["repos"]
    assert [%{"name" => "imported-project", "action" => "create"}] = data["projects"]

    assert {:ok, repo} = Repos.get(config, "imported")
    assert repo.remote_key == key

    assert {:ok, project} = Projects.get(config, "imported-project")
    assert project.members == [key]

    {again, 0} = cli(["config", "import", path, "--yes", "--no-fetch", "--json"])
    again_data = Jason.decode!(again)["data"]
    assert [%{"action" => "exists"}] = again_data["repos"]
    assert [%{"action" => "exists"}] = again_data["projects"]
  end

  defp cli(args) do
    {code, output} = ExUnit.CaptureIO.with_io(fn -> Gitspace.CLI.run(args) end)
    {output, code}
  end
end
