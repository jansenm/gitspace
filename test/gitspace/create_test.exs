defmodule Gitspace.CreateTest do
  use Gitspace.IndexCase, async: false

  alias Gitspace.{Create, Fixtures, Git, Marker, Projects, Repos, Workspaces}

  setup %{config: config} do
    source_a = Fixtures.source_repo!(branches: ["hotfix/timeout"], tags: ["v1.0.0"])
    source_b = Fixtures.source_repo!()

    {:ok, repo_a} = Repos.add(config, Fixtures.repo_url(source_a), name: "a")
    {:ok, repo_b} = Repos.add(config, Fixtures.repo_url(source_b), name: "b")

    {:ok, repo_a: repo_a, repo_b: repo_b, source_a: source_a, source_b: source_b}
  end

  test "CREATE-1/5 co creates at a branch and is idempotent", %{config: config} do
    assert {:ok, result} = Create.co(config, "a", "main")
    assert result.workspace == "a@main"
    assert result.path == Path.join([config.projects_root, "a", "main"])
    assert File.exists?(result.marker_path)

    assert [member] = result.members
    assert member.repo == "a"
    assert member.ownership == "owned"
    assert member.branch == "main"
    assert member.ref == "main"
    refute member.detached
    assert member.action == "created"
    assert member.path == Path.join([config.projects_root, "a", "main", "a"])
    assert File.dir?(member.path)

    assert {:ok, again} = Create.co(config, "a", "main")
    assert [reused] = again.members
    assert reused.action == "kept"
    assert reused.path == member.path

    assert {:ok, workspace} = Workspaces.get(config, "a@main")
    assert length(workspace.members) == 1
  end

  test "CREATE-2 refs with slashes derive a sanitized work name", %{config: config} do
    assert {:ok, result} = Create.co(config, "a", "hotfix/timeout")
    assert result.workspace == "a@hotfix-timeout"
    assert result.path == Path.join([config.projects_root, "a", "hotfix-timeout"])

    assert [member] = result.members
    assert member.branch == "hotfix/timeout"
    refute member.detached
  end

  test "CREATE-3 tags and commits stay detached", %{config: config, repo_a: repo_a} do
    tag_sha = repo_a.bare_path |> git_sha("refs/tags/v1.0.0")

    assert {:ok, tag} = Create.co(config, "a", "v1.0.0")
    assert [tag_member] = tag.members
    assert tag_member.detached
    assert is_nil(tag_member.branch)
    assert tag_member.head == tag_sha

    assert {:ok, sha} = Create.co(config, "a", tag_sha, name: "by-sha", as_is: true)
    assert [sha_member] = sha.members
    assert sha_member.detached
    assert sha_member.head == tag_sha
  end

  test "CREATE-4 --branch creates a branch and --detach forces detached", %{config: config} do
    assert {:ok, branched} =
             Create.co(config, "a", "main", name: "custom", branch: "my-work")

    assert [branch_member] = branched.members
    assert branch_member.branch == "my-work"
    assert branch_member.ref == "main"

    assert {:ok, detached} = Create.co(config, "a", "main", name: "detached", detach: true)
    assert [detached_member] = detached.members
    assert detached_member.detached
    assert is_nil(detached_member.branch)
  end

  test "CREATE-6 workspace new derives the work branch in every owned member", %{
    config: config
  } do
    assert {:ok, result} =
             Create.workspace_new(
               config,
               "mt4711-update-dependencies",
               [owned("a"), owned("b")],
               [],
               labels: ["jira-mt4711"],
               description: "update dependencies"
             )

    assert result.created
    assert result.labels == ["jira-mt4711"]
    assert result.description == "update dependencies"

    assert Enum.map(result.members, & &1.branch) ==
             ["feature/mt4711-update-dependencies", "feature/mt4711-update-dependencies"]

    assert Enum.all?(result.members, &(&1.action == "created"))
    assert Enum.all?(result.members, &File.dir?(&1.path))

    marker = Marker.read!(result.path)
    assert marker["workspace"] == "a@mt4711-update-dependencies"
    assert marker["labels"] == ["jira-mt4711"]
    assert marker["description"] == "update dependencies"

    assert {:ok, workspace} = Workspaces.get(config, "a@mt4711-update-dependencies")
    assert length(workspace.members) == 2
    assert Enum.map(workspace.labels, & &1.label) == ["jira-mt4711"]
  end

  test "CREATE-7 an explicit ref opts out of derivation; --branch overrides it", %{
    config: config
  } do
    assert {:ok, explicit} =
             Create.workspace_new(
               config,
               "ref-opts-out",
               [owned("a", "hotfix/timeout")],
               [],
               branch: "ignored-branch"
             )

    assert [explicit_member] = explicit.members
    assert explicit_member.branch == "hotfix/timeout"

    assert {:ok, overridden} =
             Create.workspace_new(config, "branch-override", [owned("a")], [], branch: "custom")

    assert [custom_member] = overridden.members
    assert custom_member.branch == "custom"

    assert {:ok, tag_ref} =
             Create.workspace_new(config, "tag-ref", [owned("a", "v1.0.0")], [])

    assert [tag_member] = tag_ref.members
    assert tag_member.detached
    assert is_nil(tag_member.branch)
  end

  test "CREATE-8 an occupied branch asks for a decision and never overwrites", %{config: config} do
    assert {:ok, _holder} = Create.co(config, "a", "main", name: "holder", as_is: true)

    occupied = %{repo: "a", ref: "main", ownership: "owned", branch_mode: :ref}

    assert {:error, error} = Create.workspace_new(config, "occupied", [occupied], [])
    assert error.code == :branch_occupied
    assert error.exit_code == 4
    assert error.details.branch == "main"
    assert error.details.path == Path.join([config.projects_root, "a", "holder", "a"])
    refute File.exists?(Path.join(config.projects_root, "occupied"))

    assert {:ok, detached} =
             Create.workspace_new(config, "occupied-detach", [occupied], [],
               on_occupied: fn _ -> :detach end
             )

    assert [detached_member] = detached.members
    assert detached_member.detached

    assert {:ok, rebranched} =
             Create.workspace_new(config, "occupied-branch", [occupied], [],
               on_occupied: fn _ -> {:branch, "main-alt"} end
             )

    assert [branched_member] = rebranched.members
    assert branched_member.branch == "main-alt"

    assert {:ok, borrowed} =
             Create.workspace_new(config, "occupied-borrow", [occupied], [],
               on_occupied: fn _ -> :borrow end
             )

    assert [borrowed_member] = borrowed.members
    assert borrowed_member.ownership == "borrowed"
    assert borrowed_member.path == Path.join([config.projects_root, "a", "holder", "a"])

    assert {:ok, _feature_holder} =
             Create.co(config, "a", "main",
               name: "feature-holder",
               branch: "feature/occupied-derive"
             )

    assert {:error, derived_occupied} =
             Create.workspace_new(config, "occupied-derive", [owned("a")], [])

    assert derived_occupied.code == :branch_occupied
    assert derived_occupied.details.branch == "feature/occupied-derive"
  end

  test "CREATE-9 duplicate members and --branch with --borrow are usage errors", %{
    config: config
  } do
    assert {:error, duplicate} =
             Create.workspace_new(config, "duplicate", [owned("a"), owned("a")], [])

    assert duplicate.code == :usage
    assert duplicate.exit_code == 2

    assert {:error, borrowed_branch} =
             Create.workspace_new(config, "borrow-branch", [], [borrowed("a")], branch: "custom")

    assert borrowed_branch.code == :usage
    assert borrowed_branch.exit_code == 2
  end

  test "CREATE-10 an existing path is a conflict and is left untouched", %{config: config} do
    path = Path.join([config.projects_root, "a", "conflict", "a"])
    File.mkdir_p!(path)
    File.write!(Path.join(path, "keep.txt"), "do not overwrite")

    assert {:error, error} = Create.workspace_new(config, "conflict", [owned("a")], [])
    assert error.code == :conflict
    assert error.exit_code == 4

    assert File.read!(Path.join(path, "keep.txt")) == "do not overwrite"
    refute File.exists?(Path.join([config.projects_root, "a", "conflict", ".gitspace.json"]))
  end

  test "CREATE-11 a missing ref creates a partial workspace; re-run completes it", %{
    config: config
  } do
    assert {:partial, result, failures} =
             Create.workspace_new(
               config,
               "partial-create",
               [owned("a"), owned("b", "does-not-exist")],
               []
             )

    assert result.created
    assert File.exists?(result.marker_path)
    assert [%{repo: "a", action: "created"}] = result.members

    assert [failure] = failures
    assert failure.repo == "b"
    assert failure.code == :not_found

    assert {:ok, workspace} = Workspaces.get(config, "a@partial-create")
    assert length(workspace.members) == 1

    assert {:ok, completed} =
             Create.workspace_new(config, "partial-create", [owned("a"), owned("b")], [])

    actions = Map.new(completed.members, &{&1.repo, &1.action})
    assert actions["a"] == "kept"
    assert actions["b"] == "created"

    assert {:ok, workspace} = Workspaces.get(config, "a@partial-create")
    assert length(workspace.members) == 2
  end

  test "CREATE-12 a subset re-run keeps existing members and unions labels", %{
    config: config
  } do
    assert {:ok, initial} =
             Create.workspace_new(config, "subset", [owned("a"), owned("b")], [],
               labels: ["one"],
               description: "kept"
             )

    assert length(initial.members) == 2

    assert {:ok, subset} =
             Create.workspace_new(config, "subset", [owned("a")], [], labels: ["two"])

    actions = Map.new(subset.members, &{&1.repo, &1.action})
    assert actions["a"] == "kept"
    assert actions["b"] == "kept"
    assert subset.labels == ["one", "two"]
    assert subset.description == "kept"

    assert {:ok, workspace} = Workspaces.get(config, "a@subset")
    assert length(workspace.members) == 2
  end

  test "CREATE-13 topics allow '/' but reject spaces, unicode and reserved '@'", %{
    config: config
  } do
    assert {:ok, slashed} = Create.workspace_new(config, "4711/sub", [owned("a")], [])
    assert slashed.workspace == "a@4711/sub"
    assert Path.basename(slashed.path) == "4711-sub"
    assert [slashed_member] = slashed.members
    assert slashed_member.branch == "feature/4711-sub"

    assert {:error, spaced} = Create.workspace_new(config, "My Work", [owned("a")], [])
    assert spaced.code == :usage

    assert {:error, unicode} = Create.workspace_new(config, "4711/ü", [owned("a")], [])
    assert unicode.code == :usage

    assert {:error, at} = Create.workspace_new(config, "4711@x", [owned("a")], [], project: "a")
    assert at.code == :usage
  end

  test "project branch template and default ref drive derived branches", %{
    config: config,
    repo_a: repo_a
  } do
    hotfix_sha = git_sha(repo_a.bare_path, "refs/remotes/origin/hotfix/timeout")

    assert {:ok, _project} =
             Projects.create(config, "work",
               repo: ["a"],
               branch_template: "task/{topic}",
               default_ref: "hotfix/timeout"
             )

    assert {:ok, result} = Create.workspace_new(config, "work@x", [owned("a")], [])

    assert result.workspace == "work@x"
    assert [member] = result.members
    assert member.branch == "task/x"
    assert member.head == hotfix_sha
  end

  test "a slashed topic and its dashed twin collide loudly", %{config: config} do
    assert {:ok, first} = Create.workspace_new(config, "a@x/y", [owned("a")], [])
    assert first.workspace == "a@x/y"

    assert {:error, conflict} = Create.workspace_new(config, "a@x-y", [owned("a")], [])
    assert conflict.code == :conflict
    assert conflict.message =~ "a@x/y"
  end

  test "project names may not contain '@'", %{config: config} do
    assert {:error, error} = Projects.create(config, "a@b")
    assert error.code == :usage
  end

  test "CREATE-14 a warm mirror works without the source; missing refs hint at fetch", %{
    config: config,
    source_a: source_a
  } do
    File.rm_rf!(source_a)

    assert {:ok, result} = Create.co(config, "a", "main")
    assert [member] = result.members
    assert member.branch == "main"
    assert File.dir?(member.path)

    assert {:error, missing} = Create.co(config, "a", "missing-branch")
    assert missing.code == :not_found
    assert missing.hint =~ "fetch"
  end

  test "WS-9 borrowed selection is explicit when several checkouts exist", %{
    config: config
  } do
    assert {:ok, _main} = Create.co(config, "a", "main")
    assert {:ok, _tag} = Create.co(config, "a", "v1.0.0")

    assert {:error, ambiguous} =
             Create.workspace_new(config, "borrow-any", [], [borrowed("a")], [])

    assert ambiguous.code == :conflict
    assert ambiguous.exit_code == 4
    assert length(ambiguous.details.candidates) == 2

    assert {:ok, on_main} =
             Create.workspace_new(config, "borrow-main", [], [borrowed("a", "main")], [])

    assert [main_member] = on_main.members
    assert main_member.ownership == "borrowed"
    assert main_member.path == Path.join([config.projects_root, "a", "main", "a"])
    assert main_member.branch == "main"
    refute main_member.detached

    marker = Marker.read!(on_main.path)
    assert [borrowed_marker] = marker["members"]
    assert borrowed_marker["ownership"] == "borrowed"
    assert borrowed_marker["path"] == main_member.path

    assert {:ok, on_tag} =
             Create.workspace_new(config, "borrow-tag", [], [borrowed("a", "v1.0.0")], [])

    assert [tag_member] = on_tag.members
    assert tag_member.ownership == "borrowed"
    assert tag_member.detached
    assert tag_member.path == Path.join([config.projects_root, "a", "v1.0.0", "a"])
  end

  test "dry-run plans without creating directories or markers", %{config: config} do
    assert {:ok, result} =
             Create.workspace_new(config, "dry-run", [owned("a"), owned("b")], [], dry_run: true)

    assert result.dry_run
    assert result.created
    assert Enum.map(result.members, & &1.action) == ["create", "create"]
    refute File.exists?(result.path)
    refute File.exists?(result.marker_path)
    assert {:error, _} = Workspaces.get(config, "a@dry-run")
  end

  test "the configured branch template drives derived branches", %{config: config} do
    config = %{config | branch_template: "work/{work}"}

    assert {:ok, result} =
             Create.workspace_new(config, "template", [owned("a")], [])

    assert [member] = result.members
    assert member.branch == "work/template"
  end

  test "repo selectors can include an owner prefix", %{config: config} do
    assert {:ok, result} =
             Create.co(config, "jenkins/a", "main", name: "owner-prefix", as_is: true)

    assert [member] = result.members
    assert member.repo == "a"
    assert member.branch == "main"
  end

  test "per-checkout member names stay top-level and persist in the marker", %{
    config: config
  } do
    a = owned("a") |> Map.put(:member_name, "acme")
    b = owned("b") |> Map.put(:member_name, "beta")

    assert {:ok, result} = Create.workspace_new(config, "aliased", [a, b], [])

    assert Enum.map(result.members, & &1.name) == ["acme", "beta"]
    assert Enum.map(result.members, &Path.basename(&1.path)) == ["acme", "beta"]
    assert Enum.all?(result.members, &(Path.dirname(&1.path) == result.path))

    marker = Marker.read!(result.path)
    assert Enum.map(marker["members"], & &1["name"]) == ["acme", "beta"]
    assert Enum.all?(marker["members"], &is_binary(&1["remote"]))

    assert {:ok, workspace} = Workspaces.get(config, "a@aliased")
    names = workspace.members |> Enum.map(& &1.name) |> Enum.sort()
    assert names == ["acme", "beta"]

    assert {:ok, again} = Create.workspace_new(config, "aliased", [owned("a")], [])
    assert [acme, beta] = Enum.sort_by(again.members, & &1.name)
    assert acme.name == "acme"
    assert acme.action == "kept"
    assert beta.name == "beta"
    assert beta.action == "kept"
  end

  test "alias changes do not move or duplicate existing members", %{config: config} do
    assert {:ok, result} = Create.workspace_new(config, "alias-move", [owned("a")], [])
    assert [member] = result.members
    old_path = member.path

    assert {:ok, renamed} = Repos.set_alias(config, "a", "renamed")
    assert renamed.slug == "renamed"

    assert {:ok, again} = Create.workspace_new(config, "alias-move", [owned("renamed")], [])
    assert [kept] = again.members
    assert kept.path == old_path
    assert kept.action == "kept"
    assert kept.repo == "renamed"
    assert File.dir?(old_path)
    refute File.exists?(Path.join(result.path, "renamed"))
  end

  test "co reuses an existing workspace after the alias changes", %{config: config} do
    assert {:ok, first} = Create.co(config, "b", "main", name: "alias-co")
    path = hd(first.members).path

    assert {:ok, _} = Repos.set_alias(config, "b", "renamed-b")

    assert {:ok, second} = Create.co(config, "renamed-b", "main", name: "alias-co")
    assert [member] = second.members
    assert member.path == path
    assert member.action == "kept"
  end

  test "duplicate member names are refused", %{config: config} do
    a = owned("a") |> Map.put(:member_name, "same")
    b = owned("b") |> Map.put(:member_name, "same")

    assert {:error, error} = Create.workspace_new(config, "duplicate-names", [a, b], [])
    assert error.code == :conflict
    assert error.message =~ "same"
  end

  test "creation markers recover after the index is deleted", %{config: config} do
    assert {:ok, _result} =
             Create.workspace_new(config, "recovered", [owned("a"), owned("b")], [],
               labels: ["recover"],
               description: "survives"
             )

    Gitspace.Index.stop()
    File.rm_rf!(Gitspace.Config.db_path(config))

    assert {:ok, summary} = Gitspace.Index.reindex(config)
    assert summary.workspaces == 1
    assert summary.workspace_members == 2

    assert {:ok, workspace} = Workspaces.get(config, "a@recovered")
    assert length(workspace.members) == 2
    assert Enum.map(workspace.labels, & &1.label) == ["recover"]
    assert workspace.description == "survives"
  end

  test "co a repo that belongs to a project checks out only that repo", %{
    config: config,
    repo_a: repo_a
  } do
    assert {:ok, _project} = Projects.create(config, "vemags", repo: ["a", "b"])

    assert {:ok, result} = Create.co(config, "a", "main")

    assert result.project == "a"
    assert result.workspace == "a@main"
    assert result.path == Path.join([config.projects_root, "a", "main"])
    assert [member] = result.members
    assert member.repo == "a"
    assert member.path == Path.join([config.projects_root, "a", "main", "a"])
    assert File.dir?(member.path)

    assert {:ok, project} = Projects.get(config, "a")
    assert project.source == "implicit"
    assert project.members == [repo_a.remote_key]
  end

  test "co reuses an implicit one-repo project created under a previous alias", %{config: config} do
    assert {:ok, first} = Create.co(config, "b", "main", name: "alias-co")
    assert first.project == "b"
    path = hd(first.members).path

    assert {:ok, _} = Repos.set_alias(config, "b", "renamed-b")

    assert {:ok, second} = Create.co(config, "renamed-b", "main", name: "alias-co")
    assert second.project == "b"
    assert [member] = second.members
    assert member.path == path
    assert member.action == "kept"
  end

  defp owned(repo, ref \\ nil) do
    %{
      repo: repo,
      ref: ref,
      ownership: "owned",
      branch_mode: if(is_nil(ref), do: :derive, else: :ref)
    }
  end

  defp borrowed(repo, ref \\ nil), do: %{repo: repo, ref: ref, ownership: "borrowed"}

  defp git_sha(bare, ref) do
    ["rev-parse", ref]
    |> Git.run!(cd: bare)
    |> String.trim()
  end
end
