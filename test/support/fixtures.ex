defmodule Gitspace.Fixtures do
  @moduledoc "Real git repositories in temp dirs; no mocks."

  import ExUnit.Callbacks, only: [on_exit: 1]

  alias Gitspace.Git

  def tmp_dir!(label) do
    base =
      Path.join(
        System.tmp_dir!(),
        "gitspace-#{label}-#{System.unique_integer([:positive])}"
      )

    File.rm_rf!(base)
    File.mkdir_p!(base)
    on_exit(fn -> File.rm_rf!(base) end)
    base
  end

  def source_repo!(opts \\ []) do
    dir = tmp_dir!("src")
    Git.run!(["init", "--initial-branch=main", dir])
    configure_user(dir)

    write(dir, "README.md", "# fixture\n")
    commit!(dir, "initial")

    Enum.each(opts[:branches] || [], &Git.run!(["branch", &1], cd: dir))
    Enum.each(opts[:tags] || [], &Git.run!(["tag", &1], cd: dir))

    dir
  end

  def configure_user(dir) do
    Git.run!(["config", "user.email", "test@example.com"], cd: dir)
    Git.run!(["config", "user.name", "Test"], cd: dir)
  end

  def write(dir, relative, contents) do
    path = Path.join(dir, relative)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, contents)
    path
  end

  def commit!(dir, message) do
    Git.run!(["add", "-A"], cd: dir)

    Git.run!(
      [
        "-c",
        "user.name=Test",
        "-c",
        "user.email=test@example.com",
        "commit",
        "-m",
        message
      ],
      cd: dir
    )
  end

  def mirror!(source) do
    bare = Path.join(tmp_dir!("mirror"), "repo.git")
    Gitspace.Git.Mirror.init!(bare, source)
    configure_user(bare)
    bare
  end

  def worktree!(bare, ref, opts \\ []) do
    path = Path.join(tmp_dir!("wt"), "checkout")

    {:ok, _} =
      Gitspace.Git.Worktree.add(bare, path, ref,
        detach: Keyword.get(opts, :detach, true),
        branch: opts[:branch]
      )

    path
  end
end
