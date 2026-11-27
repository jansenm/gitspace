defmodule Gitspace.LayoutTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Gitspace.Layout

  test "work names keep case and collapse invalid runs" do
    assert Layout.work_slug("mt4711-update-dependencies") ==
             {:ok, "mt4711-update-dependencies"}

    assert Layout.work_slug("JENKINS-123") == {:ok, "JENKINS-123"}
    assert Layout.work_slug("  feat/foo   bar  ") == {:ok, "feat-foo-bar"}
    assert Layout.work_slug("...") == {:error, :empty}
    assert Layout.work_slug("   ") == {:error, :empty}
    assert Layout.work_slug("..") == {:error, :invalid}
  end

  test "long names are truncated with a hash suffix" do
    {:ok, slug} = Layout.work_slug(String.duplicate("a", 200))

    assert String.length(slug) == 60
    assert slug =~ ~r/^a+-[0-9a-f]{8}$/
  end

  test "remote keys drop default ports and keep non-default ports" do
    assert Layout.normalize_remote("https://gitlab.com:443/acme/config.git") ==
             "gitlab.com/acme/config"

    assert Layout.normalize_remote("https://gitlab.com/acme/config.git") ==
             "gitlab.com/acme/config"

    assert Layout.normalize_remote("https://gitlab.example.com:8443/acme/config.git") ==
             "gitlab.example.com:8443/acme/config"

    assert Layout.normalize_remote("ssh://git@github.com:22/acme/config.git") ==
             "github.com/acme/config"

    assert Layout.normalize_remote("ssh://git@github.com:2222/acme/config.git") ==
             "github.com:2222/acme/config"

    assert Layout.normalize_remote("git://example.com:9418/acme/config") ==
             "example.com/acme/config"

    assert Layout.normalize_remote("http://example.com:80/acme/config") ==
             "example.com/acme/config"
  end

  test "branches are derived from the work name" do
    assert Layout.branch_for("mt4711-update-dependencies") ==
             {:ok, "feature/mt4711-update-dependencies"}

    assert Layout.branch_for("JENKINS-123", "feature/{work}") ==
             {:ok, "feature/JENKINS-123"}

    assert Layout.branch_for("jenkins/ejb-remoting") ==
             {:ok, "feature/jenkins/ejb-remoting"}

    assert Layout.branch_for("jenkins/ejb-remoting", "feature_{work}") ==
             {:ok, "feature_jenkins/ejb-remoting"}

    assert Layout.branch_for("My Work") == {:error, :invalid_branch}
  end

  test "invalid branch templates are rejected" do
    assert Layout.branch_for("x", "bad branch {work}") == {:error, :invalid_branch}
    assert Layout.branch_for("x", "feature/{work}..") == {:error, :invalid_branch}
  end

  test "topics allow slug segments and '/' but reserve '@'" do
    assert Layout.valid_topic?("4711")
    assert Layout.valid_topic?("4711/sub")
    assert Layout.valid_topic?("feature/4711-x")

    refute Layout.valid_topic?("4711@sub")
    refute Layout.valid_topic?("My Work")
    refute Layout.valid_topic?("a//b")
    refute Layout.valid_topic?("a/../b")
    refute Layout.valid_topic?("4711/ü")
  end

  test "repository names reserve '@'" do
    assert Layout.repo_slug("api") == {:ok, "api"}
    assert Layout.repo_slug("api@v2") == {:error, :invalid_repo}
  end

  test "paths are workspace-first and contained" do
    assert Layout.path("/data/work", "JENKINS-123", "job-dsl") ==
             {:ok, "/data/work/JENKINS-123/job-dsl"}

    assert Layout.path("/data/work", "JENKINS-123", "owner/name") ==
             {:error, :invalid_repo}
  end

  test "marker path is inside the work directory" do
    assert Layout.marker_path("/data/work", "JENKINS-123") ==
             {:ok, "/data/work/JENKINS-123/.gitspace.json"}
  end

  property "work slugs are path-safe" do
    check all(name <- string(:printable, min_length: 1), max_runs: 100) do
      case Layout.work_slug(name) do
        {:ok, slug} ->
          assert slug =~ ~r/^[A-Za-z0-9._-]+$/
          assert String.length(slug) <= 60
          refute String.starts_with?(slug, ".")

        {:error, _} ->
          :ok
      end
    end
  end

  property "derived branches are valid" do
    check all(name <- string(:printable, min_length: 1), max_runs: 100) do
      case Layout.branch_for(name) do
        {:ok, branch} -> assert Layout.valid_branch?(branch)
        {:error, _} -> :ok
      end
    end
  end

  property "checkout paths never escape the root" do
    check all(
            name <- string(:printable, min_length: 1),
            repo <- member_of(["api", "web", "lib", "job-dsl"]),
            max_runs: 100
          ) do
      case Layout.path("/data/work", name, repo) do
        {:ok, path} -> assert String.starts_with?(path, "/data/work/")
        {:error, _} -> :ok
      end
    end
  end
end
