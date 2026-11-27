defmodule Gitspace.EnvTest do
  use Gitspace.IndexCase, async: false

  alias Gitspace.{Config, Create, Env, Fixtures, Projects, Repos}

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
    {:ok, _} = Repos.add(config, Fixtures.repo_url(source), name: "a")
    {:ok, _} = Projects.create(config, "demo", repo: ["a"])
    {:ok, _} = Create.co(config, "demo", "main", topic: "dev")

    project_path = Path.join(config.projects_root, "demo")
    workspace_path = Path.join([config.projects_root, "demo", "dev"])
    checkout_path = Path.join([config.projects_root, "demo", "dev", "a"])

    File.write!(
      Path.join(project_path, ".env"),
      "FOO=project\nDB=${GITSPACE_PROJECT}_${GITSPACE_TOPIC}\n"
    )

    File.write!(Path.join(project_path, ".env.secrets"), "FOO=secret\nTOKEN=shh\n")

    File.write!(Path.join(checkout_path, ".env"), "FOO=repo\nBAR=repo\n")
    File.write!(Path.join(checkout_path, ".env.local"), "FOO=local\n")

    {:ok,
     config: config,
     project_path: project_path,
     workspace_path: workspace_path,
     checkout_path: checkout_path}
  end

  test "resolves project, repo, secret and local layers", %{config: config} do
    assert {:ok, data} = Env.resolve(config, "demo@dev:a")

    values = Map.new(data.entries, &{&1.key, &1.value})
    sources = Map.new(data.entries, &{&1.key, &1.source})

    assert values["FOO"] == "local"
    assert sources["FOO"] == "repo .env.local"

    assert values["DB"] == "demo_dev"
    assert sources["DB"] == "project .env"

    assert values["BAR"] == "repo"
    assert values["TOKEN"] == "shh"
    assert values["GITSPACE_PROJECT"] == "demo"
    assert values["GITSPACE_TOPIC"] == "dev"
    assert values["GITSPACE_WORKSPACE"] == "demo@dev"
    assert values["GITSPACE_MEMBER"] == "a"
    assert values["GITSPACE_REPO"] == "a"
    assert values["GITSPACE_PATH"] == data.path
    assert sources["GITSPACE_MEMBER"] == "gitspace"

    assert data.path == Path.join([config.projects_root, "demo", "dev", "a"])
  end

  test "process environment wins, and --no-env keeps GITSPACE_* only", %{config: config} do
    System.put_env("FOO", "process")
    on_exit(fn -> System.delete_env("FOO") end)

    assert {:ok, data} = Env.resolve(config, "demo@dev:a")
    assert Map.new(data.entries, &{&1.key, &1.value})["FOO"] == "process"
    assert Map.new(data.entries, &{&1.key, &1.source})["FOO"] == "process"

    assert {:ok, bare} = Env.resolve(config, "demo@dev:a", no_env: true)
    keys = Enum.map(bare.entries, & &1.key)
    assert "GITSPACE_PROJECT" in keys
    assert "GITSPACE_MEMBER" in keys
    refute "FOO" in keys
    refute "TOKEN" in keys
  end

  test "file listing keeps GITSPACE placeholders", %{project_path: project_path} do
    assert {:ok, entries} = Env.file_entries(Path.join(project_path, ".env"))
    values = Map.new(entries, &{&1.key, &1.value})

    assert values["DB"] == "${GITSPACE_PROJECT}_${GITSPACE_TOPIC}"
    assert values["FOO"] == "project"

    assert {:ok, secrets} = Env.file_entries(Path.join(project_path, ".env.secrets"))
    assert Enum.sort(Enum.map(secrets, & &1.key)) == ["FOO", "TOKEN"]
  end

  test "reserved variables and command substitution are rejected", %{
    config: config,
    project_path: project_path
  } do
    File.write!(Path.join(project_path, ".env"), "GITSPACE_PROJECT=bad\n")

    assert {:error, error} = Env.resolve(config, "demo@dev:a")
    assert error.code == :invalid_config
    assert error.message =~ "reserved"

    File.write!(Path.join(project_path, ".env"), "FOO=$(echo bad)\n")

    assert {:error, error} = Env.resolve(config, "demo@dev:a")
    assert error.code == :invalid_config
    assert error.hint =~ "command substitution"
  end

  test "shell -c runs in the target with env and GITSPACE context", %{config: config} do
    out = Path.join(config.data_dir, "shell-out")

    command =
      "printf '%s|%s|%s' \"$FOO\" \"$GITSPACE_MEMBER\" \"$PWD\" > '#{out}'"

    assert 0 == Gitspace.CLI.run(["shell", "demo@dev:a", "-c", command])
    assert File.read!(out) == "local|a|#{Path.join([config.projects_root, "demo", "dev", "a"])}"

    bare = Path.join(config.data_dir, "shell-bare")

    command =
      "printf '%s|%s' \"${FOO-unset}\" \"$GITSPACE_MEMBER\" > '#{bare}'"

    assert 0 == Gitspace.CLI.run(["shell", "demo@dev:a", "--no-env", "-c", command])
    assert File.read!(bare) == "unset|a"
  end

  test "project env and secret commands list values and require a TTY for edit", %{
    project_path: project_path
  } do
    {output, 0} = cli(["project", "env", "path", "demo"])
    assert String.trim(output) == Path.join(project_path, ".env")

    {output, 0} = cli(["project", "env", "ls", "demo", "--json"])
    entries = Jason.decode!(output)["data"]["entries"]
    assert Enum.any?(entries, &(&1["key"] == "FOO" and &1["value"] == "project"))

    {output, 0} = cli(["project", "secret", "ls", "demo", "--json"])
    entries = Jason.decode!(output)["data"]["entries"]
    assert Enum.all?(entries, &Map.has_key?(&1, "key"))
    refute Enum.any?(entries, &Map.has_key?(&1, "value"))

    {output, 0} = cli(["project", "secret", "ls", "demo", "--values", "--json"])
    entries = Jason.decode!(output)["data"]["entries"]
    assert Enum.any?(entries, &(&1["key"] == "TOKEN" and &1["value"] == "shh"))

    assert 5 == Gitspace.CLI.run(["project", "env", "edit", "demo"])
  end

  test "ls and workspace ls can print paths", %{config: config} do
    {output, 0} = cli(["ls", "--paths"])
    assert output =~ Path.join([config.projects_root, "demo", "dev", "a"])

    {output, 0} = cli(["workspace", "ls", "--paths"])
    assert output =~ Path.join([config.projects_root, "demo", "dev"])
  end

  defp cli(args) do
    {code, output} = ExUnit.CaptureIO.with_io(fn -> Gitspace.CLI.run(args) end)
    {output, code}
  end
end
