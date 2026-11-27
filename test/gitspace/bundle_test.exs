defmodule Gitspace.BundleTest do
  use Gitspace.IndexCase, async: false

  alias Gitspace.{Bundle, Fixtures, Layout, Projects, Repos}

  test "export contains projects and remote repositories but skips local ones", %{config: config} do
    source_a = Fixtures.source_repo!()
    source_b = Fixtures.source_repo!()
    {:ok, _} = Repos.add(config, Fixtures.repo_url(source_a), name: "a")
    {:ok, _} = Repos.add(config, Fixtures.repo_url(source_b), name: "b")
    {:ok, _local} = Repos.init_local(config, "local-one")

    {:ok, _} =
      Projects.create(config, "vemags",
        repo: ["a", "b"],
        description: "migration",
        branch_template: "feature/{topic}",
        default_ref: "main"
      )

    bundle = Bundle.export(config)

    assert bundle["app"] == "gitspace"
    assert bundle["schema_version"] == 1
    assert Enum.map(bundle["repos"], & &1["alias"]) == ["a", "b"]
    assert Enum.all?(bundle["repos"], &(&1["origin_kind"] == "remote"))

    project = Enum.find(bundle["projects"], &(&1["name"] == "vemags"))
    assert project["members"] == ["a", "b"]
    assert project["description"] == "migration"
    assert project["branch_template"] == "feature/{topic}"
    assert project["default_ref"] == "main"

    assert Enum.any?(bundle["skipped"], &(&1["alias"] == "local-one"))
  end

  test "export redacts credentials in remote URLs", %{config: config} do
    url = "https://user:secret@example.com/org/private.git"

    assert {:ok, _} = Repos.add(config, url, name: "private", no_fetch: true)

    bundle = Bundle.export(config)
    repo = Enum.find(bundle["repos"], &(&1["alias"] == "private"))

    assert repo["remote_url"] == "https://example.com/org/private.git"
    assert repo["credentials_removed"]
  end

  test "import creates missing repositories and projects and is idempotent", %{config: config} do
    source = Fixtures.source_repo!()
    url = Fixtures.repo_url(source)
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
        %{
          "name" => "imported-project",
          "description" => "from a bundle",
          "branch_template" => "feature/{topic}",
          "default_ref" => "main",
          "members" => ["imported"]
        }
      ]
    }

    assert {:ok, summary} = Bundle.import_bundle(config, bundle, no_fetch: true)
    refute summary.dry_run
    assert [%{alias: "imported", action: :create}] = summary.repos

    assert [%{name: "imported-project", action: :create, members: ["imported"]}] =
             summary.projects

    assert {:ok, repo} = Repos.get(config, "imported")
    assert repo.remote_key == key

    assert {:ok, project} = Projects.get(config, "imported-project")
    assert project.members == [key]
    assert project.description == "from a bundle"

    assert {:ok, again} = Bundle.import_bundle(config, bundle, no_fetch: true)
    assert [%{alias: "imported", action: :exists}] = again.repos
    assert [%{name: "imported-project", action: :exists}] = again.projects
    assert again.warnings == []
  end

  test "import leaves existing projects untouched and reports missing members", %{config: config} do
    source = Fixtures.source_repo!()
    url = Fixtures.repo_url(source)
    key = Layout.normalize_remote(url)

    assert {:ok, _} = Repos.add(config, url, name: "a")
    assert {:ok, _} = Projects.create(config, "existing", repo: ["a"], description: "keep me")

    bundle = %{
      "app" => "gitspace",
      "schema_version" => 1,
      "repos" => [
        %{
          "alias" => "a",
          "origin_kind" => "remote",
          "remote_url" => url,
          "remote_key" => key,
          "default_branch" => "main"
        }
      ],
      "projects" => [
        %{"name" => "existing", "description" => "overwrite", "members" => ["a", "missing"]},
        %{"name" => "new-one", "description" => "new", "members" => ["a", "missing"]}
      ]
    }

    assert {:partial, summary, warnings} = Bundle.import_bundle(config, bundle, no_fetch: true)

    assert Enum.any?(summary.projects, &(&1.name == "existing" and &1.action == :exists))
    assert Enum.any?(summary.projects, &(&1.name == "new-one" and &1.action == :create))
    assert Enum.any?(warnings, &String.contains?(&1, "missing"))

    assert {:ok, existing} = Projects.get(config, "existing")
    assert existing.description == "keep me"
    assert existing.members == [key]

    assert {:ok, created} = Projects.get(config, "new-one")
    assert created.members == [key]
  end

  test "import does not touch an alias with a different identity", %{config: config} do
    source = Fixtures.source_repo!()
    other = Fixtures.source_repo!()

    assert {:ok, _} = Repos.add(config, Fixtures.repo_url(source), name: "taken")
    {:ok, before} = Repos.get(config, "taken")

    bundle = %{
      "app" => "gitspace",
      "schema_version" => 1,
      "repos" => [
        %{
          "alias" => "taken",
          "origin_kind" => "remote",
          "remote_url" => Fixtures.repo_url(other),
          "default_branch" => "main"
        }
      ],
      "projects" => []
    }

    assert {:partial, _summary, warnings} = Bundle.import_bundle(config, bundle, no_fetch: true)
    assert Enum.any?(warnings, &String.contains?(&1, "different identity"))
    assert {:ok, after_repo} = Repos.get(config, "taken")
    assert after_repo.remote_key == before.remote_key
  end

  test "dry-run creates nothing", %{config: config} do
    source = Fixtures.source_repo!()

    bundle = %{
      "app" => "gitspace",
      "schema_version" => 1,
      "repos" => [
        %{
          "alias" => "dry",
          "origin_kind" => "remote",
          "remote_url" => Fixtures.repo_url(source),
          "default_branch" => "main"
        }
      ],
      "projects" => [%{"name" => "dry-project", "members" => ["dry"]}]
    }

    assert {:ok, summary} = Bundle.import_bundle(config, bundle, dry_run: true, no_fetch: true)
    assert summary.dry_run
    assert {:error, _} = Repos.get(config, "dry")
    assert {:error, _} = Projects.get(config, "dry-project")
  end

  test "rejects a foreign or future bundle", %{config: config} do
    assert {:error, error} =
             Bundle.import_bundle(config, %{"app" => "other", "schema_version" => 1})

    assert error.code == :invalid_config

    assert {:error, error} =
             Bundle.import_bundle(config, %{"app" => "gitspace", "schema_version" => 99})

    assert error.code == :invalid_config
  end
end
