defmodule Gitspace.Create do
  @moduledoc """
  Provisioning for `co` and `workspace new`.

  Creation is ensure-only: members that already match are reused, existing
  paths that do not match are conflicts, and nothing is ever removed. The marker
  is written after worktrees exist, so a partial run is recoverable and a re-run
  completes it.
  """

  alias Gitspace.{Checkouts, Config, Error, Layout, Marker, Projects, Repo, Repos, Workspaces}
  alias Gitspace.Git.{Mirror, Refs, Worktree}
  alias Gitspace.Index.Repository

  @type member ::
          %{
            repo: String.t(),
            ownership: String.t(),
            path: Path.t(),
            branch: String.t() | nil,
            detached: boolean(),
            ref: String.t() | nil,
            head: String.t() | nil,
            action: String.t()
          }

  @type result :: %{
          project: String.t(),
          topic: String.t(),
          workspace: String.t(),
          path: Path.t(),
          marker_path: Path.t(),
          created: boolean(),
          dry_run: boolean(),
          labels: [String.t()],
          description: String.t() | nil,
          members: [member()]
        }

  @spec co(Config.t(), String.t(), String.t() | nil, keyword()) ::
          {:ok, result()} | {:partial, result(), [map()]} | {:error, Error.t()}
  def co(%Config{} = config, target, ref, opts \\ []) do
    with :ok <- validate_co_ref(ref),
         :ok <- validate_co_branch(opts[:branch]),
         {:ok, project} <- resolve_project_target(config, target),
         {:ok, members} <- Projects.resolve_members(config, project),
         {:ok, selected} <- select_members(members, opts),
         {:ok, topic} <- co_topic(ref, opts),
         :ok <- validate_co_options(opts, topic),
         {:ok, branch_mode} <- co_branch_mode(opts, ref) do
      branch_mode = if is_nil(ref) and branch_mode == :ref, do: :default, else: branch_mode

      specs =
        Enum.map(selected, fn repo ->
          %{
            repo: repo,
            member_name: single_member_name(selected, opts),
            ownership: "owned",
            ref: ref,
            branch_mode: branch_mode
          }
        end)

      workspace_new(
        config,
        topic,
        specs,
        [],
        Keyword.merge(opts,
          project: project.name,
          project_path: project.path,
          topic: topic,
          created_by: "co"
        )
      )
    end
  end

  defp validate_co_ref(nil), do: :ok

  defp validate_co_ref(ref) do
    if Layout.valid_ref?(ref),
      do: :ok,
      else: {:error, Error.new(:usage, "invalid ref: #{ref}")}
  end

  defp validate_co_branch(nil), do: :ok
  defp validate_co_branch(branch), do: validate_branch(branch)

  defp resolve_project_target(config, target) do
    case Projects.get(config, target) do
      {:ok, project} ->
        {:ok, project}

      {:error, %Error{code: :not_found}} ->
        case Repos.get(config, target) do
          {:ok, repo} -> repo_project(config, repo)
          {:error, error} -> {:error, error}
        end

      {:error, error} ->
        {:error, error}
    end
  end

  # `co <repo>@<ref>` targets the repository, not every project it happens to
  # belong to. Reuse the repo's own one-repo project (including an implicit one
  # created under a previous alias), otherwise create the implicit project.
  defp repo_project(config, repo) do
    case Projects.get(config, repo.slug) do
      {:ok, project} ->
        {:ok, project}

      {:error, %Error{code: :not_found}} ->
        case implicit_one_repo_project(config, repo) do
          nil -> Projects.ensure_implicit(config, repo)
          project -> {:ok, project}
        end

      {:error, error} ->
        {:error, error}
    end
  end

  defp implicit_one_repo_project(config, repo) do
    Enum.find(Projects.list(config), fn project ->
      project.source == "implicit" and project.members == [repo.remote_key]
    end)
  end

  defp select_members(members, opts) do
    only = normalize_member_list(opts[:only])
    exclude = normalize_member_list(opts[:exclude])

    cond do
      only != [] and exclude != [] ->
        {:error, Error.new(:usage, "--only and --exclude are mutually exclusive")}

      members == [] ->
        {:error,
         Error.new(:usage, "project has no members", hint: "add one with `gitspace project add`")}

      only != [] ->
        selected = Enum.filter(members, &(&1.slug in only))
        unknown = only -- Enum.map(selected, & &1.slug)

        cond do
          unknown != [] ->
            {:error,
             Error.new(:usage, "not a project member: #{Enum.join(unknown, ", ")}",
               hint: "members: #{Enum.map_join(members, ", ", & &1.slug)}"
             )}

          selected == [] ->
            {:error, Error.new(:usage, "no members selected")}

          true ->
            {:ok, selected}
        end

      exclude != [] ->
        selected = Enum.reject(members, &(&1.slug in exclude))
        unknown = exclude -- Enum.map(members, & &1.slug)

        cond do
          unknown != [] ->
            {:error,
             Error.new(:usage, "not a project member: #{Enum.join(unknown, ", ")}",
               hint: "members: #{Enum.map_join(members, ", ", & &1.slug)}"
             )}

          selected == [] ->
            {:error, Error.new(:usage, "no members selected")}

          true ->
            {:ok, selected}
        end

      true ->
        {:ok, members}
    end
  end

  defp normalize_member_list(nil), do: []

  defp normalize_member_list(value) when is_binary(value) do
    value
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp normalize_member_list(values) when is_list(values) do
    values
    |> Enum.flat_map(&normalize_member_list/1)
    |> Enum.uniq()
  end

  defp single_member_name([_repo], opts), do: opts[:as]
  defp single_member_name(_members, _opts), do: nil

  defp co_topic(ref, opts) do
    cond do
      is_binary(opts[:name]) and not is_binary(opts[:topic]) ->
        normalize_topic(opts[:name])

      is_binary(opts[:topic]) ->
        normalize_topic(opts[:topic])

      is_binary(opts[:branch]) ->
        case Layout.work_slug(opts[:branch]) do
          {:ok, _} -> normalize_topic(opts[:branch])
          {:error, reason} -> {:error, Error.new(:usage, "invalid topic: #{reason}")}
        end

      is_binary(ref) ->
        case Layout.ref_slug(ref) do
          {:ok, slug} ->
            {:ok, slug}

          {:error, reason} ->
            {:error, Error.new(:usage, "cannot derive a topic from #{ref}: #{reason}")}
        end

      true ->
        {:error,
         Error.new(:usage, "--topic is required when no ref names the work",
           hint: "for example: gitspace co vemags --topic MT4711"
         )}
    end
  end

  defp normalize_topic(topic) do
    if Layout.valid_topic?(topic) do
      {:ok, String.trim(topic)}
    else
      {:error,
       Error.new(:usage, "invalid topic #{inspect(topic)}",
         hint: "use letters, digits, '.', '_', '-' and '/' between segments; '@' is reserved"
       )}
    end
  end

  defp co_branch_mode(opts, ref) do
    cond do
      opts[:detach] -> {:ok, :detach}
      is_binary(opts[:branch]) -> {:ok, {:create, opts[:branch]}}
      opts[:as_is] -> {:ok, if(is_nil(ref), do: :default, else: :ref)}
      explicit_topic?(opts) and is_binary(ref) -> {:ok, :derive}
      true -> {:ok, :ref}
    end
  end

  defp explicit_topic?(opts) do
    is_binary(opts[:topic]) or is_binary(opts[:name])
  end

  defp validate_co_options(opts, _topic) do
    cond do
      opts[:detach] == true and is_binary(opts[:branch]) ->
        {:error, Error.new(:usage, "--branch and --detach are mutually exclusive")}

      opts[:as_is] == true and is_binary(opts[:branch]) ->
        {:error, Error.new(:usage, "--branch and --as-is are mutually exclusive")}

      opts[:as_is] == true and opts[:detach] == true ->
        {:error, Error.new(:usage, "--as-is and --detach are mutually exclusive")}

      true ->
        :ok
    end
  end

  @spec workspace_new(Config.t(), String.t(), [map()], [map()], keyword()) ::
          {:ok, result()} | {:partial, result(), [map()]} | {:error, Error.t()}
  def workspace_new(%Config{} = config, name, owned_specs, borrowed_specs, opts \\ []) do
    with {:ok, project_name, raw_topic} <- split_target(name, opts),
         {:ok, topic} <- normalize_topic(raw_topic),
         {:ok, specs} <- resolve_specs(config, owned_specs, borrowed_specs),
         :ok <- validate_specs(specs, opts),
         {:ok, project} <- resolve_project(config, specs, project_name),
         {:ok, full_name, work_dir} <- workspace_location(config, project, topic),
         {:ok, existing} <- load_existing(config, work_dir, full_name),
         opts =
           Keyword.merge(opts,
             project: project.name,
             topic: topic,
             workspace: full_name,
             branch_template: project.branch_template,
             default_ref: project.default_ref
           ),
         {:ok, plans, failures} <- plan_all(config, full_name, work_dir, specs, existing, opts),
         :ok <- validate_plan_names(existing, plans) do
      if opts[:dry_run] do
        dry_run(config, full_name, work_dir, existing, plans, failures, opts)
      else
        execute(config, full_name, work_dir, existing, plans, failures, opts)
      end
    end
  end

  # `workspace new [project@]topic`; `co` passes the project separately and a
  # topic without a separator.
  defp split_target(name, opts) when is_binary(name) do
    name = String.trim(name)
    project = opts[:project]

    cond do
      is_binary(project) and String.contains?(name, "@") ->
        {:error,
         Error.new(:usage, "project given twice",
           hint: "use either project@topic or --project, not both"
         )}

      is_binary(project) ->
        {:ok, project, name}

      String.contains?(name, "@") ->
        case String.split(name, "@", parts: 2) do
          [project, topic] when project != "" and topic != "" ->
            if String.contains?(topic, "@") do
              {:error,
               Error.new(:usage, "target contains more than one '@': #{inspect(name)}",
                 hint: "@ separates project and topic and may appear once"
               )}
            else
              {:ok, project, topic}
            end

          _ ->
            {:error,
             Error.new(:usage, "invalid target: #{inspect(name)}", hint: "use project@topic")}
        end

      true ->
        {:ok, nil, name}
    end
  end

  defp split_target(_name, _opts) do
    {:error, Error.new(:usage, "workspace target is required")}
  end

  defp resolve_project(config, specs, project_name) do
    cond do
      is_binary(project_name) ->
        named_project(config, project_name)

      specs == [] ->
        {:error, Error.new(:usage, "at least one member is required")}

      true ->
        inferred_project(config, hd(specs).repo)
    end
  end

  defp named_project(config, name) do
    case Projects.get(config, name) do
      {:ok, project} ->
        {:ok, project}

      {:error, %Error{code: :not_found}} ->
        case Repos.get(config, name) do
          {:ok, repo} ->
            repo_project(config, repo)

          {:error, _} ->
            {:error,
             Error.new(:not_found, "project not found: #{name}",
               hint: "create it with `gitspace project new #{name}` or use project@topic"
             )}
        end

      {:error, error} ->
        {:error, error}
    end
  end

  defp inferred_project(config, repo) do
    case Projects.projects_for_repo(config, repo) do
      [name | _] -> Projects.get(config, name)
      [] -> Projects.ensure_implicit(config, repo)
    end
  end

  defp workspace_location(_config, project, topic) do
    with {:ok, slug} <- Layout.work_slug(topic) do
      root = Path.expand(project.path)
      dir = Path.expand(Path.join(root, slug))
      full_name = "#{project.name}@#{topic}"

      cond do
        dir == root ->
          {:error, Error.new(:refused, "workspace path must be below the project path")}

        not String.starts_with?(dir, root <> "/") ->
          {:error, Error.new(:refused, "workspace path escapes the project path")}

        true ->
          {:ok, full_name, dir}
      end
    end
  end

  defp resolve_specs(config, owned_specs, borrowed_specs) do
    specs =
      Enum.map(owned_specs, &Map.put(&1, :ownership, "owned")) ++
        Enum.map(borrowed_specs, &Map.put(&1, :ownership, "borrowed"))

    Enum.reduce_while(specs, {:ok, []}, fn spec, {:ok, acc} ->
      with {:ok, repo} <- resolve_repo(config, spec.repo),
           :ok <- validate_spec_repo(spec, repo),
           :ok <- ensure_unique(acc, repo) do
        {:cont, {:ok, acc ++ [%{spec | repo: repo}]}}
      else
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp validate_spec_repo(%{ownership: "owned"}, repo) do
    cond do
      repo.state == "external" ->
        {:error,
         Error.new(:refused, "cannot create a worktree for external repository #{repo.slug}",
           hint: "register its remote with `gitspace repo add <url> --name #{repo.slug}`"
         )}

      is_nil(repo.bare_path) or not File.dir?(repo.bare_path) ->
        {:error,
         Error.new(:refused, "mirror for #{repo.slug} is missing",
           hint: "run `gitspace repo add <url> --name #{repo.slug}` again"
         )}

      true ->
        :ok
    end
  end

  defp validate_spec_repo(_spec, _repo), do: :ok

  defp ensure_unique(acc, repo) do
    if Enum.any?(acc, &(&1.repo.slug == repo.slug)) do
      {:error, Error.new(:usage, "duplicate repository in workspace: #{repo.slug}")}
    else
      :ok
    end
  end

  defp validate_specs(specs, opts) do
    borrowed? = Enum.any?(specs, &(&1.ownership == "borrowed"))
    branch = opts[:branch]

    cond do
      borrowed? and is_binary(branch) ->
        {:error, Error.new(:usage, "--branch cannot be combined with --borrow")}

      opts[:as_is] == true and is_binary(branch) ->
        {:error, Error.new(:usage, "--branch and --as-is are mutually exclusive")}

      is_binary(branch) and not Layout.valid_branch?(branch) ->
        {:error, Error.new(:usage, "invalid branch: #{branch}")}

      true ->
        Enum.reduce_while(specs, :ok, fn spec, :ok ->
          with :ok <- validate_member_name(spec[:member_name]),
               :ok <- validate_spec(spec) do
            {:cont, :ok}
          else
            {:error, error} -> {:halt, {:error, error}}
          end
        end)
    end
  end

  defp validate_member_name(nil), do: :ok

  defp validate_member_name(name) do
    case Layout.repo_slug(name) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        {:error, Error.new(:usage, "invalid member name #{inspect(name)}: #{reason}")}
    end
  end

  defp validate_spec(%{ownership: "borrowed"} = spec) do
    cond do
      spec.ref && not Layout.valid_ref?(spec.ref) ->
        {:error, Error.new(:usage, "invalid ref: #{spec.ref}")}

      true ->
        :ok
    end
  end

  defp validate_spec(spec) do
    cond do
      spec.ref && not Layout.valid_ref?(spec.ref) ->
        {:error, Error.new(:usage, "invalid ref: #{spec.ref}")}

      match?({:create, _}, spec.branch_mode) ->
        {:create, branch} = spec.branch_mode

        if Layout.valid_branch?(branch) do
          :ok
        else
          {:error, Error.new(:usage, "invalid branch: #{branch}")}
        end

      spec.branch_mode == :ref and is_nil(spec.ref) ->
        {:error, Error.new(:usage, "a ref is required for a direct checkout")}

      spec.branch_mode == :detach and is_nil(spec.ref) ->
        {:error, Error.new(:usage, "a ref is required for a detached checkout")}

      true ->
        :ok
    end
  end

  defp resolve_repo(_config, %Repository{} = repo), do: {:ok, repo}

  defp resolve_repo(config, selector) do
    case Repos.get(config, selector) do
      {:ok, repo} ->
        {:ok, repo}

      {:error, %Error{code: :not_found} = error} ->
        {:error, missing_repo_error(selector, error)}

      {:error, %Error{} = error} ->
        {:error, error}
    end
  end

  defp missing_repo_error(selector, error) do
    %{error | hint: "register it with `gitspace repo add <url> --name #{selector}`"}
  end

  defp load_existing(config, work_dir, name) do
    marker_path = Path.join(work_dir, Marker.marker_filename())
    database = database_workspace(config, name)

    cond do
      File.exists?(marker_path) ->
        case Marker.read(work_dir) do
          {:ok, marker} ->
            if marker["workspace"] == name do
              {:ok, existing_from_marker(marker)}
            else
              {:error,
               Error.new(
                 :conflict,
                 "workspace directory already belongs to #{marker["workspace"]}",
                 hint: "choose another topic name",
                 details: %{path: work_dir, existing: marker["workspace"]}
               )}
            end

          {:error, reason} ->
            {:error,
             Error.new(:conflict, "invalid workspace marker at #{marker_path}",
               hint:
                 "run `gitspace doctor --reindex` or remove the directory after inspecting it",
               details: %{reason: inspect(reason)}
             )}
        end

      database ->
        {:ok, existing_from_database(work_dir, database)}

      File.exists?(work_dir) and not File.dir?(work_dir) ->
        {:error,
         Error.new(:conflict, "workspace path exists and is not a directory: #{work_dir}")}

      File.dir?(work_dir) and not empty_dir?(work_dir) ->
        {:error,
         Error.new(:conflict, "workspace directory is not empty and has no marker",
           hint: "move it aside or choose another name",
           details: %{path: work_dir}
         )}

      true ->
        {:ok, empty_existing()}
    end
  end

  defp database_workspace(config, name) do
    case Workspaces.get(config, name) do
      {:ok, workspace} -> workspace
      {:error, _} -> nil
    end
  end

  defp existing_from_marker(marker) do
    %{
      exists?: true,
      members: marker["members"] || [],
      labels: List.wrap(marker["labels"]),
      description: marker["description"],
      created_at: marker["created_at"]
    }
  end

  defp existing_from_database(work_dir, workspace) do
    members =
      Enum.map(workspace.members, fn member ->
        checkout = member.checkout
        repo = checkout.repository

        base = %{
          "repo" => repo.slug,
          "remote" => repo.remote_key,
          "name" => member.name,
          "ownership" => member.ownership,
          "branch" => checkout.branch,
          "ref" => checkout.branch || checkout.head_sha,
          "head" => checkout.head_sha,
          "role" => member.role
        }

        case member.ownership do
          "owned" ->
            Map.put(base, "rel_path", Path.relative_to(checkout.path, work_dir))

          "borrowed" ->
            Map.put(base, "path", checkout.path)
        end
      end)

    %{
      exists?: true,
      members: members,
      labels: Enum.map(workspace.labels, & &1.label),
      description: workspace.description,
      created_at: workspace.inserted_at && DateTime.to_iso8601(workspace.inserted_at)
    }
  end

  defp empty_existing do
    %{exists?: false, members: [], labels: [], description: nil, created_at: nil}
  end

  defp empty_dir?(dir) do
    case File.ls(dir) do
      {:ok, entries} -> entries == []
      {:error, _} -> false
    end
  end

  defp plan_all(config, name, work_dir, specs, existing, opts) do
    {plans, failures} =
      Enum.reduce(specs, {[], []}, fn spec, {plans, failures} ->
        case plan_member(config, name, work_dir, spec, existing, opts) do
          {:ok, plan} -> {[plan | plans], failures}
          {:skip, _member} -> {plans, failures}
          {:error, error} -> {plans, [failure(spec, error) | failures]}
        end
      end)

    {:ok, Enum.reverse(plans), Enum.reverse(failures)}
  end

  defp failure(subject, error) do
    repo =
      case subject[:repo] do
        %Repository{slug: slug} -> slug
        slug when is_binary(slug) -> slug
        _ -> "workspace"
      end

    %{
      repo: repo,
      ownership: subject[:ownership],
      ref: subject[:ref],
      code: error.code,
      reason: error.message,
      hint: error.hint,
      error: error
    }
  end

  defp plan_member(config, name, work_dir, spec, existing, opts) do
    case find_member(existing, spec.repo) do
      nil ->
        plan_new_member(config, name, work_dir, spec, opts)

      member ->
        if member_checkout_present?(member, work_dir) do
          skip_existing_member(member, spec)
        else
          plan_new_member(config, name, work_dir, spec, opts)
        end
    end
  end

  defp member_checkout_present?(%{"ownership" => "owned"} = member, work_dir) do
    relative = member["rel_path"] || member["name"] || member["repo"]
    is_binary(relative) and File.dir?(Path.join(work_dir, relative))
  end

  defp member_checkout_present?(%{"ownership" => "borrowed", "path" => path}, _work_dir) do
    is_binary(path) and File.dir?(path)
  end

  defp member_checkout_present?(_member, _work_dir), do: false

  defp skip_existing_member(member, spec) do
    with :ok <- ownership_matches(member, spec.ownership),
         :ok <- existing_member_name_matches(member, spec[:member_name]) do
      {:skip, member}
    end
  end

  defp plan_new_member(config, name, work_dir, %{ownership: "owned"} = spec, opts) do
    plan_owned(config, name, work_dir, spec, nil, opts)
  end

  defp plan_new_member(config, _name, _work_dir, %{ownership: "borrowed"} = spec, _opts) do
    plan_borrowed(config, spec, nil)
  end

  defp validate_plan_names(existing, plans) do
    existing_names =
      existing.members
      |> Enum.reject(fn member ->
        Enum.any?(plans, fn plan -> member_matches_repo?(member, plan.repo) end)
      end)
      |> Enum.map(&marker_name/1)

    names = existing_names ++ Enum.map(plans, & &1.name)

    duplicates =
      names
      |> Enum.frequencies()
      |> Enum.filter(fn {_name, count} -> count > 1 end)

    case duplicates do
      [] ->
        :ok

      [{name, _} | _] ->
        {:error,
         Error.new(:conflict, "member name is used more than once: #{name}",
           hint: "choose a different --as name for one of the members"
         )}
    end
  end

  defp find_member(existing, %Repository{} = repo) do
    Enum.find(existing.members, &member_matches_repo?(&1, repo))
  end

  defp member_matches_repo?(member, %Repository{} = repo),
    do: member_matches_key?(member, repo.remote_key, repo.slug)

  defp member_matches_repo?(member, %{repo: slug, remote: remote}),
    do: member_matches_key?(member, remote, slug)

  defp member_matches_key?(member, remote_key, slug) do
    if is_binary(member["remote"]) do
      member["remote"] == remote_key
    else
      member["repo"] == slug
    end
  end

  defp plan_owned(config, name, work_dir, spec, existing_member, opts) do
    with :ok <- ownership_matches(existing_member, "owned"),
         :ok <- existing_member_name_matches(existing_member, spec[:member_name]),
         member_name = member_name(spec, existing_member, spec.repo.slug),
         path = Path.join(work_dir, member_name),
         {:ok, plan} <- owned_desired(config, name, spec, path, opts),
         {:ok, plan} <- apply_occupancy(config, plan, opts),
         :ok <- existing_owned_matches(existing_member, plan),
         {:ok, plan} <- owned_path_state(config, plan, opts) do
      {:ok, Map.put(plan, :name, member_name)}
    end
  end

  defp existing_member_name_matches(nil, _requested), do: :ok

  defp existing_member_name_matches(member, requested) do
    existing = member_name_from_marker(member)

    if is_nil(requested) or requested == existing do
      :ok
    else
      {:error,
       Error.new(:conflict, "member is already checked out as #{existing}",
         hint: "member directory names are immutable; choose a new workspace or omit --as",
         details: %{existing: existing, requested: requested}
       )}
    end
  end

  defp member_name(spec, existing_member, fallback) do
    cond do
      existing_member -> member_name_from_marker(existing_member)
      is_binary(spec[:member_name]) -> spec[:member_name]
      true -> fallback
    end
  end

  defp member_name_from_marker(member) do
    member["name"] ||
      (member["rel_path"] && Path.basename(member["rel_path"])) ||
      member["repo"]
  end

  defp ownership_matches(nil, _ownership), do: :ok

  defp ownership_matches(member, ownership) do
    if member["ownership"] == ownership do
      :ok
    else
      {:error,
       Error.new(
         :conflict,
         "#{member["repo"]} is already a #{member["ownership"]} member of this workspace",
         hint: "choose a different repository or workspace name"
       )}
    end
  end

  defp owned_desired(config, _name, spec, path, opts) do
    base = %{
      repo: spec.repo,
      ownership: "owned",
      ref: spec.ref,
      desired_branch: nil,
      detached: false,
      start_ref: nil,
      start_sha: nil,
      head: nil,
      path: path,
      action: :created,
      branch_exists?: false,
      existing_member: nil
    }

    case spec.branch_mode do
      :derive ->
        with {:ok, repo, info} <- start_info(config, spec.repo, spec.ref, opts),
             {:ok, branch} <- derived_branch(config, opts) do
          {:ok,
           %{
             base
             | repo: repo,
               desired_branch: branch,
               start_ref: info.start,
               start_sha: info.sha,
               head: info.sha,
               branch_exists?: Refs.local_branch?(repo.bare_path, branch)
           }}
        end

      :default ->
        with {:ok, repo, info} <- default_info(config, spec.repo, opts) do
          {:ok,
           %{
             base
             | repo: repo,
               desired_branch: info.branch,
               start_ref: info.start,
               start_sha: info.sha,
               head: info.sha,
               branch_exists?: Refs.local_branch?(repo.bare_path, info.branch)
           }}
        end

      :detach ->
        with {:ok, repo, info} <- start_info(config, spec.repo, spec.ref, opts) do
          {:ok,
           %{
             base
             | repo: repo,
               detached: true,
               start_ref: info.sha,
               start_sha: info.sha,
               head: info.sha
           }}
        end

      {:create, branch} ->
        with :ok <- validate_branch(branch),
             {:ok, repo, info} <- start_info(config, spec.repo, spec.ref, opts) do
          {:ok,
           %{
             base
             | repo: repo,
               desired_branch: branch,
               start_ref: info.start,
               start_sha: info.sha,
               head: info.sha,
               branch_exists?: Refs.local_branch?(repo.bare_path, branch)
           }}
        end

      :ref ->
        with {:ok, repo, info} <- ref_info(config, spec.repo, spec.ref, opts) do
          if info.branch do
            {:ok,
             %{
               base
               | repo: repo,
                 desired_branch: info.branch,
                 start_ref: info.start,
                 start_sha: info.sha,
                 head: info.sha,
                 branch_exists?: Refs.local_branch?(repo.bare_path, info.branch)
             }}
          else
            {:ok,
             %{
               base
               | repo: repo,
                 detached: true,
                 start_ref: info.sha,
                 start_sha: info.sha,
                 head: info.sha
             }}
          end
        end
    end
  end

  defp start_info(config, repo, nil, opts), do: default_info(config, repo, opts)
  defp start_info(config, repo, ref, opts), do: ref_info(config, repo, ref, opts)

  defp derived_branch(config, opts) do
    case opts[:branch] do
      nil ->
        topic = opts[:topic] || opts[:workspace]
        template = opts[:branch_template] || config.branch_template

        case Layout.branch_for(topic, template) do
          {:ok, branch} -> {:ok, branch}
          {:error, reason} -> {:error, Error.new(:usage, "cannot derive a branch: #{reason}")}
        end

      branch ->
        with :ok <- validate_branch(branch), do: {:ok, branch}
    end
  end

  defp validate_branch(branch) do
    if Layout.valid_branch?(branch) do
      :ok
    else
      {:error, Error.new(:usage, "invalid branch: #{branch}")}
    end
  end

  defp apply_occupancy(config, plan, opts, attempts \\ 0)

  defp apply_occupancy(_config, _plan, _opts, attempts) when attempts > 8 do
    {:error, Error.new(:conflict, "could not find a free branch")}
  end

  defp apply_occupancy(config, plan, opts, attempts) do
    if plan.detached or is_nil(plan.desired_branch) do
      {:ok, plan}
    else
      case Refs.branch_checked_out(plan.repo.bare_path, plan.desired_branch) do
        nil ->
          {:ok, plan}

        entry ->
          entry_path = Path.expand(entry.path)

          cond do
            entry_path == Path.expand(plan.path) and File.dir?(entry.path) ->
              {:ok, %{plan | action: :reused, branch_exists?: true}}

            entry_path == Path.expand(plan.path) ->
              {:error,
               Error.new(:conflict, "branch #{plan.desired_branch} points at a missing worktree",
                 hint: "run `gitspace doctor --fix` to prune stale worktree metadata",
                 details: %{branch: plan.desired_branch, path: entry_path}
               )}

            true ->
              occupied_decision(config, plan, entry, opts, attempts)
          end
      end
    end
  end

  defp occupied_decision(config, plan, entry, opts, attempts) do
    context = %{
      repo: plan.repo.slug,
      branch: plan.desired_branch,
      path: Path.expand(entry.path),
      target_path: plan.path
    }

    decision =
      case opts[:on_occupied] do
        nil -> :error
        fun -> fun.(context)
      end

    case decision do
      :error ->
        {:error, branch_occupied_error(context)}

      :cancel ->
        {:error, Error.new(:refused, "cancelled")}

      :borrow ->
        borrowed_from_worktree(config, plan, entry, opts)

      :detach ->
        {:ok,
         %{
           plan
           | detached: true,
             desired_branch: nil,
             start_ref: plan.start_sha,
             head: plan.start_sha,
             action: :created
         }}

      {:branch, branch} ->
        with :ok <- validate_branch(branch) do
          plan = %{
            plan
            | desired_branch: branch,
              branch_exists?: Refs.local_branch?(plan.repo.bare_path, branch),
              action: :created
          }

          apply_occupancy(config, plan, opts, attempts + 1)
        end

      _other ->
        {:error, branch_occupied_error(context)}
    end
  end

  defp branch_occupied_error(context) do
    Error.new(
      :branch_occupied,
      "branch '#{context.branch}' is already checked out",
      hint: "use --detach, --branch <new-name>, or --borrow #{context.repo}@#{context.branch}",
      details: %{branch: context.branch, path: context.path, repo: context.repo}
    )
  end

  defp borrowed_from_worktree(config, plan, entry, opts) do
    path = Path.expand(entry.path)

    case import_checkout(config, plan.repo, path, source_for(path), opts[:created_by]) do
      {:ok, checkout} ->
        {:ok,
         %{
           plan
           | ownership: "borrowed",
             path: checkout.path,
             desired_branch: checkout.branch,
             detached: checkout.detached,
             head: checkout.head_sha,
             start_ref: nil,
             start_sha: nil,
             branch_exists?: false,
             action: if(File.dir?(path), do: :borrowed, else: :created)
         }}

      {:error, error} ->
        {:error, error}
    end
  end

  defp source_for(path) do
    case Checkouts.get_by_path(path) do
      {:ok, checkout} -> checkout.source
      {:error, _} -> "external"
    end
  end

  defp existing_owned_matches(nil, _plan), do: :ok

  defp existing_owned_matches(member, plan) do
    existing_branch = member["branch"]

    cond do
      plan.detached and is_nil(existing_branch) ->
        :ok

      plan.detached ->
        {:error,
         Error.new(
           :conflict,
           "#{member["repo"]} is already on branch #{existing_branch} in this workspace",
           hint: "use a different --branch or a new workspace name"
         )}

      existing_branch == plan.desired_branch ->
        :ok

      true ->
        {:error,
         Error.new(
           :conflict,
           "#{member["repo"]} is already at #{existing_branch || "a detached HEAD"} in this workspace",
           hint:
             "requested #{plan.desired_branch}; use a different --branch or a new workspace name",
           details: %{
             repo: member["repo"],
             existing: existing_branch,
             requested: plan.desired_branch
           }
         )}
    end
  end

  defp owned_path_state(_config, %{ownership: "borrowed"} = plan, _opts), do: {:ok, plan}

  defp owned_path_state(_config, plan, _opts) do
    case path_state(plan.path) do
      :missing ->
        {:ok, plan}

      :directory ->
        case verify_checkout(plan.path, plan) do
          :ok -> {:ok, %{plan | action: :reused}}
          {:error, error} -> {:error, error}
        end

      :symlink ->
        {:error,
         Error.new(:conflict, "refusing to replace a symlink at #{plan.path}",
           hint: "move it aside or choose another workspace name"
         )}

      :file ->
        {:error,
         Error.new(:conflict, "path exists and is not a directory: #{plan.path}",
           hint: "move it aside or choose another workspace name"
         )}

      {:error, reason} ->
        {:error, Error.new(:error, "cannot inspect #{plan.path}: #{inspect(reason)}")}
    end
  end

  defp path_state(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :directory}} -> :directory
      {:ok, %File.Stat{type: :symlink}} -> :symlink
      {:ok, _stat} -> :file
      {:error, :enoent} -> :missing
      {:error, reason} -> {:error, reason}
    end
  end

  defp verify_checkout(path, plan) do
    with {:ok, %{stdout: common}} <-
           Gitspace.Git.run(["rev-parse", "--path-format=absolute", "--git-common-dir"], cd: path),
         true <- Path.expand(String.trim(common)) == Path.expand(plan.repo.bare_path),
         {:ok, %{stdout: branch_out}} <-
           Gitspace.Git.run(["rev-parse", "--abbrev-ref", "HEAD"], cd: path) do
      branch = String.trim(branch_out)

      cond do
        plan.detached and branch == "HEAD" ->
          detached_head_matches(path, plan.head)

        plan.detached ->
          {:error, path_conflict(plan, "checked out on #{branch}")}

        branch == plan.desired_branch ->
          :ok

        true ->
          {:error, path_conflict(plan, "checked out on #{branch}")}
      end
    else
      _ -> {:error, path_conflict(plan, "not a worktree of #{plan.repo.slug}")}
    end
  end

  defp detached_head_matches(path, expected) do
    if is_nil(expected) do
      :ok
    else
      case Gitspace.Git.run(["rev-parse", "HEAD"], cd: path) do
        {:ok, %{stdout: out}} ->
          if String.trim(out) == expected, do: :ok, else: :conflict

        {:error, _} ->
          :conflict
      end
      |> case do
        :ok -> :ok
        :conflict -> {:error, Error.new(:conflict, "detached HEAD at #{path} has moved")}
      end
    end
  end

  defp path_conflict(plan, reason) do
    Error.new(:conflict, "path already exists and does not match this member: #{plan.path}",
      hint: "move it aside or choose another workspace name",
      details: %{
        path: plan.path,
        repo: plan.repo.slug,
        expected_branch: plan.desired_branch,
        reason: reason
      }
    )
  end

  defp plan_borrowed(config, spec, existing_member) do
    with :ok <- ownership_matches(existing_member, "borrowed"),
         :ok <- existing_member_name_matches(existing_member, spec[:member_name]),
         {:ok, checkout} <- select_borrowed(config, spec, existing_member) do
      name =
        existing_member_name(existing_member) ||
          spec[:member_name] ||
          Path.basename(checkout.path) ||
          spec.repo.slug

      {:ok,
       %{
         repo: spec.repo,
         name: name,
         ownership: "borrowed",
         ref: spec.ref,
         desired_branch: checkout.branch,
         detached: checkout.detached,
         start_ref: nil,
         start_sha: nil,
         head: checkout.head_sha,
         path: checkout.path,
         action: if(existing_member, do: :reused, else: :borrowed),
         branch_exists?: false,
         existing_member: existing_member,
         checkout: checkout
       }}
    end
  end

  defp existing_member_name(nil), do: nil
  defp existing_member_name(member), do: member_name_from_marker(member)

  defp select_borrowed(config, spec, existing_member) do
    candidates =
      config
      |> Checkouts.list(repo: spec.repo.slug)
      |> Enum.filter(&(File.dir?(&1.path) and &1.state not in ["missing", "broken"]))
      |> Enum.uniq_by(& &1.path)

    existing_checkout =
      case existing_member do
        %{"path" => path} when is_binary(path) ->
          Enum.find(candidates, &(&1.path == Path.expand(path)))

        _ ->
          nil
      end

    cond do
      existing_member && is_nil(existing_checkout) ->
        {:error,
         Error.new(:not_found, "borrowed checkout for #{spec.repo.slug} is missing",
           hint: "restore the directory or re-run `gitspace link <path>`"
         )}

      existing_checkout ->
        assert_borrowed(existing_checkout, spec.ref, spec.repo, candidates)

      spec.ref ->
        matches = Enum.filter(candidates, &borrowed_match?(&1, spec.ref, spec.repo))

        case matches do
          [checkout] -> {:ok, checkout}
          [] -> {:error, borrowed_missing_error(spec, candidates)}
          many -> {:error, borrowed_ambiguous_error(spec, many)}
        end

      true ->
        case candidates do
          [checkout] -> {:ok, checkout}
          [] -> {:error, borrowed_missing_error(spec, candidates)}
          many -> {:error, borrowed_ambiguous_error(spec, many)}
        end
    end
  end

  defp assert_borrowed(checkout, nil, _repo, _candidates), do: {:ok, checkout}

  defp assert_borrowed(checkout, ref, repo, candidates) do
    if borrowed_match?(checkout, ref, repo) do
      {:ok, checkout}
    else
      {:error,
       Error.new(:conflict, "borrowed checkout for #{repo.slug} does not match #{ref}",
         hint: "choose another checkout with @<ref>",
         details: %{
           path: checkout.path,
           branch: checkout.branch,
           requested: ref,
           candidates: candidate_maps(candidates)
         }
       )}
    end
  end

  defp borrowed_match?(checkout, ref, repo) do
    case borrow_ref(repo, ref) do
      {:ok, %{kind: kind, branch: branch}}
      when kind in [:local_branch, :remote_branch] ->
        checkout.branch in [branch, ref]

      {:ok, %{kind: :tag, sha: sha}} ->
        checkout.detached and checkout.head_sha == sha

      {:ok, %{kind: :commit, sha: sha}} ->
        checkout.head_sha == sha

      _ ->
        checkout.branch == ref or sha_prefix?(checkout.head_sha, ref)
    end
  end

  defp borrow_ref(repo, ref) do
    if repo.bare_path && File.dir?(repo.bare_path) do
      Refs.resolve(repo.bare_path, ref)
    else
      {:error, :not_found}
    end
  end

  defp sha_prefix?(nil, _ref), do: false

  defp sha_prefix?(sha, ref) do
    normalized = String.downcase(ref)
    Regex.match?(~r/^[0-9a-f]{4,64}$/, normalized) and String.starts_with?(sha, normalized)
  end

  defp borrowed_missing_error(spec, candidates) do
    Error.new(:not_found, "no existing checkout for #{spec.repo.slug}",
      hint:
        "create one with `gitspace co #{spec.repo.slug}@<ref>` or index it with `gitspace link <path>`",
      details: %{repo: spec.repo.slug, ref: spec.ref, candidates: candidate_maps(candidates)}
    )
  end

  defp borrowed_ambiguous_error(spec, candidates) do
    Error.new(:conflict, "#{spec.repo.slug} has #{length(candidates)} checkouts",
      hint: "select one with --borrow #{spec.repo.slug}@<ref>",
      details: %{repo: spec.repo.slug, candidates: candidate_maps(candidates)}
    )
  end

  defp candidate_maps(candidates) do
    Enum.map(candidates, fn checkout ->
      %{path: checkout.path, branch: checkout.branch, head: checkout.head_sha}
    end)
  end

  defp default_info(config, repo, opts) do
    case opts[:default_ref] do
      ref when is_binary(ref) -> ref_info(config, repo, ref, opts)
      _ -> default_branch_info(config, repo, opts)
    end
  end

  defp default_branch_info(config, repo, opts) do
    default = repo.default_branch || Mirror.default_branch(repo.bare_path)

    cond do
      is_nil(default) ->
        {:error,
         Error.new(:not_found, "#{repo.slug} has no default branch",
           hint: "fetch it with `gitspace repo fetch #{repo.slug}`, or pass repo@<ref>"
         )}

      true ->
        case Refs.resolve_default(repo.bare_path, default) do
          {:ok, info} ->
            {:ok, repo, info}

          {:error, :invalid_ref} ->
            {:error, Error.new(:usage, "invalid default branch: #{default}")}

          {:error, :not_found} ->
            fetch_default(config, repo, default, opts)
        end
    end
  end

  defp fetch_default(config, repo, default, opts) do
    if opts[:fetch] == true and !opts[:dry_run] do
      case Repos.fetch(config, repo) do
        {:ok, fetched} ->
          default = fetched.default_branch || default

          case Refs.resolve_default(fetched.bare_path, default) do
            {:ok, info} -> {:ok, fetched, info}
            _ -> {:error, missing_default_error(fetched, default)}
          end

        {:error, error} ->
          {:error, error}
      end
    else
      {:error, missing_default_error(repo, default)}
    end
  end

  defp missing_default_error(repo, default) do
    Error.new(:not_found, "default branch '#{default}' is not available in #{repo.slug}",
      hint: "fetch it with `gitspace repo fetch #{repo.slug}`"
    )
  end

  defp ref_info(_config, _repo, nil, _opts) do
    {:error, Error.new(:usage, "a ref is required")}
  end

  defp ref_info(config, repo, ref, opts) do
    case Refs.resolve(repo.bare_path, ref) do
      {:ok, info} ->
        {:ok, repo, info}

      {:error, :invalid_ref} ->
        {:error, Error.new(:usage, "invalid ref: #{ref}")}

      {:error, :not_found} ->
        fetch_ref(config, repo, ref, opts)
    end
  end

  defp fetch_ref(config, repo, ref, opts) do
    if opts[:fetch] == true and !opts[:dry_run] do
      case Repos.fetch(config, repo) do
        {:ok, fetched} ->
          case Refs.resolve(fetched.bare_path, ref) do
            {:ok, info} -> {:ok, fetched, info}
            _ -> {:error, missing_ref_error(fetched, ref)}
          end

        {:error, error} ->
          {:error, error}
      end
    else
      {:error, missing_ref_error(repo, ref)}
    end
  end

  defp missing_ref_error(repo, ref) do
    hint =
      if repo.bare_path do
        "fetch it with `gitspace repo fetch #{repo.slug}`, or re-run with --fetch"
      else
        "this repository is external; register its remote with `gitspace repo add`"
      end

    Error.new(:not_found, "ref '#{ref}' not found in #{repo.slug}",
      hint: hint,
      details: %{repo: repo.slug, ref: ref}
    )
  end

  defp dry_run(_config, name, work_dir, existing, plans, failures, opts) do
    result = result_from_plans(name, work_dir, existing, plans, true, opts)

    cond do
      failures != [] and plans == [] ->
        {:error, first_error(failures)}

      failures != [] ->
        {:partial, result, failures}

      true ->
        {:ok, result}
    end
  end

  defp execute(config, name, work_dir, existing, plans, plan_failures, opts) do
    {results, run_failures} =
      Enum.reduce(plans, {[], []}, fn plan, {results, failures} ->
        case execute_member(config, plan, opts) do
          {:ok, result} -> {[result | results], failures}
          {:error, error} -> {results, [failure(plan, error) | failures]}
        end
      end)

    results = Enum.reverse(results)
    failures = plan_failures ++ Enum.reverse(run_failures)

    result = result_from_results(name, work_dir, existing, results, false, opts)

    cond do
      failures != [] and results == [] ->
        {:error, first_error(failures)}

      failures == [] ->
        case write_workspace(config, name, work_dir, existing, results, opts) do
          :ok ->
            {:ok, result_from_results(name, work_dir, existing, results, false, opts)}

          {:error, error} ->
            result = result_from_results(name, work_dir, existing, results, false, opts)
            {:partial, result, [failure(%{repo: name, ownership: "workspace", ref: nil}, error)]}
        end

      true ->
        case write_workspace(config, name, work_dir, existing, results, opts) do
          :ok ->
            {:partial, result, failures}

          {:error, error} ->
            result = result_from_results(name, work_dir, existing, results, false, opts)

            {:partial, result,
             failures ++ [failure(%{repo: name, ownership: "workspace", ref: nil}, error)]}
        end
    end
  end

  defp execute_member(config, %{ownership: "borrowed"} = plan, opts) do
    import_borrowed(config, plan, opts)
  end

  defp execute_member(config, %{action: :reused} = plan, opts) do
    import_owned(config, plan, opts)
  end

  defp execute_member(config, plan, opts) do
    File.mkdir_p!(Path.dirname(plan.path))

    result =
      cond do
        plan.detached ->
          Worktree.add(plan.repo.bare_path, plan.path, plan.start_ref || plan.head, detach: true)

        plan.branch_exists? ->
          Worktree.add(plan.repo.bare_path, plan.path, plan.desired_branch)

        true ->
          Worktree.add(plan.repo.bare_path, plan.path, plan.start_ref,
            branch: plan.desired_branch
          )
      end

    case result do
      {:ok, _} -> import_owned(config, plan, opts)
      {:error, git_result} -> {:error, worktree_error(plan, git_result)}
    end
  end

  defp import_owned(config, plan, opts) do
    case import_checkout(config, plan.repo, plan.path, "managed", opts[:created_by]) do
      {:ok, checkout} ->
        {:ok, checkout_result(plan, checkout)}

      {:error, error} ->
        {:error, error}
    end
  end

  defp import_borrowed(config, plan, _opts) do
    source =
      case plan[:checkout] do
        %{source: source} -> source
        _ -> source_for(plan.path)
      end

    case import_checkout(config, plan.repo, plan.path, source, nil) do
      {:ok, checkout} -> {:ok, checkout_result(plan, checkout)}
      {:error, error} -> {:error, error}
    end
  end

  defp import_checkout(config, repo, path, source, created_by) do
    kind =
      cond do
        File.regular?(Path.join(path, ".git")) -> "worktree"
        File.dir?(Path.join(path, ".git")) -> "clone"
        true -> "worktree"
      end

    case Checkouts.import(config, repo, path,
           kind: kind,
           source: source,
           created_by: created_by
         ) do
      {:ok, checkout, _created} -> {:ok, checkout}
      {:error, error} -> {:error, error}
    end
  end

  defp checkout_result(plan, checkout) do
    %{
      repo: plan.repo.slug,
      remote: plan.repo.remote_key,
      name: plan.name,
      ownership: plan.ownership,
      path: checkout.path,
      branch: checkout.branch,
      detached: checkout.detached,
      ref: plan.ref || checkout.branch || checkout.head_sha,
      head: checkout.head_sha,
      action: action_name(plan.action)
    }
  end

  defp action_name(:created), do: "created"
  defp action_name(:reused), do: "reused"
  defp action_name(:borrowed), do: "borrowed"

  defp worktree_error(plan, result) do
    stderr = String.trim(result.stderr)

    cond do
      stderr =~ "already checked out" or stderr =~ "already used by worktree" ->
        branch_occupied_error(%{
          repo: plan.repo.slug,
          branch: plan.desired_branch,
          path: plan.path
        })

      stderr =~ "already exists" ->
        path_conflict(plan, stderr)

      true ->
        Error.new(:error, "cannot create #{plan.path}: #{stderr}",
          hint: "inspect the directory and re-run; existing members are untouched"
        )
    end
  end

  defp write_workspace(config, name, work_dir, existing, results, opts) do
    marker = marker(name, existing, results, opts)

    try do
      Marker.write!(work_dir, marker)

      case Workspaces.recover(config, work_dir, marker) do
        {:ok, _members, []} -> :ok
        {:ok, _members, issues} -> {:error, index_issue_error(issues)}
        {:error, error} -> {:error, error}
      end
    rescue
      error ->
        {:error, Error.new(:error, "cannot write workspace marker: #{Exception.message(error)}")}
    end
  end

  defp index_issue_error(issues) do
    parts =
      Enum.map(issues, fn issue -> "#{issue[:repo] || issue[:workspace]}: #{issue[:reason]}" end)

    Error.new(:partial, "workspace marker written but indexing was incomplete",
      hint: "run `gitspace doctor --reindex` after fixing the reported members",
      details: %{issues: issues, reasons: parts}
    )
  end

  defp marker(name, existing, results, opts) do
    members = merge_members(existing.members, results)

    description =
      if Keyword.has_key?(opts, :description) do
        opts[:description]
      else
        existing.description
      end

    Marker.build(name,
      project: opts[:project],
      topic: opts[:topic],
      description: description,
      labels: Enum.uniq(existing.labels ++ List.wrap(opts[:labels])),
      created_at: existing.created_at || DateTime.utc_now() |> DateTime.to_iso8601(),
      members: members
    )
  end

  defp merge_members(existing_members, results) do
    existing_members
    |> Enum.map(fn member ->
      Enum.find_value(results, member, fn result ->
        if member_matches_repo?(member, result), do: marker_member(result)
      end)
    end)
    |> Enum.concat(
      results
      |> Enum.reject(fn result ->
        Enum.any?(existing_members, &member_matches_repo?(&1, result))
      end)
      |> Enum.map(&marker_member/1)
    )
    |> Enum.map(&refresh_member_alias/1)
  end

  defp refresh_member_alias(member) do
    case member["remote"] do
      key when is_binary(key) ->
        case Repo.get_by(Repository, remote_key: key) do
          nil -> member
          repo -> Map.put(member, "repo", repo.slug)
        end

      _ ->
        member
    end
  end

  defp marker_member(result) do
    base = %{
      "repo" => result.repo,
      "remote" => result.remote,
      "name" => result.name,
      "ownership" => result.ownership,
      "branch" => result.branch,
      "ref" => result.ref,
      "head" => result.head
    }

    case result.ownership do
      "owned" -> Map.put(base, "rel_path", result.name || Path.basename(result.path))
      "borrowed" -> Map.put(base, "path", result.path)
    end
  end

  defp result_from_results(name, work_dir, existing, results, dry_run?, opts) do
    final_members = merge_members(existing.members, results)

    members =
      Enum.map(final_members, fn marker_member ->
        result = Enum.find(results, &member_matches_repo?(marker_member, &1))
        output_member(marker_member, result, work_dir)
      end)

    metadata(name, work_dir, existing, results, members, dry_run?, opts)
  end

  defp result_from_plans(name, work_dir, existing, plans, dry_run?, opts) do
    planned =
      Enum.map(plans, fn plan ->
        %{
          repo: plan.repo.slug,
          remote: plan.repo.remote_key,
          name: plan.name,
          ownership: plan.ownership,
          path: plan.path,
          branch: plan.desired_branch,
          detached: plan.detached,
          ref: plan.ref || plan.desired_branch || plan.head,
          head: plan.head,
          action:
            case plan.action do
              :reused -> "reuse"
              :borrowed -> "borrow"
              _ -> "create"
            end
        }
      end)

    kept =
      existing.members
      |> Enum.reject(fn member ->
        Enum.any?(plans, fn plan -> member_matches_repo?(member, plan.repo) end)
      end)
      |> Enum.map(&output_member(&1, nil, work_dir))

    metadata(name, work_dir, existing, planned, kept ++ planned, dry_run?, opts)
  end

  defp output_member(marker_member, result, work_dir) do
    ownership = marker_member["ownership"]
    name = (result && result.name) || marker_member["name"] || marker_name(marker_member)

    path =
      case ownership do
        "owned" -> Path.join(work_dir, marker_member["rel_path"] || name)
        _ -> marker_member["path"]
      end

    branch = (result && result.branch) || marker_member["branch"]
    ref = (result && result.ref) || marker_member["ref"] || branch
    head = (result && result.head) || marker_member["head"]

    %{
      repo: marker_member["repo"],
      remote: (result && result.remote) || marker_member["remote"],
      name: name,
      ownership: ownership,
      path: path,
      branch: branch,
      detached: is_nil(branch) and not is_nil(ref),
      ref: ref,
      head: head,
      action: (result && result.action) || "kept"
    }
  end

  defp marker_name(marker_member) do
    marker_member["name"] ||
      (marker_member["rel_path"] && Path.basename(marker_member["rel_path"])) ||
      marker_member["repo"]
  end

  defp metadata(name, work_dir, existing, results, members, dry_run?, opts) do
    labels = Enum.uniq(existing.labels ++ List.wrap(opts[:labels]))

    description =
      if Keyword.has_key?(opts, :description) do
        opts[:description]
      else
        existing.description
      end

    %{
      project: opts[:project],
      topic: opts[:topic],
      workspace: name,
      path: work_dir,
      marker_path: Path.join(work_dir, Marker.marker_filename()),
      created: not existing.exists?,
      dry_run: dry_run?,
      labels: labels,
      description: description,
      members: members,
      changed: Enum.any?(results, &(&1.action in ["created", "borrowed", "create", "borrow"])),
      failures: []
    }
  end

  defp first_error([%{error: %Error{} = error} | _]), do: error
  defp first_error([%{reason: reason} | _]), do: Error.new(:error, reason)
end
