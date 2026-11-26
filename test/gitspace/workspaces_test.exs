defmodule Gitspace.WorkspacesTest do
  use Gitspace.IndexCase, async: false

  alias Gitspace.{Fixtures, Marker, Projects, Repos, Workspaces}
  alias Gitspace.Git.Worktree
  alias Gitspace.Index.Repository

  test "reindex flags legacy project/topic markers instead of importing them", %{config: config} do
    project_path = Path.join(config.projects_root, "legacy")
    assert {:ok, _project} = Projects.create(config, "legacy", path: project_path)

    dir = Path.join(project_path, "main")
    File.mkdir_p!(dir)
    Marker.write!(dir, Marker.build("legacy/main", project: "legacy", topic: "main", members: []))

    assert {:ok, summary} = Workspaces.reindex(config)

    assert Enum.any?(summary.issues, &(&1.kind == :legacy_workspace_name))
    assert Workspaces.list(config) == []
  end

  test "REC-1 recovers owned and borrowed members, labels and missing paths", %{config: config} do
    source = Fixtures.source_repo!()
    {:ok, demo} = Repos.add(config, Fixtures.repo_url(source), name: "demo")

    lib_source = Fixtures.source_repo!()
    {:ok, lib} = Repos.add(config, Fixtures.repo_url(lib_source), name: "lib")

    ui_source = Fixtures.source_repo!()
    {:ok, _ui} = Repos.add(config, Fixtures.repo_url(ui_source), name: "ui")

    {:ok, _project} = Projects.create(config, "demo", repo: ["demo"])
    owned_path = Path.join([config.projects_root, "demo", "JENKINS-123", "demo"])
    borrowed_path = Path.join([config.projects_root, "demo", "main", "lib"])

    File.mkdir_p!(Path.dirname(owned_path))
    File.mkdir_p!(Path.dirname(borrowed_path))

    {:ok, _} =
      Worktree.add(demo.bare_path, owned_path, "origin/main", branch: "feature_JENKINS-123")

    {:ok, _} = Worktree.add(lib.bare_path, borrowed_path, "origin/main", branch: "main")

    work_dir = Path.dirname(owned_path)

    marker =
      Marker.build("demo@JENKINS-123",
        project: "demo",
        topic: "JENKINS-123",
        description: "move the deploy job",
        labels: ["jira-123"],
        members: [
          %{
            "repo" => "demo",
            "ownership" => "owned",
            "rel_path" => "demo",
            "branch" => "feature_JENKINS-123"
          },
          %{
            "repo" => "lib",
            "ownership" => "borrowed",
            "path" => borrowed_path,
            "ref" => "main"
          },
          %{
            "repo" => "ui",
            "ownership" => "owned",
            "rel_path" => "ui",
            "branch" => "feature_JENKINS-123"
          }
        ]
      )

    Marker.write!(work_dir, marker)

    assert {:ok, summary} = Workspaces.reindex(config)
    assert summary.workspaces == 1
    assert summary.members == 3
    assert summary.issues == []

    assert {:ok, workspace} = Workspaces.get(config, "demo@JENKINS-123")
    assert workspace.description == "move the deploy job"
    assert Enum.map(workspace.labels, & &1.label) == ["jira-123"]
    assert length(workspace.members) == 3

    owned =
      Enum.find(workspace.members, &(&1.ownership == "owned" and &1.checkout.path == owned_path))

    assert owned
    assert owned.checkout.source == "managed"
    assert owned.checkout.branch == "feature_JENKINS-123"

    borrowed = Enum.find(workspace.members, &(&1.ownership == "borrowed"))
    assert borrowed
    assert borrowed.checkout.path == borrowed_path
    assert borrowed.checkout.source == "external"

    missing = Enum.find(workspace.members, &(&1.checkout.state == "missing"))
    assert missing
    assert missing.checkout.path == Path.join(work_dir, "ui")
  end

  test "invalid markers are reported, not hidden", %{config: config} do
    {:ok, _project} = Projects.create(config, "broken")
    broken = Path.join([config.projects_root, "broken", "BROKEN", ".gitspace.json"])
    File.mkdir_p!(Path.dirname(broken))
    File.write!(broken, "{not json")

    assert {:ok, summary} = Workspaces.reindex(config)
    assert summary.workspaces == 0
    assert Enum.any?(summary.issues, &(&1.kind == :invalid_marker))
  end

  test "a duplicate member name does not stop later members from being indexed", %{
    config: config
  } do
    register_repos(["a", "b", "c"])

    work_dir = Path.join([config.projects_root, "demo", "duplicate-name"])
    File.mkdir_p!(work_dir)

    marker =
      Marker.build("demo@duplicate-name",
        project: "demo",
        topic: "duplicate-name",
        members: [
          owned_member("a", "same", "a-dir"),
          owned_member("b", "same", "b-dir"),
          owned_member("c", "c", "c-dir")
        ]
      )

    Marker.write!(work_dir, marker)

    assert {:ok, 2, [issue]} = Workspaces.recover(config, work_dir, marker)
    assert issue.kind == :member

    assert {:ok, workspace} = Workspaces.get(config, "demo@duplicate-name")

    assert workspace.members |> Enum.map(& &1.checkout.repository.slug) |> Enum.sort() == [
             "a",
             "c"
           ]
  end

  test "a duplicate repository does not stop later members from being indexed", %{
    config: config
  } do
    register_repos(["a", "b"])

    work_dir = Path.join([config.projects_root, "demo", "duplicate-repo"])
    File.mkdir_p!(work_dir)

    marker =
      Marker.build("demo@duplicate-repo",
        project: "demo",
        topic: "duplicate-repo",
        members: [
          owned_member("a", "a-one"),
          owned_member("a", "a-two"),
          owned_member("b", "b")
        ]
      )

    Marker.write!(work_dir, marker)

    assert {:ok, 2, [issue]} = Workspaces.recover(config, work_dir, marker)
    assert issue.kind == :member

    assert {:ok, workspace} = Workspaces.get(config, "demo@duplicate-repo")

    assert workspace.members |> Enum.map(& &1.checkout.repository.slug) |> Enum.sort() == [
             "a",
             "b"
           ]
  end

  defp register_repos(slugs) do
    Enum.each(slugs, fn slug ->
      {:ok, _repo} =
        %Repository{}
        |> Repository.changeset(%{
          slug: slug,
          remote_url: "file:///#{slug}",
          remote_key: slug,
          state: "external"
        })
        |> Repo.insert()
    end)
  end

  defp owned_member(slug, name, rel_path \\ nil) do
    %{
      "repo" => slug,
      "remote" => slug,
      "name" => name,
      "ownership" => "owned",
      "rel_path" => rel_path || name,
      "branch" => "main"
    }
  end
end
