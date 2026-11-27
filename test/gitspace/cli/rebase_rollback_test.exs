defmodule Gitspace.CLI.RebaseRollbackTest do
  use Gitspace.IndexCase, async: false

  alias Gitspace.{Config, Fixtures, Git, Index, Marker, Projects, Repos}
  alias Gitspace.Git.Worktree

  setup %{config: config} do
    :ok = Config.save(config)
    System.delete_env("GITSPACE_DATA")
    System.delete_env("GITSPACE_PROJECTS_ROOT")
    previous = System.get_env("GITSPACE_CONFIG")
    System.put_env("GITSPACE_CONFIG", config.path)

    on_exit(fn ->
      if previous do
        System.put_env("GITSPACE_CONFIG", previous)
      else
        System.delete_env("GITSPACE_CONFIG")
      end
    end)

    source = Fixtures.source_repo!()
    {:ok, repo} = Repos.add(config, Fixtures.repo_url(source), name: "demo")
    {:ok, _project} = Projects.create(config, "demo", repo: ["demo"])
    path = Path.join([config.projects_root, "demo", "JENKINS-123", "demo"])
    File.mkdir_p!(Path.dirname(path))
    {:ok, _} = Worktree.add(repo.bare_path, path, "origin/main", branch: "feature_JENKINS-123")

    Marker.write!(Path.dirname(path), %{
      "schema_version" => 1,
      "workspace" => "demo@JENKINS-123",
      "project" => "demo",
      "topic" => "JENKINS-123",
      "description" => "move the deploy job",
      "labels" => ["jira-123"],
      "members" => [
        %{
          "repo" => "demo",
          "ownership" => "owned",
          "rel_path" => "demo",
          "branch" => "feature_JENKINS-123"
        }
      ]
    })

    {:ok, _summary} = Index.reindex(config)

    {:ok, repo: repo, path: path, source: source}
  end

  test "rollback restores the branch and removes its temporary keep ref", %{
    path: path,
    repo: repo,
    source: source
  } do
    Fixtures.configure_user(path)

    Fixtures.write(source, "upstream.txt", "up\n")
    Fixtures.commit!(source, "upstream work")
    Gitspace.Git.Mirror.fetch!(repo.bare_path)

    Fixtures.write(path, "local.txt", "local\n")
    Fixtures.commit!(path, "local work")
    original = head(path)

    {_, 0} = cli(["rebase", "--json"])
    refute head(path) == original

    {output, 0} = cli(["rebase", "--abort", "--yes", "--json"])
    entry = Jason.decode!(output)["data"]["entries"] |> hd()

    assert entry["status"] == "rolled_back"
    assert head(path) == original
    assert keep_refs(path) == []
  end

  defp head(path) do
    Git.run!(["rev-parse", "HEAD"], cd: path) |> String.trim()
  end

  defp keep_refs(path) do
    Git.run!(["for-each-ref", "--format=%(refname)", "refs/gitspace/keep/rebase"], cd: path)
    |> String.split("\n", trim: true)
  end

  defp cli(args) do
    {code, output} = ExUnit.CaptureIO.with_io(fn -> Gitspace.CLI.run(args) end)
    {output, code}
  end
end
