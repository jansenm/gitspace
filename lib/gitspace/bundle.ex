defmodule Gitspace.Bundle do
  @moduledoc """
  Portable export and import of projects and repositories.

  A bundle contains project definitions and the remote-backed repositories they
  reference. It deliberately excludes workspaces, checkouts, labels, absolute
  paths and credentials. Local repositories have no portable upstream and are
  skipped; a project that references one is imported without that member and
  reported as partial.

  Import is additive and idempotent: existing repositories with the same
  identity are reused, existing projects gain missing members, and nothing is
  overwritten.
  """

  alias Gitspace.{Config, Error, Layout, Projects, Repo, Repos}
  alias Gitspace.Index.Repository

  @schema_version 1
  @app "gitspace"

  @spec export(Config.t()) :: map()
  def export(%Config{} = config) do
    {repos, skipped_repos} = export_repos(config)
    {projects, skipped_projects} = export_projects(config)

    %{
      "schema_version" => @schema_version,
      "app" => @app,
      "exported_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "projects" => projects,
      "repos" => repos,
      "skipped" => Enum.sort_by(skipped_repos ++ skipped_projects, &(&1["alias"] || &1["name"]))
    }
  end

  @spec import_bundle(Config.t(), map(), keyword()) ::
          {:ok, map()} | {:partial, map(), [String.t()]} | {:error, Error.t()}
  def import_bundle(%Config{} = config, data, opts \\ []) do
    with :ok <- validate(data),
         {:ok, repos} <- plan_repos(config, data["repos"] || []),
         {:ok, projects, warnings} <- plan_projects(config, data["projects"] || [], repos) do
      warnings =
        Enum.map(
          Enum.filter(repos.entries, &(&1.action == :conflict)),
          &"repository #{&1.alias} already exists with a different identity"
        ) ++ warnings

      plan = %{repos: repos, projects: projects, warnings: warnings}

      if opts[:dry_run] do
        {:ok, summary(plan, true)}
      else
        execute(config, plan, opts)
      end
    end
  end

  defp export_repos(config) do
    {repos, skipped} =
      config
      |> Repos.list()
      |> Enum.reduce({[], []}, fn %{repo: repo}, {repos, skipped} ->
        cond do
          repo.origin_kind == "local" ->
            {repos, [skip(repo.slug, "local repository without an upstream") | skipped]}

          repo.state != "managed" or is_nil(repo.bare_path) ->
            {repos, [skip(repo.slug, "not a managed mirror") | skipped]}

          not is_binary(repo.remote_url) or repo.remote_url == "" ->
            {repos, [skip(repo.slug, "no remote URL") | skipped]}

          not is_binary(repo.remote_key) or repo.remote_key == "" ->
            {repos, [skip(repo.slug, "no repository identity") | skipped]}

          true ->
            {url, redacted?} = redact_url(repo.remote_url)

            entry = %{
              "alias" => repo.slug,
              "origin_kind" => repo.origin_kind,
              "remote_url" => url,
              "remote_key" => repo.remote_key,
              "default_branch" => repo.default_branch,
              "credentials_removed" => redacted?
            }

            {[entry | repos], skipped}
        end
      end)

    {Enum.sort_by(repos, & &1["alias"]), skipped}
  end

  defp export_projects(config) do
    {projects, skipped} =
      config
      |> Projects.list()
      |> Enum.reduce({[], []}, fn project, {projects, skipped} ->
        {members, missing} =
          Enum.reduce(project.members, {[], []}, fn key, {members, missing} ->
            case Repo.get_by(Repository, remote_key: key) do
              %Repository{slug: slug} -> {[slug | members], missing}
              nil -> {members, [key | missing]}
            end
          end)

        entry = %{
          "name" => project.name,
          "description" => project.description,
          "branch_template" => project.branch_template,
          "default_ref" => project.default_ref,
          "members" => Enum.sort(members)
        }

        entry =
          if missing == [] do
            entry
          else
            Map.put(entry, "missing_members", Enum.sort(missing))
          end

        skipped =
          Enum.reduce(missing, skipped, fn key, acc ->
            [%{"project" => project.name, "member" => key} | acc]
          end)

        {[entry | projects], skipped}
      end)

    {Enum.sort_by(projects, & &1["name"]), skipped}
  end

  defp skip(alias_name, reason), do: %{"alias" => alias_name, "reason" => reason}

  defp redact_url(url) do
    redacted = Regex.replace(~r{://[^/@]+@}, url, "://")
    {redacted, redacted != url}
  end

  defp validate(%{"app" => @app, "schema_version" => @schema_version} = data) do
    repos = Map.get(data, "repos", [])
    projects = Map.get(data, "projects", [])

    if is_list(repos) and is_list(projects) and Enum.all?(repos, &is_map/1) and
         Enum.all?(projects, &is_map/1) do
      :ok
    else
      {:error, Error.new(:invalid_config, "bundle repos and projects must be lists of objects")}
    end
  end

  defp validate(%{"app" => app}) when is_binary(app) and app != @app do
    {:error,
     Error.new(:invalid_config, "not a gitspace bundle: app is #{inspect(app)}",
       hint: "export the bundle with `gitspace config export`"
     )}
  end

  defp validate(%{"schema_version" => version}) when version != @schema_version do
    {:error,
     Error.new(:invalid_config, "unsupported bundle schema: #{inspect(version)}",
       hint: "this gitspace supports schema #{@schema_version}; upgrade gitspace"
     )}
  end

  defp validate(_data) do
    {:error,
     Error.new(:invalid_config, "not a gitspace bundle",
       hint: "expected app=gitspace and schema_version=#{@schema_version}"
     )}
  end

  defp plan_repos(config, entries) do
    Enum.reduce_while(entries, {:ok, %{entries: [], by_alias: %{}, seen: %{}}}, fn entry,
                                                                                   {:ok, acc} ->
      case plan_repo(config, entry, acc) do
        {:ok, acc} -> {:cont, {:ok, acc}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
    |> case do
      {:ok, acc} ->
        {:ok,
         %{
           entries: Enum.reverse(acc.entries),
           by_alias: acc.by_alias
         }}

      {:error, error} ->
        {:error, error}
    end
  end

  defp plan_repo(_config, %{"origin_kind" => "local"} = entry, acc) do
    alias_name = entry["alias"] || entry["remote_key"] || "local"
    {:ok, Map.update!(acc, :by_alias, &Map.put(&1, alias_name, :skipped))}
  end

  defp plan_repo(_config, entry, acc) do
    alias_name = entry["alias"]
    url = entry["remote_url"]

    with {:ok, alias_name} <- valid_alias(alias_name),
         :ok <- unique_alias(acc, alias_name, url),
         {:ok, key} <- bundle_key(entry, url),
         {:ok, target} <- resolve_target(alias_name, key, url) do
      if target.conflict do
        {:ok,
         Map.update!(
           acc,
           :entries,
           &[
             %{
               alias: alias_name,
               actual_alias: target.alias,
               key: key,
               url: url,
               action: :conflict,
               existing: target.existing
             }
             | &1
           ]
         )}
      else
        actual_alias = target.alias
        action = if target.existing, do: :exists, else: :create

        repo_entry = %{
          alias: alias_name,
          actual_alias: actual_alias,
          key: key,
          url: url,
          action: action,
          existing: target.existing
        }

        {:ok,
         acc
         |> Map.update!(:entries, &[repo_entry | &1])
         |> Map.update!(:by_alias, &Map.put(&1, alias_name, repo_entry))
         |> Map.update!(:seen, &Map.put(&1, alias_name, url))}
      end
    end
  end

  defp valid_alias(alias_name) when is_binary(alias_name) do
    case Layout.repo_slug(alias_name) do
      {:ok, _} ->
        {:ok, alias_name}

      {:error, _} ->
        {:error, Error.new(:invalid_config, "invalid repository alias: #{alias_name}")}
    end
  end

  defp valid_alias(_), do: {:error, Error.new(:invalid_config, "repository entry has no alias")}

  defp unique_alias(acc, alias_name, url) do
    case Map.fetch(acc.seen, alias_name) do
      :error ->
        :ok

      {:ok, ^url} ->
        :ok

      {:ok, _other} ->
        {:error, Error.new(:conflict, "duplicate repository alias in bundle: #{alias_name}")}
    end
  end

  defp bundle_key(entry, url) do
    case entry["remote_key"] do
      key when is_binary(key) and key != "" ->
        {:ok, key}

      _ ->
        if is_binary(url) and url != "" do
          {:ok, Layout.normalize_remote(url)}
        else
          {:error,
           Error.new(:invalid_config, "repository #{entry["alias"]} has no remote_url",
             hint: "local repositories cannot be imported from a bundle"
           )}
        end
    end
  end

  defp resolve_target(alias_name, key, url) do
    existing =
      Repo.get_by(Repository, remote_key: key) ||
        existing_by_url(url) ||
        Repo.get_by(Repository, slug: alias_name)

    cond do
      existing && existing.remote_key == key ->
        {:ok, %{existing: existing, alias: existing.slug, action: :exists, conflict: false}}

      existing && is_binary(url) && existing.remote_url == url ->
        {:ok, %{existing: existing, alias: existing.slug, action: :exists, conflict: false}}

      existing ->
        {:ok, %{existing: existing, alias: existing.slug, action: :exists, conflict: true}}

      true ->
        {:ok, %{existing: nil, alias: alias_name, action: :create, conflict: false}}
    end
  end

  defp existing_by_url(nil), do: nil
  defp existing_by_url(""), do: nil
  defp existing_by_url(url), do: Repo.get_by(Repository, remote_url: url)

  defp plan_projects(config, entries, repos) do
    Enum.reduce_while(entries, {:ok, [], []}, fn entry, {:ok, projects, warnings} ->
      case plan_project(config, entry, repos) do
        {:ok, project, project_warnings} ->
          {:cont, {:ok, [project | projects], warnings ++ project_warnings}}

        {:error, error} ->
          {:halt, {:error, error}}
      end
    end)
    |> case do
      {:ok, projects, warnings} -> {:ok, Enum.reverse(projects), warnings}
      {:error, error} -> {:error, error}
    end
  end

  defp plan_project(config, entry, repos) do
    name = entry["name"]
    members = entry["members"] || []

    cond do
      not is_binary(name) or name == "" ->
        {:error, Error.new(:invalid_config, "project entry has no name")}

      match?({:ok, _}, Projects.get(config, name)) ->
        {:ok, %{name: name, action: :exists, members: [], attrs: %{}}, []}

      true ->
        with {:ok, members, warnings} <- resolve_members(name, members, repos) do
          warnings =
            Enum.map(
              List.wrap(entry["missing_members"]),
              &"#{name}: repository #{&1} was not exported"
            ) ++ warnings

          attrs = %{
            description: entry["description"],
            branch_template: entry["branch_template"],
            default_ref: entry["default_ref"]
          }

          {:ok,
           %{
             name: name,
             action: :create,
             members: members,
             attrs: attrs
           }, warnings}
        end
    end
  end

  defp resolve_members(name, members, repos) do
    {resolved, warnings} =
      Enum.reduce(members, {[], []}, fn member, {resolved, warnings} ->
        case Map.fetch(repos.by_alias, member) do
          {:ok, :skipped} ->
            {resolved, ["#{name}: repository #{member} is local and was skipped" | warnings]}

          {:ok, %{actual_alias: actual}} ->
            {[actual | resolved], warnings}

          :error ->
            case Repo.get_by(Repository, slug: member) do
              %Repository{} ->
                {[member | resolved], warnings}

              nil ->
                {resolved, ["#{name}: repository #{member} is missing" | warnings]}
            end
        end
      end)

    {:ok, resolved |> Enum.uniq() |> Enum.sort(), Enum.reverse(warnings)}
  end

  defp execute(config, plan, opts) do
    with {:ok, created} <- create_repos(config, plan.repos, opts) do
      case create_projects(config, plan.projects) do
        :ok ->
          summary = summary(plan, false) |> Map.put(:created_repos, created)

          if plan.warnings == [] do
            {:ok, summary}
          else
            {:partial, summary, plan.warnings}
          end

        {:error, error} ->
          {:error, error}
      end
    end
  end

  defp create_repos(config, repos, opts) do
    Enum.reduce_while(repos.entries, {:ok, []}, fn entry, {:ok, created} ->
      if entry.action == :create do
        case Repos.add(config, entry.url, name: entry.alias, no_fetch: !!opts[:no_fetch]) do
          {:ok, repo} ->
            {:cont, {:ok, [repo.slug | created]}}

          {:error, error} ->
            {:halt,
             {:error,
              Error.new(error.code, error.message,
                hint: error.hint,
                details:
                  Map.merge(error.details, %{
                    failed_repo: entry.alias,
                    created_repos: Enum.reverse(created)
                  })
              )}}
        end
      else
        {:cont, {:ok, created}}
      end
    end)
    |> case do
      {:ok, created} -> {:ok, Enum.reverse(created)}
      {:error, error} -> {:error, error}
    end
  end

  defp create_projects(config, projects) do
    Enum.reduce_while(projects, :ok, fn project, :ok ->
      if project.action == :create do
        case Projects.create(config, project.name, project_opts(project)) do
          {:ok, _} -> {:cont, :ok}
          {:error, error} -> {:halt, {:error, error}}
        end
      else
        {:cont, :ok}
      end
    end)
  end

  defp project_opts(project) do
    [
      repo: project.members,
      description: project.attrs.description,
      branch_template: project.attrs.branch_template,
      default_ref: project.attrs.default_ref
    ]
  end

  defp summary(plan, dry_run?) do
    %{
      dry_run: dry_run?,
      repos:
        Enum.map(plan.repos.entries, fn entry ->
          %{alias: entry.actual_alias, action: entry.action}
        end),
      projects:
        Enum.map(plan.projects, fn project ->
          %{name: project.name, action: project.action, members: project.members}
        end),
      warnings: plan.warnings
    }
  end
end
