defmodule Gitspace.Config do
  @moduledoc """
  Effective configuration, loaded from TOML with environment overrides.

  Precedence: environment > config file > defaults. The config file is
  `$XDG_CONFIG_HOME/gitspace/config.toml` (or `GITSPACE_CONFIG`). Data lives
  under `$XDG_DATA_HOME/gitspace` unless overridden.

  `GITSPACE_DATA` and `GITSPACE_PROJECTS_ROOT` make the tool usable in tests
  and ephemeral environments without running `setup` first.
  """

  @schema_version 1
  @sync_names ~w(nextcloud dropbox onedrive icloud iclouddrive google-drive)

  defstruct path: nil,
            data_dir: nil,
            projects_root: nil,
            branch_template: "feature/{topic}",
            git_minimum: "2.42",
            status_max_age: 3600

  @type t :: %__MODULE__{
          path: Path.t() | nil,
          data_dir: Path.t() | nil,
          projects_root: Path.t() | nil,
          branch_template: String.t(),
          git_minimum: String.t(),
          status_max_age: pos_integer()
        }

  @spec load() :: {:ok, t()} | {:error, term()}
  def load do
    case load_optional() do
      {:ok, %__MODULE__{projects_root: nil}} -> {:error, :not_configured}
      other -> other
    end
  end

  @spec load!() :: t()
  def load! do
    case load() do
      {:ok, config} ->
        config

      {:error, :not_configured} ->
        raise Gitspace.Error,
          code: :not_configured,
          message: "gitspace is not configured",
          hint: "run `gitspace setup`"

      {:error, reason} ->
        raise Gitspace.Error,
          code: :invalid_config,
          message: "cannot load configuration: #{format_reason(reason)}",
          hint: "fix #{config_path()} or run `gitspace setup`"
    end
  end

  @doc "Like `load/0`, but succeeds when only the data directory is known."
  @spec load_optional() :: {:ok, t()} | {:error, term()}
  def load_optional do
    path = config_path()

    with {:ok, config} <- read(path) do
      config
      |> apply_env()
      |> validate()
    end
  end

  @doc "Reads the config file without applying environment overrides."
  @spec load_file() :: {:ok, t()} | {:error, term()}
  def load_file do
    path = config_path()

    if File.exists?(path) do
      read_config(path)
    else
      {:error, :not_configured}
    end
  end

  @spec save(t()) :: :ok | {:error, term()}
  def save(%__MODULE__{} = config) do
    path = config.path || config_path()

    with {:ok, _config} <- validate(config),
         {:ok, body} <- TomlElixir.encode(to_map(config)) do
      File.mkdir_p!(Path.dirname(path))
      tmp = path <> ".tmp"

      with :ok <- File.write(tmp, body),
           :ok <- File.rename(tmp, path) do
        :ok
      else
        {:error, reason} ->
          _ = File.rm(tmp)
          {:error, reason}
      end
    end
  end

  @spec config_path() :: Path.t()
  def config_path do
    System.get_env("GITSPACE_CONFIG") || Path.join(config_home(), "config.toml")
  end

  @spec config_home() :: Path.t()
  def config_home do
    Path.join(xdg_dir("XDG_CONFIG_HOME", ".config"), "gitspace")
  end

  @spec data_home() :: Path.t()
  def data_home do
    Path.join(xdg_dir("XDG_DATA_HOME", Path.join(".local", "share")), "gitspace")
  end

  @spec default_data_dir() :: Path.t()
  def default_data_dir, do: data_home()

  @spec default_projects_root() :: Path.t()
  def default_projects_root, do: Path.join(System.user_home!(), "work")

  @doc "Deprecated alias for `default_projects_root/0`."
  @spec default_checkout_dir() :: Path.t()
  def default_checkout_dir, do: default_projects_root()

  @spec db_path(t()) :: Path.t()
  def db_path(%__MODULE__{data_dir: data_dir}), do: Path.join(data_dir, "index.sqlite3")

  @spec repos_dir(t()) :: Path.t()
  def repos_dir(%__MODULE__{data_dir: data_dir}), do: Path.join(data_dir, "repos")

  @doc "True when a path sits inside a well-known file-sync root."
  @spec sync_root?(Path.t()) :: boolean()
  def sync_root?(path) do
    path
    |> Path.expand()
    |> Path.split()
    |> Enum.map(&String.downcase/1)
    |> Enum.any?(fn segment ->
      segment in @sync_names or
        String.starts_with?(segment, ".nextcloud") or
        String.starts_with?(segment, ".dropbox")
    end)
  end

  @spec ensure_dirs(t()) :: :ok | {:error, Gitspace.Error.t()}
  def ensure_dirs(%__MODULE__{} = config) do
    dirs = [config.data_dir, repos_dir(config), config.projects_root]

    Enum.reduce_while(dirs, :ok, fn dir, :ok ->
      with :ok <- File.mkdir_p(dir),
           :ok <- writable?(dir) do
        {:cont, :ok}
      else
        {:error, reason} ->
          {:halt,
           {:error,
            Gitspace.Error.new(:refused, "cannot use #{dir}: #{format_reason(reason)}",
              hint: "choose a writable directory with `gitspace setup --data/--projects`"
            )}}
      end
    end)
  end

  defp read(path) do
    if File.exists?(path) do
      read_config(path)
    else
      {:ok, %__MODULE__{path: path, data_dir: default_data_dir()}}
    end
  end

  defp read_config(path) do
    with {:ok, body} <- File.read(path),
         {:ok, data} <- decode(body) do
      from_map(data, path)
    end
  end

  defp decode(body) do
    case TomlElixir.decode(body) do
      {:ok, data} -> {:ok, data}
      {:error, reason} -> {:error, {:invalid_toml, reason}}
    end
  rescue
    error -> {:error, {:invalid_toml, Exception.message(error)}}
  end

  defp from_map(data, path) when is_map(data) do
    version = get_in_map(data, ["schema_version"], @schema_version)

    if version != @schema_version do
      {:error, {:unsupported_schema, version}}
    else
      {:ok,
       %__MODULE__{
         path: path,
         data_dir: expand(get_in_map(data, ["paths", "data"], default_data_dir())),
         projects_root:
           expand(
             get_in_map(
               data,
               ["projects", "root"],
               get_in_map(data, ["paths", "checkouts"], nil)
             )
           ),
         branch_template: get_in_map(data, ["branch", "template"], "feature/{topic}"),
         git_minimum: get_in_map(data, ["git", "minimum_version"], "2.42"),
         status_max_age: get_in_map(data, ["status", "max_age_seconds"], 3600)
       }}
    end
  end

  defp apply_env(config) do
    %{
      config
      | data_dir: expand(env_or("GITSPACE_DATA", config.data_dir)),
        projects_root:
          expand(
            env_or(
              "GITSPACE_PROJECTS_ROOT",
              env_or("GITSPACE_CHECKOUTS", config.projects_root)
            )
          )
    }
  end

  defp validate(%__MODULE__{} = config) do
    cond do
      not is_binary(config.data_dir) or config.data_dir == "" ->
        {:error, :missing_data_dir}

      Path.type(config.data_dir) != :absolute ->
        {:error, {:relative_path, config.data_dir}}

      is_binary(config.projects_root) and Path.type(config.projects_root) != :absolute ->
        {:error, {:relative_path, config.projects_root}}

      is_binary(config.projects_root) and config.projects_root == config.data_dir ->
        {:error, :same_data_and_projects}

      not is_integer(config.status_max_age) or config.status_max_age <= 0 ->
        {:error, :invalid_status_max_age}

      true ->
        {:ok, config}
    end
  end

  defp to_map(%__MODULE__{} = config) do
    %{
      "schema_version" => @schema_version,
      "paths" => %{"data" => config.data_dir},
      "projects" => %{"root" => config.projects_root},
      "branch" => %{"template" => config.branch_template},
      "git" => %{"minimum_version" => config.git_minimum},
      "status" => %{"max_age_seconds" => config.status_max_age}
    }
  end

  defp get_in_map(map, keys, default) do
    Enum.reduce_while(keys, map, fn key, acc ->
      case acc do
        %{} when is_map_key(acc, key) -> {:cont, Map.get(acc, key)}
        _ -> {:halt, :missing}
      end
    end)
    |> case do
      :missing -> default
      value -> value
    end
  end

  defp expand(nil), do: nil
  defp expand(path) when is_binary(path), do: Path.expand(path)
  defp expand(other), do: other

  defp writable?(dir) do
    probe = Path.join(dir, ".gitspace-write-test-#{System.unique_integer([:positive])}")

    case File.write(probe, "") do
      :ok ->
        _ = File.rm(probe)
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp env_or(variable, default) do
    case System.get_env(variable) do
      nil -> default
      "" -> default
      value -> value
    end
  end

  defp xdg_dir(variable, fallback) do
    case System.get_env(variable) do
      nil -> Path.join(System.user_home!(), fallback)
      "" -> Path.join(System.user_home!(), fallback)
      dir -> dir
    end
  end

  defp format_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp format_reason(reason) when is_binary(reason), do: reason
  defp format_reason(reason), do: inspect(reason)
end
