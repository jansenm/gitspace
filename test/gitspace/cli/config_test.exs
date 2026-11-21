defmodule Gitspace.CLI.ConfigTest do
  use Gitspace.IndexCase, async: false

  alias Gitspace.Config

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

    {:ok, config: config}
  end

  test "config list reports effective values and sources", %{config: config} do
    {output, 0} = cli(["config", "list", "--json"])
    data = Jason.decode!(output)["data"]

    assert data["configured"] == true
    assert data["config_path"] == config.path
    assert data["values"]["paths.data"] == config.data_dir
    assert data["values"]["projects.root"] == config.projects_root
    assert data["values"]["branch.template"] == "feature/{topic}"
    assert data["sources"]["paths.data"] == "file"
  end

  test "config get returns one effective value", %{config: config} do
    {output, 0} = cli(["config", "get", "projects.root", "--json"])
    data = Jason.decode!(output)["data"]

    assert data["key"] == "projects.root"
    assert data["value"] == config.projects_root
  end

  test "config set validates and persists a value", %{config: config} do
    {output, 0} = cli(["config", "set", "branch.template", "work/{work}", "--json"])
    data = Jason.decode!(output)["data"]

    assert data["key"] == "branch.template"
    assert data["value"] == "work/{work}"
    assert data["env_override"] == false

    assert {:ok, reloaded} = Config.load_file()
    assert reloaded.branch_template == "work/{work}"
    assert reloaded.projects_root == config.projects_root
  end

  test "config set rejects invalid values without writing the file", %{config: config} do
    {output, 2} = cli(["config", "set", "status.max_age_seconds", "soon", "--json"])
    assert Jason.decode!(output)["error"]["code"] == "usage"

    {output, 2} = cli(["config", "set", "branch.template", "bad branch", "--json"])
    assert Jason.decode!(output)["error"]["code"] == "usage"

    assert {:ok, reloaded} = Config.load_file()
    assert reloaded.status_max_age == 3600
    assert reloaded.branch_template == "feature/{topic}"
    assert reloaded.projects_root == config.projects_root
  end

  test "unknown configuration keys are usage errors" do
    {output, 2} = cli(["config", "get", "nope", "--json"])
    assert Jason.decode!(output)["error"]["code"] == "usage"

    {output, 2} = cli(["config", "set", "nope", "value", "--json"])
    assert Jason.decode!(output)["error"]["code"] == "usage"
  end

  test "config set refuses a file-sync root unless forced", %{config: config} do
    {output, 5} =
      cli(["config", "set", "projects.root", "/data/mjansen/nextcloud/shared/work", "--json"])

    assert Jason.decode!(output)["error"]["code"] == "refused"

    assert {:ok, reloaded} = Config.load_file()
    assert reloaded.projects_root == config.projects_root

    {output, 0} =
      cli([
        "config",
        "set",
        "projects.root",
        "/data/mjansen/nextcloud/shared/work",
        "--force",
        "--json"
      ])

    assert Jason.decode!(output)["data"]["value"] == "/data/mjansen/nextcloud/shared/work"
  end

  test "environment overrides are visible and noted on set", %{config: config, root: root} do
    env_data = Path.join(root, "env-data")
    System.put_env("GITSPACE_DATA", env_data)

    {output, 0} = cli(["config", "list", "--json"])
    data = Jason.decode!(output)["data"]

    assert data["values"]["paths.data"] == env_data
    assert data["sources"]["paths.data"] == "env"

    new_data = Path.join(root, "new-data")
    {set_output, 0} = cli(["config", "set", "paths.data", new_data, "--json"])
    set_data = Jason.decode!(set_output)["data"]

    assert set_data["env_override"] == true
    assert set_data["note"] =~ "environment overrides"

    assert {:ok, reloaded} = Config.load_file()
    assert reloaded.data_dir == new_data
    assert reloaded.projects_root == config.projects_root
  end

  test "a missing configuration is reported, not guessed" do
    File.rm!(Config.config_path())

    {output, 7} = cli(["config", "set", "branch.template", "work/{work}", "--json"])
    assert Jason.decode!(output)["error"]["code"] == "not_configured"

    {output, 0} = cli(["config", "list", "--json"])
    data = Jason.decode!(output)["data"]
    assert data["configured"] == false
    assert data["sources"]["projects.root"] == "unset"
  end

  test "config --help shows the command surface", _context do
    {output, 0} = cli(["config", "--help"])
    assert output =~ "gitspace config set <key> <value>"
    assert output =~ "status.max_age_seconds"
  end

  test "top-level help lists config", _context do
    {output, 0} = cli(["--help"])
    assert output =~ "config [list|get|set]"
  end

  defp cli(args) do
    {code, output} = ExUnit.CaptureIO.with_io(fn -> Gitspace.CLI.run(args) end)
    {output, code}
  end
end
