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
    {_, 0} = cli(["co", "vemags@main", "--topic", "dev", "--json"])

    {:ok, config: config}
  end

  test "prints bash, zsh and fish scripts" do
    {bash, 0} = cli(["completion", "bash"])
    assert bash =~ "complete -o nospace"
    assert bash =~ "gitspace __complete"
    assert bash =~ "gsp"

    {zsh, 0} = cli(["completion", "zsh"])
    assert zsh =~ "#compdef gitspace gsp"
    assert zsh =~ "compadd"

    {fish, 0} = cli(["completion", "fish"])
    assert fish =~ "complete -c gitspace"
    assert fish =~ "__complete"
  end

  test "completes commands, subcommands and flags" do
    {commands, 0} = cli(["__complete", "0", ""])
    assert "co" in lines(commands)
    assert "project" in lines(commands)
    assert "completion" in lines(commands)

    {subcommands, 0} = cli(["__complete", "1", "project", ""])
    assert "show" in lines(subcommands)
    assert "add" in lines(subcommands)

    {flags, 0} = cli(["__complete", "1", "co", "--new"])
    assert lines(flags) == ["--new-branch"]
  end

  test "completes dynamic projects, workspaces and members" do
    {projects, 0} = cli(["__complete", "1", "co", ""])
    assert "vemags" in lines(projects)

    {workspaces, 0} = cli(["__complete", "1", "status", ""])
    assert "vemags/dev" in lines(workspaces)

    {members, 0} = cli(["__complete", "3", "co", "vemags", "--only", ""])
    assert lines(members) == ["api", "web"]

    {subcommands, 0} = cli(["__complete", "1", "workspace", ""])
    assert "rm" in lines(subcommands)

    {targets, 0} = cli(["__complete", "2", "workspace", "rm", ""])
    assert "vemags/dev" in lines(targets)
    assert "vemags/dev:api" in lines(targets)

    {repos, 0} = cli(["__complete", "3", "project", "add", "vemags", ""])
    assert "api" in lines(repos)
    assert "web" in lines(repos)

    {repo_commands, 0} = cli(["__complete", "1", "repo", ""])
    assert "set-url" in lines(repo_commands)

    {set_url_repos, 0} = cli(["__complete", "2", "repo", "set-url", ""])
    assert "api" in lines(set_url_repos)
    assert "web" in lines(set_url_repos)

    {set_url_flags, 0} = cli(["__complete", "3", "repo", "set-url", "api", "--p"])
    assert lines(set_url_flags) == ["--push"]
  end

  test "completes config keys and shell names" do
    {keys, 0} = cli(["__complete", "2", "config", "get", ""])
    assert "projects.root" in lines(keys)

    {shells, 0} = cli(["__complete", "1", "completion", ""])
    assert lines(shells) == ["bash", "fish", "zsh"]
  end

  defp lines(output) do
    output |> String.split("\n", trim: true) |> Enum.map(&String.trim/1)
  end

  defp cli(args) do
    {code, output} = ExUnit.CaptureIO.with_io(fn -> Gitspace.CLI.run(args) end)
    {output, code}
  end
end
