defmodule Gitspace.IndexCase do
  @moduledoc "Starts a fresh SQLite index for each test."

  use ExUnit.CaseTemplate

  alias Gitspace.Config

  using do
    quote do
      import Gitspace.IndexCase
      alias Gitspace.{Config, Repo}
    end
  end

  setup _context do
    Gitspace.Index.stop()

    root = Gitspace.Fixtures.tmp_dir!("index")

    config = %Config{
      path: Path.join(root, "config.toml"),
      data_dir: Path.join(root, "data"),
      checkouts_dir: Path.join(root, "work")
    }

    File.mkdir_p!(config.data_dir)
    File.mkdir_p!(config.checkouts_dir)
    :ok = Gitspace.Index.ensure_started(config)

    on_exit(fn -> Gitspace.Index.stop() end)

    {:ok, config: config, root: root}
  end
end
