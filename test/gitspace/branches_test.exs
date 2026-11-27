defmodule Gitspace.BranchesTest do
  use Gitspace.IndexCase, async: false

  alias Gitspace.{Branches, Fixtures, Repos}
  alias Gitspace.Git.Worktree
  alias Gitspace.Git.Worktree

  setup %{config: config} do
    source = Fixtures.source_repo!(branches: ["hotfix/timeout"], tags: ["v1.0.0"])
    assert {:ok, repo} = Repos.add(config, Fixtures.repo_url(source), name: "demo")

    {:ok, repo: repo, source: source}
  end

  test "lists remote branches and opt-in tags", %{config: config} do
    assert {:ok, data} = Branches.list(config, "demo", tags: true)

    assert data.repo == "demo"
    assert data.default_branch == "main"

    assert Enum.map(data.branches, &{&1.kind, &1.name}) == [
             {:remote, "hotfix/timeout"},
             {:remote, "main"},
             {:tag, "v1.0.0"}
           ]

    assert Enum.find(data.branches, &(&1.name == "main")).default

    refute Enum.find(data.branches, &(&1.name == "main")).checked_out
  end

  test "excludes tags unless requested", %{config: config} do
    assert {:ok, data} = Branches.list(config, "demo")
    refute Enum.any?(data.branches, &(&1.kind == :tag))
  end

  test "filters with a glob or a regex", %{config: config} do
    assert {:ok, data} = Branches.list(config, "demo", match: "hotfix/*")
    assert Enum.map(data.branches, & &1.name) == ["hotfix/timeout"]

    assert {:ok, data} = Branches.list(config, "demo", match: "nope*")
    assert data.branches == []

    assert {:ok, data} = Branches.list(config, "demo", regex: "^main$")
    assert Enum.map(data.branches, & &1.name) == ["main"]

    assert {:error, error} = Branches.list(config, "demo", match: "*", regex: ".*")
    assert error.code == :usage

    assert {:error, error} = Branches.list(config, "demo", regex: "[")
    assert error.code == :usage
  end

  test "marks a local branch as checked out", %{config: config, repo: repo} do
    path = Path.join([config.projects_root, "demo", "feature_x", "demo"])
    File.mkdir_p!(Path.dirname(path))
    assert {:ok, _} = Worktree.add(repo.bare_path, path, "origin/main", branch: "feature_x")

    assert {:ok, data} = Branches.list(config, "demo")

    local = Enum.find(data.branches, &(&1.kind == :local and &1.name == "feature_x"))
    assert local.checked_out == path
    refute local.default
  end
end
