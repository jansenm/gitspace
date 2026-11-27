defmodule Gitspace.CLI.CompletionTest do
  use Gitspace.IndexCase, async: false

  alias Gitspace.{Config, Fixtures, Repos}

  setup %{config: config} do
    :ok = Config.save(config)
    previous = System.get_env("GITSPACE_CONFIG")
    System.put_env("GITSPACE_CONFIG", config.path)
    System.delete_env("GITSPACE_DATA")
    System.delete_env("GITSPACE_PROJECTS_ROOT")

    on_exit(fn ->
      if previous do
        System.put_env("GITSPACE_CONFIG", previous)
      else
        System.delete_env("GITSPACE_CONFIG")
      end

      System.delete_env("GITSPACE_DATA")
      System.delete_env("GITSPACE_PROJECTS_ROOT")
    end)

    for name <- ["api", "web"] do
      source = Fixtures.source_repo!()
      {:ok, _} = Repos.add(config, Fixtures.repo_url(source), name: name)
    end

    {_, 0} = cli(["project", "new", "vemags", "--repo", "api", "--repo", "web"])
    {_, 0} = cli(["co", "vemags@main", "--topic", "dev", "--label", "one", "--json"])

    {:ok, config: config}
  end

  test "prints bash, zsh and fish scripts" do
    {bash, 0} = cli(["completion", "bash"])
    assert bash =~ "complete -o nospace"
    assert bash =~ "gitspace __complete"
    assert bash =~ "gsp"
    assert bash =~ "cksum"

    {zsh, 0} = cli(["completion", "zsh"])
    assert zsh =~ "#compdef gitspace gsp"
    assert zsh =~ "compadd"
    assert zsh =~ "cksum"

    {fish, 0} = cli(["completion", "fish"])
    assert fish =~ "complete -c gitspace"
    assert fish =~ "__complete"
    assert fish =~ "cksum"
  end

  test "completes commands, subcommands and flags" do
    {commands, 0} = cli(["__complete", "0", ""])
    assert "co" in lines(commands)
    assert "project" in lines(commands)
    assert "completion" in lines(commands)

    {subcommands, 0} = cli(["__complete", "1", "project", ""])
    assert "show" in lines(subcommands)
    assert "add" in lines(subcommands)

    {flags, 0} = cli(["__complete", "1", "co", "--as-i"])
    assert lines(flags) == ["--as-is"]
  end

  test "completes dynamic projects, workspaces and members" do
    {projects, 0} = cli(["__complete", "1", "co", ""])
    assert "vemags" in lines(projects)

    {workspaces, 0} = cli(["__complete", "1", "status", ""])
    assert "vemags@dev" in lines(workspaces)

    {members, 0} = cli(["__complete", "3", "co", "vemags", "--only", ""])
    assert lines(members) == ["api", "web"]

    {any_members, 0} = cli(["__complete", "2", "co", "--only", ""])
    assert "api" in lines(any_members)
    assert "web" in lines(any_members)

    {subcommands, 0} = cli(["__complete", "1", "workspace", ""])
    assert "rm" in lines(subcommands)

    {targets, 0} = cli(["__complete", "2", "workspace", "rm", ""])
    assert "vemags@dev" in lines(targets)
    assert "vemags@dev:api" in lines(targets)

    {repos, 0} = cli(["__complete", "3", "project", "add", "vemags", ""])
    assert "api" in lines(repos)
    assert "web" in lines(repos)

    {top, 0} = cli(["__complete", "0", ""])
    assert "base" in lines(top)

    {base_flags, 0} = cli(["__complete", "1", "base", "--c"])
    assert lines(base_flags) == ["--clear"]

    {repo_commands, 0} = cli(["__complete", "1", "repo", ""])
    assert "set-url" in lines(repo_commands)

    {set_url_repos, 0} = cli(["__complete", "2", "repo", "set-url", ""])
    assert "api" in lines(set_url_repos)
    assert "web" in lines(set_url_repos)

    {set_url_flags, 0} = cli(["__complete", "3", "repo", "set-url", "api", "--p"])
    assert lines(set_url_flags) == ["--push"]
  end

  test "completes compound workspace targets segment by segment" do
    {path_topics, 0} = cli(["__complete", "1", "status", "vemags/"])
    assert lines(path_topics) == ["vemags/dev"]

    {path_members, 0} = cli(["__complete", "1", "status", "vemags/dev/"])
    assert "vemags/dev/api" in lines(path_members)
    assert "vemags/dev/web" in lines(path_members)

    {path_partial, 0} = cli(["__complete", "1", "status", "vemags/dev/a"])
    assert lines(path_partial) == ["vemags/dev/api"]

    {workspace, 0} = cli(["__complete", "1", "status", "vemags@"])
    assert lines(workspace) == ["vemags@dev"]

    {handles, 0} = cli(["__complete", "1", "status", "vemags@dev:"])
    assert "vemags@dev:api" in lines(handles)
    assert "vemags@dev:web" in lines(handles)

    {at_path_members, 0} = cli(["__complete", "1", "status", "vemags@dev/"])
    assert "vemags@dev/api" in lines(at_path_members)

    {workspace_command, 0} = cli(["__complete", "2", "workspace", "status", "vemags@"])
    assert lines(workspace_command) == ["vemags@dev"]
  end

  test "completes filters, prefixed targets and workspace new" do
    {workspaces, 0} = cli(["__complete", "2", "ls", "--workspace", ""])
    assert lines(workspaces) == ["vemags@dev"]

    {labels, 0} = cli(["__complete", "2", "ls", "--label", ""])
    assert lines(labels) == ["one"]

    {repos, 0} = cli(["__complete", "1", "status", "repo:"])
    assert lines(repos) == ["repo:api", "repo:web"]

    {repos_partial, 0} = cli(["__complete", "1", "status", "repo:a"])
    assert lines(repos_partial) == ["repo:api"]

    {projects, 0} = cli(["__complete", "1", "status", "project:"])
    assert lines(projects) == ["project:vemags"]

    {new_projects, 0} = cli(["__complete", "2", "workspace", "new", ""])
    assert lines(new_projects) == ["vemags"]
  end

  test "completes log targets, detail flags and the commit limit key" do
    {targets, 0} = cli(["__complete", "1", "log", ""])
    assert "vemags@dev" in lines(targets)

    {outgoing, 0} = cli(["__complete", "1", "log", "--o"])
    assert lines(outgoing) == ["--outgoing"]

    {long, 0} = cli(["__complete", "1", "status", "--l"])
    assert lines(long) == ["--long"]

    {push_targets, 0} = cli(["__complete", "1", "push", ""])
    assert "vemags@dev" in lines(push_targets)

    {dry_run, 0} = cli(["__complete", "1", "push", "--d"])
    assert lines(dry_run) == ["--dry-run"]

    {rebase_targets, 0} = cli(["__complete", "1", "rebase", ""])
    assert "vemags@dev" in lines(rebase_targets)

    {continue, 0} = cli(["__complete", "1", "rebase", "--c"])
    assert lines(continue) == ["--continue"]

    {keep_subcommands, 0} = cli(["__complete", "1", "keep", ""])
    assert "prune" in lines(keep_subcommands)

    {older_than, 0} = cli(["__complete", "2", "keep", "prune", "--o"])
    assert lines(older_than) == ["--older-than"]

    {keys, 0} = cli(["__complete", "2", "config", "get", ""])
    assert "log.max_commits" in lines(keys)
  end

  test "completes config keys and shell names" do
    {keys, 0} = cli(["__complete", "2", "config", "get", ""])
    assert "projects.root" in lines(keys)

    {shells, 0} = cli(["__complete", "1", "completion", ""])
    assert lines(shells) == ["bash", "fish", "zsh"]
  end

  test "snapshots data-backed candidates in a cache", %{config: config} do
    {_, 0} = cli(["__complete", "1", "co", ""])

    payload =
      config.path
      |> Kernel.<>(".complete.json")
      |> File.read!()
      |> Jason.decode!()

    assert payload["version"] == 3
    assert payload["app"] == to_string(Application.spec(:gitspace, :vsn))
    assert payload["lists"]["projects"] == ["vemags"]
    assert "vemags@dev" in payload["lists"]["targets"]
    assert payload["lists"]["members"]["vemags"] == ["api", "web"]
    assert payload["lists"]["workspace_names"] == ["vemags@dev"]
    assert payload["lists"]["labels"] == ["one"]

    # A cache hit must not start the index or parse the config again.
    Gitspace.Index.stop()

    {output, 0} = cli(["__complete", "1", "co", ""])
    assert "vemags" in lines(output)
    refute Gitspace.Index.started?()
  end

  test "a corrupt cache falls back to the index", %{config: config} do
    {_, 0} = cli(["__complete", "1", "co", ""])
    File.write!(config.path <> ".complete.json", "not json")

    {output, 0} = cli(["__complete", "1", "co", ""])
    assert "vemags" in lines(output)
    assert Jason.decode!(File.read!(config.path <> ".complete.json"))["version"] == 3
  end

  test "mutations invalidate the cache, reads do not", %{config: config} do
    stamp = config.path <> ".stamp"
    {_, 0} = cli(["__complete", "1", "co", ""])
    first = File.read!(stamp)

    {_, 0} = cli(["ls", "--json"])
    assert File.read!(stamp) == first

    {_, 0} = cli(["project", "new", "other", "--repo", "api", "--json"])
    refute File.read!(stamp) == first

    {output, 0} = cli(["__complete", "1", "co", ""])
    assert "other" in lines(output)
  end

  defp lines(output) do
    output |> String.split("\n", trim: true) |> Enum.map(&String.trim/1)
  end

  defp cli(args) do
    {code, output} = ExUnit.CaptureIO.with_io(fn -> Gitspace.CLI.run(args) end)
    {output, code}
  end
end
