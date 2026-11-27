defmodule Gitspace.KeepTest do
  use Gitspace.IndexCase, async: false

  alias Gitspace.{Fixtures, Keep, Repos, Safety}
  alias Gitspace.Git

  setup %{config: config} do
    :ok = Gitspace.Config.save(config)
    System.put_env("GITSPACE_CONFIG", config.path)
    System.delete_env("GITSPACE_DATA")
    System.delete_env("GITSPACE_PROJECTS_ROOT")

    on_exit(fn ->
      System.delete_env("GITSPACE_CONFIG")
      System.delete_env("GITSPACE_DATA")
      System.delete_env("GITSPACE_PROJECTS_ROOT")
    end)

    source = Fixtures.source_repo!()
    {:ok, repo} = Repos.add(config, Fixtures.repo_url(source), name: "demo")
    path = Fixtures.worktree!(repo.bare_path, "origin/main", detach: false, branch: "main")

    %{config: config, repo: repo, path: path}
  end

  test "classifies redundant and orphaned anchors", %{config: config, repo: repo, path: path} do
    now = System.system_time(:second)
    old = now - 10 * 86_400
    reachable = ref!(repo, "origin/main")

    assert :ok =
             Safety.anchor!(
               repo.bare_path,
               "refs/gitspace/keep/doctor/abcdef12-#{now}",
               reachable
             )

    orphan = orphan_commit!(path)
    assert :ok = Safety.anchor!(repo.bare_path, "refs/gitspace/keep/demo-main/#{old}", orphan)

    entries = Keep.list(config)

    assert length(entries) == 2

    redundant = Enum.find(entries, & &1.redundant)
    kept = Enum.find(entries, &(not &1.redundant))

    assert redundant.kind == "doctor"
    assert redundant.sha == reachable
    assert kept.kind == "demo-main"
    assert kept.sha == orphan
    assert kept.age_days == 10

    summary = Keep.summary(config)
    assert summary.total == 2
    assert summary.redundant == 1
    assert summary.orphaned == 1
    assert summary.oldest_days == 10
  end

  test "prune removes redundant anchors and ages out orphans on request", %{
    config: config,
    repo: repo,
    path: path
  } do
    now = System.system_time(:second)
    old = now - 10 * 86_400
    reachable = ref!(repo, "origin/main")
    orphan = orphan_commit!(path)

    assert :ok =
             Safety.anchor!(
               repo.bare_path,
               "refs/gitspace/keep/doctor/abcdef12-#{now}",
               reachable
             )

    assert :ok = Safety.anchor!(repo.bare_path, "refs/gitspace/keep/demo-main/#{old}", orphan)

    result = Keep.prune(config)
    assert length(result.pruned) == 1
    assert hd(result.pruned).redundant
    assert length(result.kept) == 1
    assert ref_names(repo) == ["refs/gitspace/keep/demo-main/#{old}"]

    assert Keep.prune(config, older_than: 20).pruned == []
    assert length(ref_names(repo)) == 1

    dry = Keep.prune(config, older_than: 5, dry_run: true)
    assert length(dry.pruned) == 1
    assert length(ref_names(repo)) == 1

    result = Keep.prune(config, older_than: 5)
    assert length(result.pruned) == 1
    assert ref_names(repo) == []
  end

  test "keep ls and prune work through the CLI", %{repo: repo, path: path} do
    now = System.system_time(:second)
    old = now - 10 * 86_400
    reachable = ref!(repo, "origin/main")
    orphan = orphan_commit!(path)

    assert :ok =
             Safety.anchor!(
               repo.bare_path,
               "refs/gitspace/keep/doctor/abcdef12-#{now}",
               reachable
             )

    assert :ok = Safety.anchor!(repo.bare_path, "refs/gitspace/keep/demo-main/#{old}", orphan)

    {list, 0} = cli(["doctor", "keep", "ls", "--json"])
    entries = Jason.decode!(list)["data"]["entries"]
    assert length(entries) == 2

    {refused, 6} = cli(["doctor", "keep", "prune", "--older-than", "5", "--json"])
    assert Jason.decode!(refused)["error"]["code"] == "confirmation_required"

    {pruned, 0} = cli(["doctor", "keep", "prune", "--older-than", "5", "--yes", "--json"])
    assert length(Jason.decode!(pruned)["data"]["pruned"]) == 2
    assert ref_names(repo) == []
  end

  test "doctor reports and --fix prunes redundant anchors", %{repo: repo} do
    reachable = ref!(repo, "origin/main")
    ref = "refs/gitspace/keep/doctor/abcdef12-#{System.system_time(:second)}"
    assert :ok = Safety.anchor!(repo.bare_path, ref, reachable)

    {output, 0} = cli(["doctor", "--json"])
    check = Enum.find(Jason.decode!(output)["data"]["checks"], &(&1["name"] == "keep"))
    assert check["status"] == "warn"

    {fixed, 0} = cli(["doctor", "fix", "--json"])
    keep_fix = Enum.find(Jason.decode!(fixed)["data"]["fixes"], &(&1["kind"] == "keep"))
    assert keep_fix["pruned"] == 1
    assert ref_names(repo) == []
  end

  defp orphan_commit!(path) do
    Fixtures.write(path, "orphan.txt", "orphan\n")
    Fixtures.commit!(path, "orphan")
    sha = Git.run!(["rev-parse", "HEAD"], cd: path) |> String.trim()
    Git.run!(["reset", "--hard", "HEAD~1"], cd: path)
    sha
  end

  defp ref!(repo, ref) do
    Git.run!(["rev-parse", ref], cd: repo.bare_path) |> String.trim()
  end

  defp ref_names(repo) do
    Git.run!(["for-each-ref", "--format=%(refname)", "refs/gitspace/keep/"], cd: repo.bare_path)
    |> String.split("\n", trim: true)
  end

  defp cli(args) do
    {code, output} = ExUnit.CaptureIO.with_io(fn -> Gitspace.CLI.run(args) end)
    {output, code}
  end
end
