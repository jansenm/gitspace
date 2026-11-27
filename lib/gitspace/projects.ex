defmodule Gitspace.Projects do
  @moduledoc """
  Project definitions: named sets of repositories.

  Projects are user intent, so they are not derived from git. They live in
  `<data>/projects.toml`; the SQLite index only records workspace instances.

  A project's `path` is the directory that contains its topic workspaces, not
  the parent of that directory. Defaults are created under `projects.root`.
  """

  alias Gitspace.{Config, Error, Layout, Repo}
  alias Gitspace.Index.Repository

  @projects_file "projects.toml"
  @marker_file ".gitspace-project.json"
  @schema_version 1

  defstruct name: nil,
            path: nil,
            description: nil,
            branch_template: nil,
            default_ref: nil,
            members: [],
            source: "explicit"

  @type t :: %__MODULE__{
          name: String.t(),
          path: Path.t(),
          description: String.t() | nil,
          branch_template: String.t() | nil,
          default_ref: String.t() | nil,
          members: [String.t()],
          source: String.t()
        }

  @spec path(Config.t()) :: Path.t()
  def path(%Config{data_dir: data_dir}), do: Path.join(data_dir, @projects_file)

  @spec load(Config.t()) :: {:ok, %{String.t() => t()}} | {:error, Error.t()}
  def load(%Config{} = config) do
    file = path(config)

    if File.exists?(file) do
      with {:ok, body} <- File.read(file),
           {:ok, data} <- decode(body) do
        from_map(data)
      else
        {:error, reason} ->
          {:error,
           Error.new(:invalid_config, "cannot read projects: #{format_reason(reason)}",
             hint: "fix #{file} or delete it to start over"
           )}
      end
    else
      {:ok, %{}}
    end
  end

  @spec load!(Config.t()) :: %{String.t() => t()}
  def load!(%Config{} = config) do
    case load(config) do
      {:ok, projects} -> projects
      {:error, error} -> raise error
    end
  end

  @spec save(Config.t(), %{String.t() => t()}) :: :ok | {:error, Error.t()}
  def save(%Config{} = config, projects) when is_map(projects) do
    file = path(config)
    File.mkdir_p!(Path.dirname(file))

    body =
      projects
      |> Enum.sort_by(fn {name, _project} -> name end)
      |> Map.new(fn {_name, project} -> {project.name, to_map(project)} end)
      |> then(&%{"schema_version" => @schema_version, "projects" => &1})
      |> TomlElixir.encode()
      |> case do
        {:ok, body} -> body
        {:error, reason} -> raise "cannot encode projects: #{inspect(reason)}"
      end

    tmp = file <> ".tmp"

    with :ok <- File.write(tmp, body),
         :ok <- File.rename(tmp, file) do
      :ok
    else
      {:error, reason} ->
        _ = File.rm(tmp)

        {:error,
         Error.new(:error, "cannot save projects: #{format_reason(reason)}",
           hint: "check that #{file} is writable"
         )}
    end
  rescue
    error in RuntimeError ->
      {:error, Error.new(:error, Exception.message(error))}
  end

  @spec list(Config.t()) :: [t()]
  def list(%Config{} = config) do
    config
    |> load!()
    |> Map.values()
    |> Enum.sort_by(& &1.name)
  end

  @spec get(Config.t(), String.t()) :: {:ok, t()} | {:error, Error.t()}
  def get(%Config{} = config, name) do
    name = String.trim(name)

    case Map.fetch(load!(config), name) do
      {:ok, project} ->
        {:ok, project}

      :error ->
        {:error,
         Error.new(:not_found, "project not found: #{name}", hint: "run `gitspace project ls`")}
    end
  end

  @doc "Gets a project, or creates an implicit one-repo project for a registered repo."
  @spec get_or_implicit(Config.t(), String.t()) :: {:ok, t()} | {:error, Error.t()}
  def get_or_implicit(%Config{} = config, name) do
    case get(config, name) do
      {:ok, project} ->
        {:ok, project}

      {:error, %Error{code: :not_found} = error} ->
        case Repo.get_by(Repository, slug: name) do
          nil ->
            {:error, error}

          repo ->
            ensure_implicit(config, repo)
        end

      {:error, error} ->
        {:error, error}
    end
  end

  @spec ensure_implicit(Config.t(), Repository.t()) :: {:ok, t()} | {:error, Error.t()}
  def ensure_implicit(%Config{} = config, %Repository{} = repo) do
    projects = load!(config)

    case Map.fetch(projects, repo.slug) do
      {:ok, project} ->
        {:ok, project}

      :error ->
        project = %__MODULE__{
          name: repo.slug,
          path: default_path(config, repo.slug),
          members: [repo.remote_key],
          source: "implicit"
        }

        with :ok <- ensure_path(config, project, projects),
             :ok <- save(config, Map.put(projects, project.name, project)) do
          {:ok, project}
        end
    end
  end

  @spec ensure_project(Config.t(), String.t()) :: {:ok, t()} | {:error, Error.t()}
  def ensure_project(%Config{} = config, name) do
    case get(config, name) do
      {:ok, project} -> {:ok, project}
      {:error, %Error{code: :not_found}} -> create(config, name)
      {:error, error} -> {:error, error}
    end
  end

  @spec create(Config.t(), String.t(), keyword()) :: {:ok, t()} | {:error, Error.t()}
  def create(%Config{} = config, name, opts \\ []) do
    projects = load!(config)

    with {:ok, name} <- validate_name(name),
         :ok <- ensure_new(projects, name),
         {:ok, members} <-
           resolve_member_keys(
             config,
             opts |> Keyword.get_values(:repo) |> List.flatten()
           ),
         path <- Keyword.get(opts, :path) || default_path(config, name),
         {:ok, path} <- validate_explicit_path(config, name, path, opts, projects),
         project = %__MODULE__{
           name: name,
           path: path,
           description: opts[:description],
           branch_template: opts[:branch_template],
           default_ref: opts[:default_ref],
           members: members,
           source: "explicit"
         },
         :ok <- ensure_path(config, project, projects),
         :ok <- save(config, Map.put(projects, name, project)) do
      {:ok, project}
    end
  end

  @spec update(Config.t(), String.t(), map()) :: {:ok, t()} | {:error, Error.t()}
  def update(%Config{} = config, name, attrs) do
    projects = load!(config)

    with {:ok, project} <- fetch(projects, name) do
      project = struct(project, attrs)

      with :ok <- save(config, Map.put(projects, project.name, project)) do
        {:ok, project}
      end
    end
  end

  @spec delete(Config.t(), String.t()) :: :ok | {:error, Error.t()}
  def delete(%Config{} = config, name) do
    projects = load!(config)

    with {:ok, project} <- fetch(projects, name) do
      save(config, Map.delete(projects, project.name))
    end
  end

  @spec add_members(Config.t(), String.t(), [String.t()]) ::
          {:ok, t()} | {:error, Error.t()}
  def add_members(%Config{} = config, name, selectors) do
    projects = load!(config)

    with {:ok, project} <- fetch(projects, name),
         {:ok, keys} <- resolve_member_keys(config, selectors) do
      project = %{project | members: Enum.uniq(project.members ++ keys)}

      with :ok <- save(config, Map.put(projects, project.name, project)) do
        {:ok, project}
      end
    end
  end

  @spec remove_members(Config.t(), String.t(), [String.t()]) ::
          {:ok, t()} | {:error, Error.t()}
  def remove_members(%Config{} = config, name, selectors) do
    projects = load!(config)

    with {:ok, project} <- fetch(projects, name),
         {:ok, keys} <- resolve_member_keys(config, selectors),
         {:ok, project} <- remove_existing(project, keys) do
      with :ok <- save(config, Map.put(projects, project.name, project)) do
        {:ok, project}
      end
    end
  end

  @doc "Resolves a project's member remote keys to indexed repositories."
  @spec resolve_members(Config.t(), t()) :: {:ok, [Repository.t()]} | {:error, Error.t()}
  def resolve_members(%Config{} = _config, %__MODULE__{} = project) do
    {repos, missing} =
      Enum.reduce(project.members, {[], []}, fn key, {repos, missing} ->
        if is_binary(key) do
          case Repo.get_by(Repository, remote_key: key) do
            nil -> {repos, [key | missing]}
            repo -> {[repo | repos], missing}
          end
        else
          {repos, [key | missing]}
        end
      end)

    case missing do
      [] ->
        {:ok, Enum.reverse(repos)}

      keys ->
        {:error,
         Error.new(:not_found, "project #{project.name} references unregistered repositories",
           hint:
             "restore them with `gitspace repo add`, or remove: " <>
               Enum.map_join(Enum.reverse(keys), ", ", fn key ->
                 if is_binary(key), do: key, else: inspect(key)
               end),
           details: %{project: project.name, missing: Enum.reverse(keys)}
         )}
    end
  end

  @spec projects_for_repo(Config.t(), Repository.t()) :: [String.t()]
  def projects_for_repo(%Config{} = config, %Repository{} = repo) do
    config
    |> list()
    |> Enum.filter(&(repo.remote_key in &1.members))
    |> Enum.map(& &1.name)
  end

  @spec default_path(Config.t(), String.t()) :: Path.t()
  def default_path(%Config{} = config, name) do
    Path.expand(Path.join(config.projects_root, name))
  end

  @spec marker_path(t()) :: Path.t()
  def marker_path(%__MODULE__{path: path}), do: Path.join(path, @marker_file)

  @doc false
  def marker_filename, do: @marker_file

  @spec read_marker(Path.t()) :: {:ok, map()} | {:error, term()}
  def read_marker(path) do
    marker = Path.join(path, @marker_file)

    with {:ok, body} <- File.read(marker),
         {:ok, data} <- Jason.decode(body),
         :ok <- validate_marker(data) do
      {:ok, data}
    end
  end

  @spec write_marker!(t()) :: Path.t()
  def write_marker!(%__MODULE__{} = project) do
    File.mkdir_p!(project.path)
    marker = Path.join(project.path, @marker_file)

    File.write!(
      marker,
      Jason.encode!(%{"schema_version" => @schema_version, "project" => project.name},
        pretty: true
      ) <> "\n"
    )

    marker
  end

  @spec validate_name(String.t()) :: {:ok, String.t()} | {:error, Error.t()}
  def validate_name(name) when is_binary(name) do
    cond do
      String.contains?(name, ["/", ":", "@"]) ->
        {:error,
         Error.new(:usage, "project name cannot contain '/', ':' or '@': #{inspect(name)}")}

      true ->
        validate_slug_name(name)
    end
  end

  def validate_name(_), do: {:error, Error.new(:usage, "project name is required")}

  defp validate_slug_name(name) do
    case Layout.work_slug(name) do
      {:ok, _} ->
        {:ok, String.trim(name)}

      {:error, reason} ->
        {:error, Error.new(:usage, "invalid project name #{inspect(name)}: #{reason}")}
    end
  end

  @spec ensure_path(Config.t(), t(), %{String.t() => t()}) :: :ok | {:error, Error.t()}
  def ensure_path(%Config{} = config, %__MODULE__{} = project, projects) do
    path = Path.expand(project.path)

    cond do
      path == "/" ->
        {:error, Error.new(:refused, "refusing to use / as a project path")}

      path == Path.expand(System.user_home!()) ->
        {:error, Error.new(:refused, "refusing to use the home directory as a project path")}

      path == Path.expand(config.data_dir) ->
        {:error, Error.new(:refused, "refusing to use the data directory as a project path")}

      path == Path.expand(config.projects_root) ->
        {:error,
         Error.new(:refused, "a project path must be a subdirectory of projects.root",
           hint: "pass --at #{Path.join(config.projects_root, project.name)}"
         )}

      File.regular?(Path.join(path, ".git")) or File.dir?(Path.join(path, ".git")) ->
        {:error,
         Error.new(:refused, "project path is a git checkout: #{path}",
           hint: "a project directory contains topic directories, not a repository"
         )}

      parent_missing?(path) ->
        {:error,
         Error.new(:not_found, "parent directory does not exist: #{Path.dirname(path)}",
           hint: "create the parent (or mount the volume) first"
         )}

      nested?(path, projects) ->
        {:error,
         Error.new(:conflict, "project path overlaps another project: #{path}",
           hint: "choose a directory outside every other project"
         )}

      true ->
        ensure_directory(path, project)
    end
  end

  defp ensure_directory(path, project) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :directory}} ->
        cond do
          empty_dir?(path) ->
            write_marker!(project)
            :ok

          marker_matches?(path, project.name) ->
            write_marker!(project)
            :ok

          true ->
            {:error,
             Error.new(:conflict, "project directory is not empty and has no matching marker",
               hint: "use an empty directory or an existing gitspace project",
               details: %{path: path}
             )}
        end

      {:ok, %File.Stat{type: :symlink}} ->
        {:error, Error.new(:refused, "refusing to use a symlink as a project path: #{path}")}

      {:ok, _} ->
        {:error, Error.new(:conflict, "project path is not a directory: #{path}")}

      {:error, :enoent} ->
        File.mkdir_p!(path)
        write_marker!(project)
        :ok

      {:error, reason} ->
        {:error, Error.new(:error, "cannot inspect #{path}: #{format_reason(reason)}")}
    end
  rescue
    error ->
      {:error,
       Error.new(:error, "cannot create project path #{path}: #{Exception.message(error)}")}
  end

  defp validate_explicit_path(%Config{} = config, name, path, opts, projects) do
    path = Path.expand(path)

    cond do
      is_nil(opts[:path]) ->
        {:ok, path}

      Path.basename(path) != name ->
        {:error,
         Error.new(:usage, "explicit project path must end with the project name",
           hint: "use --at #{Path.join(Path.dirname(path), name)}"
         )}

      Path.type(path) != :absolute ->
        {:error, Error.new(:usage, "project path must be absolute: #{path}")}

      true ->
        case ensure_path(config, %__MODULE__{name: name, path: path}, projects) do
          :ok -> {:ok, path}
          {:error, error} -> {:error, error}
        end
    end
  end

  defp resolve_member_keys(_config, selectors) do
    selectors
    |> Enum.flat_map(fn selector ->
      selector
      |> to_string()
      |> String.split(",", trim: true)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
    end)
    |> Enum.uniq()
    |> Enum.reduce_while({:ok, []}, fn selector, {:ok, acc} ->
      case Repo.get_by(Repository, slug: selector) do
        nil ->
          {:halt,
           {:error,
            Error.new(:not_found, "repository not registered: #{selector}",
              hint: "register it with `gitspace repo add <url>`"
            )}}

        repo ->
          {:cont, {:ok, acc ++ [repo.remote_key]}}
      end
    end)
  end

  defp fetch(projects, name) do
    case Map.fetch(projects, String.trim(name)) do
      {:ok, project} -> {:ok, project}
      :error -> {:error, Error.new(:not_found, "project not found: #{name}")}
    end
  end

  defp remove_existing(project, keys) do
    unknown = keys -- project.members

    if unknown == [] do
      {:ok, %{project | members: project.members -- keys}}
    else
      {:error,
       Error.new(:not_found, "not a project member: #{Enum.join(unknown, ", ")}",
         hint: "members: #{Enum.join(project.members, ", ")}"
       )}
    end
  end

  defp ensure_new(projects, name) do
    if Map.has_key?(projects, name), do: {:error, exists_error(name)}, else: :ok
  end

  defp exists_error(name) do
    Error.new(:conflict, "project already exists: #{name}",
      hint: "use `gitspace project add #{name} <repo>`"
    )
  end

  defp parent_missing?(path) do
    not File.dir?(Path.dirname(path))
  end

  defp nested?(path, projects) do
    Enum.any?(projects, fn {_name, other} ->
      other = Path.expand(other.path)
      path == other or within?(path, other) or within?(other, path)
    end)
  end

  defp within?(path, root), do: path == root or String.starts_with?(path, root <> "/")

  defp empty_dir?(path) do
    case File.ls(path) do
      {:ok, []} -> true
      _ -> false
    end
  end

  defp marker_matches?(path, name) do
    case read_marker(path) do
      {:ok, %{"project" => ^name}} -> true
      _ -> false
    end
  end

  defp validate_marker(%{"schema_version" => @schema_version, "project" => name})
       when is_binary(name) and name != "",
       do: :ok

  defp validate_marker(%{"schema_version" => version}) when version != @schema_version,
    do: {:error, {:unsupported_schema, version}}

  defp validate_marker(_), do: {:error, :missing_fields}

  defp decode(body) do
    case TomlElixir.decode(body) do
      {:ok, data} -> {:ok, data}
      {:error, reason} -> {:error, {:invalid_toml, reason}}
    end
  rescue
    error -> {:error, {:invalid_toml, Exception.message(error)}}
  end

  defp from_map(data) when is_map(data) do
    version = Map.get(data, "schema_version", @schema_version)

    if version != @schema_version do
      {:error, {:unsupported_schema, version}}
    else
      projects =
        data
        |> Map.get("projects", %{})
        |> Enum.map(fn {name, attrs} -> {name, project_from_map(name, attrs)} end)
        |> Map.new()

      {:ok, projects}
    end
  end

  defp from_map(_), do: {:error, :invalid_projects}

  defp project_from_map(name, attrs) when is_map(attrs) do
    %__MODULE__{
      name: name,
      path: Map.get(attrs, "path"),
      description: Map.get(attrs, "description"),
      branch_template: Map.get(attrs, "branch_template"),
      default_ref: Map.get(attrs, "default_ref"),
      members: List.wrap(Map.get(attrs, "members", [])),
      source: Map.get(attrs, "source", "explicit")
    }
  end

  defp project_from_map(name, _attrs), do: %__MODULE__{name: name, members: []}

  defp to_map(%__MODULE__{} = project) do
    %{
      "path" => project.path,
      "description" => project.description,
      "branch_template" => project.branch_template,
      "default_ref" => project.default_ref,
      "members" => project.members,
      "source" => project.source
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp format_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp format_reason(reason) when is_binary(reason), do: reason
  defp format_reason(reason), do: inspect(reason)
end
