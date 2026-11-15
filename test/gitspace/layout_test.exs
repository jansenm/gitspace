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

  test "branches are derived from the work name" do
    assert Layout.branch_for("mt4711-update-dependencies") ==
             {:ok, "feature_mt4711-update-dependencies"}

    assert Layout.branch_for("JENKINS-123", "feature/{work}") ==
             {:ok, "feature/JENKINS-123"}
  end

  test "invalid branch templates are rejected" do
    assert Layout.branch_for("x", "bad branch {work}") == {:error, :invalid_branch}
    assert Layout.branch_for("x", "feature/{work}..") == {:error, :invalid_branch}
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
