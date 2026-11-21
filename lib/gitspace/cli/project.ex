defmodule Gitspace.CLI.Project do
  @moduledoc false

  alias Gitspace.{Error, Projects, Repo, Workspaces}
  alias Gitspace.CLI.{Helpers, Output}

  def run(global, args) do
    case args do
      ["new" | rest] -> new(global, rest)
      ["ls" | rest] -> list(global, rest)
      ["show" | rest] -> show(global, rest)
      ["add" | rest] -> add(global, rest)
      ["remove" | rest] -> remove(global, rest)
      ["rm" | rest] -> rm(global, rest)
      [] -> {:ok, %{help: help()}, &render_help/1}
      ["help"] -> {:ok, %{help: help()}, &render_help/1}
      [other | _] -> {:error, Error.new(:usage, "unknown project command: #{other}")}
    end
  end

  defp new(_global, args) do
    with {:ok, opts, rest} <- Helpers.parse(args, new_strict()),
         {:ok, name} <- one_arg(rest, "gitspace project new <name>"),
         {:ok, config} <- Helpers.load_config(),
         :ok <- Helpers.start_index(config),
         {:ok, project} <-
           Projects.create(config, name,
             repo: Keyword.get_values(opts, :repo),
             path: opts[:at],
             description: opts[:description],
             branch_template: opts[:branch_template],
             default_ref: opts[:default_ref]
           ) do
      {:ok, project_map(config, project), &render_show/1}
    end
  end

  defp new_strict do
    [
      repo: :keep,
      at: :string,
      description: :string,
      branch_template: :string,
      default_ref: :string
    ] ++ Helpers.global_strict()
  end

  defp list(_global, args) do
    with {:ok, _opts, rest} <- Helpers.parse(args, Helpers.global_strict()),
         :ok <- Helpers.no_extra_args(rest),
         {:ok, config} <- Helpers.load_config(),
         :ok <- Helpers.start_index(config) do
      workspaces = Workspaces.list(config)

      projects =
        config
        |> Projects.list()
        |> Enum.map(fn project ->
          %{
            name: project.name,
            path: project.path,
            members: length(project.members),
            workspaces: count_workspaces(workspaces, project),
            source: project.source,
            description: project.description
          }
        end)

      {:ok, %{projects: projects}, &render_list/1}
    end
  end

  defp show(_global, args) do
    with {:ok, _opts, rest} <- Helpers.parse(args, Helpers.global_strict()),
         {:ok, name} <- one_arg(rest, "gitspace project show <name>"),
         {:ok, config} <- Helpers.load_config(),
         :ok <- Helpers.start_index(config),
         {:ok, project} <- Projects.get(config, name) do
      {:ok, project_map(config, project), &render_show/1}
    end
  end

  defp add(_global, args) do
    with {:ok, _opts, rest} <- Helpers.parse(args, Helpers.global_strict()),
         {:ok, name, repos} <- name_and_repos(rest, "gitspace project add <name> <repo>..."),
         {:ok, config} <- Helpers.load_config(),
         :ok <- Helpers.start_index(config),
         {:ok, project} <- Projects.add_members(config, name, repos) do
      {:ok, project_map(config, project), &render_changed/1}
    end
  end

  defp remove(_global, args) do
    with {:ok, _opts, rest} <- Helpers.parse(args, Helpers.global_strict()),
         {:ok, name, repos} <- name_and_repos(rest, "gitspace project remove <name> <repo>..."),
         {:ok, config} <- Helpers.load_config(),
         :ok <- Helpers.start_index(config),
         {:ok, project} <- Projects.remove_members(config, name, repos) do
      {:ok, project_map(config, project), &render_changed/1}
    end
  end

  defp rm(_global, args) do
    with {:ok, opts, rest} <- Helpers.parse(args, rm_strict()),
         {:ok, name} <- one_arg(rest, "gitspace project rm <name>"),
         {:ok, config} <- Helpers.load_config(),
         :ok <- Helpers.start_index(config),
         {:ok, project} <- Projects.get(config, name),
         :ok <- maybe_ensure_no_workspaces(config, project, opts[:force]),
         workspaces = Enum.count(Workspaces.list(config), &workspace_in_project?(&1, project)),
         :ok <- Projects.delete(config, project.name) do
      {:ok,
       %{
         project: project.name,
         path: project.path,
         workspaces_kept: workspaces,
         forced: !!opts[:force]
       }, &render_removed/1}
    end
  end

  defp rm_strict, do: [force: :boolean] ++ Helpers.global_strict()

  defp maybe_ensure_no_workspaces(_config, _project, true), do: :ok

  defp maybe_ensure_no_workspaces(config, project, _force),
    do: ensure_no_workspaces(config, project)

  defp ensure_no_workspaces(config, project) do
    case Enum.filter(Workspaces.list(config), &workspace_in_project?(&1, project)) do
      [] ->
        :ok

      workspaces ->
        names = Enum.map(workspaces, & &1.name)

        {:error,
         Error.new(:refused, "project #{project.name} still has workspaces",
           hint: "tear them down first: " <> Enum.join(names, ", "),
           details: %{workspaces: names}
         )}
    end
  end

  defp project_map(config, project) do
    workspaces = Enum.filter(Workspaces.list(config), &workspace_in_project?(&1, project))
    repos = Repo.all(Gitspace.Index.Repository) |> Map.new(&{&1.remote_key, &1})

    members =
      Enum.map(project.members, fn key ->
        case Map.get(repos, key) do
          nil ->
            %{remote_key: key, slug: nil, missing: true}

          repo ->
            %{remote_key: key, slug: repo.slug, remote_url: repo.remote_url, missing: false}
        end
      end)

    %{
      name: project.name,
      path: project.path,
      description: project.description,
      branch_template: project.branch_template,
      default_ref: project.default_ref,
      source: project.source,
      members: members,
      workspaces:
        Enum.map(workspaces, fn workspace ->
          %{name: workspace.name, marker_path: workspace.marker_path}
        end)
    }
  end

  defp workspace_in_project?(workspace, project) do
    workspace.name == project.name or String.starts_with?(workspace.name, project.name <> "/")
  end

  defp count_workspaces(workspaces, project) do
    Enum.count(workspaces, &workspace_in_project?(&1, project))
  end

  defp name_and_repos([name | repos], _usage) when name != "" and repos != [] do
    {:ok, name, repos}
  end

  defp name_and_repos(_rest, usage), do: {:error, Error.new(:usage, "usage: #{usage}")}

  defp one_arg([arg], _usage), do: {:ok, arg}
  defp one_arg(_rest, usage), do: {:error, Error.new(:usage, "usage: #{usage}")}

  defp render_list(%{projects: projects}) do
    Output.table(
      ["NAME", "MEMBERS", "WORKSPACES", "PATH"],
      Enum.map(projects, fn project ->
        [project.name, project.members, project.workspaces, project.path]
      end)
    )
  end

  defp render_show(project) do
    IO.puts("#{project.name}")
    IO.puts("  path:       #{project.path}")
    IO.puts("  source:     #{project.source}")

    if project.description do
      IO.puts("  description: #{project.description}")
    end

    if project.branch_template do
      IO.puts("  branch:     #{project.branch_template}")
    end

    if project.default_ref do
      IO.puts("  default:    #{project.default_ref}")
    end

    IO.puts("")

    Output.table(
      ["MEMBER", "REMOTE", "STATE"],
      Enum.map(project.members, fn member ->
        [
          member.slug || "-",
          member.remote_key,
          if(member.missing, do: "missing", else: "ok")
        ]
      end)
    )

    if project.workspaces != [] do
      IO.puts("")
      IO.puts("workspaces:")

      Enum.each(project.workspaces, fn workspace ->
        IO.puts("  #{workspace.name}")
      end)
    end
  end

  defp render_changed(project) do
    IO.puts("updated project #{project.name}")
    IO.puts("  path:    #{project.path}")
    IO.puts("  members: #{length(project.members)}")
  end

  defp render_removed(data) do
    IO.puts("removed project #{data.project}")
    IO.puts("  path: #{data.path} (directory kept)")

    if data.workspaces_kept > 0 do
      IO.puts(
        "  workspaces kept: #{data.workspaces_kept} (run `gitspace reindex` to report them as orphans)"
      )
    end
  end

  defp render_help(%{help: help}), do: IO.puts(help)

  @doc false
  def help do
    """
    USAGE
      gitspace project new <name> [--repo <alias>]... [--at <path>]
                                [--description D] [--branch-template T]
                                [--default-ref REF] [--json]
      gitspace project ls [--json]
      gitspace project show <name> [--json]
      gitspace project add <name> <repo>...
      gitspace project remove <name> <repo>...
      gitspace project rm <name> [--force] [--json]

    PATHS
      By default a project lives at projects.root/<name>. --at names the
      project directory itself; it is used verbatim and must end with <name>.

    MEMBERSHIP
      A project is a named set of registered repositories. `add` and `remove`
      change future checkouts only; existing workspaces are never moved.

    REMOVING
      `project rm` refuses while workspaces exist. `--force` removes only the
      definition and keeps every checkout directory in place.
    """
  end
end
