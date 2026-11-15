defmodule Gitspace.ProbeTest do
  @moduledoc """
  M0 probes for repositories whose contents are not fully modelled in v1.

  v1 promises **no-crash** behaviour for submodules and LFS, not correct
  materialisation. These tests pin that promise down.
  """

  use ExUnit.Case, async: true

  alias Gitspace.{Fixtures, Git}
  alias Gitspace.Git.Status

  test "a repo with a submodule mirrors and creates a worktree without crashing" do
    sub = Fixtures.source_repo!()
    parent = Fixtures.source_repo!()

    Git.run!(
      ["-c", "protocol.file.allow=always", "submodule", "add", sub, "vendor/sub"],
      cd: parent
    )

    Fixtures.commit!(parent, "add submodule")

    bare = Fixtures.mirror!(parent)
    path = Fixtures.worktree!(bare, "origin/main")

    assert File.dir?(path)
    assert File.exists?(Path.join(path, ".gitmodules"))

    # `worktree add` does not initialise submodules. The directory exists but
    # is empty; that is acceptable for v1 as long as nothing breaks.
    assert File.dir?(Path.join(path, "vendor/sub"))

    assert %Status{} = Status.read!(path)
  end

  @tag :lfs
  test "a repo with LFS pointers mirrors and creates a worktree without crashing" do
    if System.find_executable("git-lfs") do
      dir = Fixtures.tmp_dir!("lfs")
      Git.run!(["init", "--initial-branch=main", dir])
      Fixtures.configure_user(dir)

      Git.run!(["lfs", "install", "--local"], cd: dir)
      Git.run!(["lfs", "track", "*.bin"], cd: dir)

      File.write!(Path.join(dir, "asset.bin"), :crypto.strong_rand_bytes(256))
      Fixtures.commit!(dir, "add lfs asset")

      bare = Fixtures.mirror!(dir)
      path = Fixtures.worktree!(bare, "origin/main")

      assert File.exists?(Path.join(path, "asset.bin"))
      assert %Status{} = Status.read!(path)

      # The mirror has no LFS filter configuration and no LFS object store, so
      # the checkout contains the pointer file. No crash, wrong content: this is
      # exactly why v1 only promises no-crash for LFS.
      assert File.read!(Path.join(path, "asset.bin")) =~ "git-lfs.github.com/spec/v1"
    else
      IO.puts("git-lfs not installed; skipping LFS probe")
    end
  end
end
