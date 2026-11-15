defmodule Gitspace.ConfigTest do
  use ExUnit.Case, async: false

  alias Gitspace.{Config, Fixtures}

  setup do
    root = Fixtures.tmp_dir!("config")
    path = Path.join(root, "config.toml")
    previous = System.get_env("GITSPACE_CONFIG")
    System.put_env("GITSPACE_CONFIG", path)

    on_exit(fn ->
      if previous,
        do: System.put_env("GITSPACE_CONFIG", previous),
        else: System.delete_env("GITSPACE_CONFIG")
    end)

    {:ok, root: root, path: path}
  end

  test "ENV-5 saves and reloads TOML configuration", %{root: root, path: path} do
    config = %Config{
      path: path,
      data_dir: Path.join(root, "data"),
      checkouts_dir: Path.join(root, "work")
    }

    assert :ok = Config.save(config)
    assert File.exists?(path)
    assert File.read!(path) =~ ~s([paths])

    assert {:ok, loaded} = Config.load()
    assert loaded.data_dir == config.data_dir
    assert loaded.checkouts_dir == config.checkouts_dir
    assert loaded.branch_template == "feature_{work}"
    assert loaded.git_minimum == "2.40"
  end

  test "ENV-1 environment overrides take precedence", %{root: root, path: path} do
    config = %Config{
      path: path,
      data_dir: Path.join(root, "data"),
      checkouts_dir: Path.join(root, "work")
    }

    assert :ok = Config.save(config)
    System.put_env("GITSPACE_DATA", Path.join(root, "other-data"))
    System.put_env("GITSPACE_CHECKOUTS", Path.join(root, "other-work"))

    on_exit(fn ->
      System.delete_env("GITSPACE_DATA")
      System.delete_env("GITSPACE_CHECKOUTS")
    end)

    assert {:ok, loaded} = Config.load()
    assert loaded.data_dir == Path.join(root, "other-data")
    assert loaded.checkouts_dir == Path.join(root, "other-work")
  end

  test "ENV-2 detects file-sync roots" do
    assert Config.sync_root?("/data/mjansen/nextcloud/shared/work")
    assert Config.sync_root?("/home/me/Dropbox/gitspace")
    refute Config.sync_root?("/data/work")
  end

  test "a missing checkout directory means not configured" do
    System.delete_env("GITSPACE_CHECKOUTS")
    assert {:error, :not_configured} = Config.load()
  end
end
