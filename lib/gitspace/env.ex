defmodule Gitspace.Env do
  @moduledoc """
  Resolves dotenv layers for a project, workspace or checkout.

  Layer order, lowest to highest:

    * `<project.path>/.env`
    * `<checkout.path>/.env`
    * `<project.path>/.env.secrets`
    * `<checkout.path>/.env.local`
    * the process environment
    * `GITSPACE_*` context variables

  Secrets therefore override same-named non-secrets, and the process
  environment wins over files. `GITSPACE_*` are reserved and always win.
  """

  import Ecto.Query

  alias Gitspace.{Checkouts, Config, Error, Projects, Repo, Targets, Workspaces}
  alias Gitspace.Index.{Checkout, Repository, Workspace, WorkspaceMember}

  @key_regex ~r/^\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*=/m
  @reserved "GITSPACE_"

  @type entry :: %{key: String.t(), value: String.t(), source: String.t()}
  @type resolved :: %{
          path: Path.t() | nil,
          context: %{String.t() => String.t()},
          entries: [entry()],
          files: [Path.t()],
          warnings: [String.t()]
        }

  @spec resolve(Config.t(), String.t(), keyword()) :: {:ok, resolved()} | {:error, Error.t()}
  def resolve(%Config{} = config, target, opts \\ []) do
    with {:ok, resolved} <- Targets.resolve(config, target),
         {:ok, ctx} <- context(config, resolved) do
      project_files = project_files(ctx.project)
      checkout_files = checkout_files(ctx.checkout)

      layers =
        [
          {"project .env", project_files[:env]},
          {"repo .env", checkout_files[:env]},
          {"project .env.secrets", project_files[:secrets]},
          {"repo .env.local", checkout_files[:local]}
        ]
        |> Enum.filter(fn {_label, path} -> is_binary(path) and File.exists?(path) end)

      layers = if opts[:no_env], do: [], else: layers
      context = gitspace_vars(ctx)
      process = System.get_env()
      # A project target has no topic, member or repo. Keep those references
      # literal instead of failing so the project environment stays inspectable.
      base = Map.merge(interpolation_base(), context)

      with {:ok, values, sources, files} <- load_layers(layers, base),
           entries <- entries(values, sources, context, process) do
        {:ok,
         %{
           path: ctx.path,
           context: context,
           entries: entries,
           files: files,
           warnings: []
         }}
      end
    end
  end

  @doc "The env and secret file paths for a project."
  @spec project_paths(Config.t(), String.t()) :: {:ok, map()} | {:error, Error.t()}
  def project_paths(%Config{} = config, project_name) do
    with {:ok, project} <- Projects.get(config, project_name) do
      {:ok, project_files(project)}
    end
  end

  @doc "Reads one project env or secret file for display."
  @spec file_entries(Path.t()) ::
          {:ok, [%{key: String.t(), value: String.t()}]} | {:error, Error.t()}
  def file_entries(path) do
    case File.read(path) do
      {:ok, body} ->
        keys = keys_defined(body)

        if Enum.any?(keys, &String.starts_with?(&1, @reserved)) do
          {:error,
           Error.new(:invalid_config, "reserved GITSPACE_ variable in #{path}",
             hint: "remove GITSPACE_* assignments from #{path}"
           )}
        else
          display(path, body, keys)
        end

      {:error, :enoent} ->
        {:ok, []}

      {:error, reason} ->
        {:error,
         Error.new(:error, "cannot read #{path}", hint: :file.format_error(reason) |> to_string())}
    end
  end

  defp display(path, body, keys) do
    case parse(body, interpolation_base()) do
      {:ok, parsed} ->
        entries =
          keys
          |> Enum.map(fn key -> %{key: key, value: Map.get(parsed, key, "")} end)
          |> Enum.sort_by(& &1.key)

        {:ok, entries}

      {:error, message} ->
        {:error, parse_error(path, message)}
    end
  end

  @doc "Path used for project env display."
  @spec project_env_path(map()) :: Path.t()
  def project_env_path(paths), do: paths.env

  @doc "Path used for project secret display."
  @spec project_secret_path(map()) :: Path.t()
  def project_secret_path(paths), do: paths.secrets

  defp context(_config, {:project, project}) do
    {:ok, %{project: project, workspace: nil, member: nil, checkout: nil, path: project.path}}
  end

  defp context(config, {:workspace, workspace}) do
    with {:ok, project} <- project_for(config, workspace),
         {:ok, path} <- workspace_path(workspace) do
      {:ok,
       %{
         project: project,
         workspace: workspace,
         member: nil,
         checkout: nil,
         path: path
       }}
    end
  end

  defp context(config, {:member, workspace, member}) do
    with {:ok, project} <- project_for(config, workspace) do
      {:ok,
       %{
         project: project,
         workspace: workspace,
         member: member,
         checkout: member.checkout,
         path: member.checkout.path
       }}
    end
  end

  defp context(config, {:checkout, checkout}) do
    case memberships(checkout.id) do
      [] ->
        {:ok,
         %{project: nil, workspace: nil, member: nil, checkout: checkout, path: checkout.path}}

      [member] ->
        workspace = member.workspace

        with {:ok, project} <- project_for(config, workspace) do
          {:ok,
           %{
             project: project,
             workspace: workspace,
             member: member,
             checkout: checkout,
             path: checkout.path
           }}
        end

      many ->
        {:error,
         Error.new(:ambiguous, "#{checkout.path} is a member of #{length(many)} workspaces",
           hint: "use a workspace:member target to choose the env context"
         )}
    end
  end

  defp context(config, {:repo, repo}) do
    case Checkouts.list(config, repo: repo.slug) do
      [checkout] ->
        context(config, {:checkout, checkout})

      [] ->
        {:error,
         Error.new(:not_found, "no indexed checkouts for #{repo.slug}",
           hint: "create one with `gitspace checkout #{repo.slug} --topic ...`"
         )}

      many ->
        {:error,
         Error.new(:ambiguous, "#{repo.slug} has #{length(many)} checkouts",
           hint: "use a workspace:member or checkout target"
         )}
    end
  end

  defp context(_config, _resolved) do
    {:error,
     Error.new(
       :usage,
       "env needs a project, workspace, workspace:member, checkout or repo target"
     )}
  end

  defp project_for(config, workspace) do
    case Workspaces.parts(workspace) do
      {name, _topic} when is_binary(name) -> Projects.get(config, name)
      _ -> {:error, Error.new(:error, "workspace #{workspace.name} has no project")}
    end
  end

  defp workspace_path(workspace) do
    case workspace_dir(workspace) do
      nil ->
        {:error,
         Error.new(:error, "workspace #{workspace.name} has no recorded path",
           hint: "run `gitspace doctor reindex`"
         )}

      path ->
        {:ok, path}
    end
  end

  defp workspace_dir(%Workspace{marker_path: marker}) when is_binary(marker),
    do: Path.dirname(marker)

  defp workspace_dir(_workspace), do: nil

  defp memberships(checkout_id) do
    from(m in WorkspaceMember,
      join: w in assoc(m, :workspace),
      where: m.checkout_id == ^checkout_id,
      where: w.state == "active",
      preload: [:workspace]
    )
    |> Repo.all()
  end

  defp project_files(nil), do: %{}

  defp project_files(%Projects{path: path}) when is_binary(path) do
    %{env: Path.join(path, ".env"), secrets: Path.join(path, ".env.secrets")}
  end

  defp checkout_files(nil), do: %{}

  defp checkout_files(%Checkout{path: path}) when is_binary(path) do
    %{env: Path.join(path, ".env"), local: Path.join(path, ".env.local")}
  end

  defp gitspace_vars(ctx) do
    {topic, project_name} =
      case ctx.workspace do
        %Workspace{} = workspace ->
          {project, topic} = Workspaces.parts(workspace)
          {topic, project}

        _ ->
          {nil, ctx.project && ctx.project.name}
      end

    repo =
      case ctx.checkout do
        %Checkout{repository: %Repository{} = repo} -> repo
        %Checkout{repository_id: id} when is_binary(id) -> Repo.get(Repository, id)
        _ -> nil
      end

    member_name =
      case ctx.member do
        %WorkspaceMember{} = member -> member.name || (repo && repo.slug)
        _ -> nil
      end

    %{
      "GITSPACE_PROJECT" => project_name,
      "GITSPACE_TOPIC" => topic,
      "GITSPACE_WORKSPACE" => ctx.workspace && ctx.workspace.name,
      "GITSPACE_MEMBER" => member_name,
      "GITSPACE_REPO" => repo && repo.slug,
      "GITSPACE_BRANCH" => ctx.checkout && ctx.checkout.branch,
      "GITSPACE_PATH" => ctx.path,
      "GITSPACE_IDENTITY" => repo && repo.remote_key
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) or value == "" end)
    |> Map.new(fn {key, value} -> {key, to_string(value)} end)
  end

  defp interpolation_base do
    placeholders =
      Map.new(
        [
          "GITSPACE_PROJECT",
          "GITSPACE_TOPIC",
          "GITSPACE_WORKSPACE",
          "GITSPACE_MEMBER",
          "GITSPACE_REPO",
          "GITSPACE_BRANCH",
          "GITSPACE_PATH",
          "GITSPACE_IDENTITY"
        ],
        fn key -> {key, "${#{key}}"} end
      )

    Map.merge(System.get_env(), placeholders)
  end

  defp load_layers(layers, base) do
    Enum.reduce_while(layers, {:ok, %{}, %{}, []}, fn {source, path},
                                                      {:ok, values, sources, files} ->
      case load_layer(source, path, base, values) do
        {:ok, new_values} ->
          values = Map.merge(values, new_values)
          new_sources = Map.new(new_values, fn {key, _} -> {key, source} end)
          sources = Map.merge(sources, new_sources)
          {:cont, {:ok, values, sources, [path | files]}}

        {:error, error} ->
          {:halt, {:error, error}}
      end
    end)
    |> case do
      {:ok, values, sources, files} -> {:ok, values, sources, Enum.reverse(files)}
      {:error, error} -> {:error, error}
    end
  end

  defp load_layer(source, path, base, values) do
    case File.read(path) do
      {:ok, body} ->
        keys = keys_defined(body)

        if Enum.any?(keys, &String.starts_with?(&1, @reserved)) do
          {:error,
           Error.new(:invalid_config, "reserved GITSPACE_ variable in #{source}",
             hint: "remove GITSPACE_* assignments from #{path}"
           )}
        else
          interp_base = Map.merge(values, base)

          case parse(body, interp_base) do
            {:ok, parsed} ->
              {:ok, Map.new(keys, fn key -> {key, Map.get(parsed, key, "")} end)}

            {:error, message} ->
              {:error, parse_error(path, message)}
          end
        end

      {:error, :enoent} ->
        {:ok, %{}}

      {:error, reason} ->
        {:error,
         Error.new(:error, "cannot read #{path}", hint: :file.format_error(reason) |> to_string())}
    end
  end

  @doc false
  def refuse_shell(_cmd, _args, _opts), do: {"", 1}

  defp parse(body, base) do
    Dotenvy.Parser.parse(body, base, sys_cmd_fn: &__MODULE__.refuse_shell/3)
  end

  defp keys_defined(body) do
    @key_regex
    |> Regex.scan(body, capture: :all_but_first)
    |> List.flatten()
    |> Enum.uniq()
  end

  defp entries(values, sources, context, process) do
    keys =
      (Map.keys(values) ++ Map.keys(context))
      |> Enum.uniq()

    Enum.map(keys, fn key ->
      cond do
        Map.has_key?(context, key) ->
          %{key: key, value: context[key], source: "gitspace"}

        Map.has_key?(process, key) ->
          %{key: key, value: process[key], source: "process"}

        true ->
          %{key: key, value: Map.get(values, key, ""), source: Map.get(sources, key, "?")}
      end
    end)
    |> Enum.sort_by(& &1.key)
  end

  defp parse_error(path, message) do
    hint =
      if String.contains?(message, "Command ") do
        "command substitution is not allowed in dotenv files"
      else
        nil
      end

    Error.new(:invalid_config, "cannot parse #{path}: #{message}", hint: hint)
  end
end
