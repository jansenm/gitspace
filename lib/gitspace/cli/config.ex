defmodule Gitspace.CLI.Config do
  @moduledoc false

  alias Gitspace.{Config, Error, Layout}
  alias Gitspace.CLI.{Helpers, Output}

  @keys ~w(paths.data projects.root branch.template git.minimum_version status.max_age_seconds log.max_commits)

  def run(_global, args) do
    case args do
      [] -> list([])
      ["list" | rest] -> list(rest)
      ["get" | rest] -> get(rest)
      ["set" | rest] -> set(rest)
      ["help"] -> {:ok, %{help: help()}, &IO.puts/1}
      [other | _] -> {:error, Error.new(:usage, "unknown config command: #{other}")}
    end
  end

  defp list(args) do
    with {:ok, _opts, rest} <- Helpers.parse(args, Helpers.global_strict()),
         :ok <- Helpers.no_extra_args(rest),
         {:ok, config} <- load_any() do
      {:ok,
       %{
         config_path: Config.config_path(),
         configured: not is_nil(config.projects_root),
         values: values(config),
         sources: sources(config)
       }, &render_list/1}
    end
  end

  defp get(args) do
    with {:ok, _opts, rest} <- Helpers.parse(args, Helpers.global_strict()),
         {:ok, key} <- one_arg(rest, "gitspace config get <key>"),
         {:ok, config} <- load_any(),
         {:ok, value} <- value_for(config, key) do
      {:ok, %{key: key, value: value}, &render_get/1}
    end
  end

  defp set(args) do
    with {:ok, opts, rest} <- Helpers.parse(args, strict_set()),
         {:ok, key, value} <- key_and_value(rest),
         {:ok, config} <- load_file_config(),
         {:ok, updated, note} <- apply_setting(config, key, value, opts),
         :ok <- Config.save(updated) do
      env_override = env_override?(key)

      note =
        cond do
          env_override -> "environment overrides this value at runtime"
          note -> note
          true -> nil
        end

      {:ok,
       %{
         key: key,
         value: value_for!(updated, key),
         config_path: Config.config_path(),
         env_override: env_override,
         note: note
       }, &render_set/1}
    end
  end

  defp strict_set, do: [force: :boolean] ++ Helpers.global_strict()

  defp load_any do
    case Config.load_optional() do
      {:ok, config} ->
        {:ok, config}

      {:error, reason} ->
        {:error,
         Error.new(:invalid_config, "cannot read configuration: #{Helpers.format_reason(reason)}",
           hint: "fix #{Config.config_path()} or run `gitspace setup`"
         )}
    end
  end

  defp load_file_config do
    case Config.load_file() do
      {:ok, %Config{projects_root: nil}} ->
        {:error,
         Error.new(:not_configured, "gitspace is not configured", hint: "run `gitspace setup`")}

      {:ok, config} ->
        {:ok, config}

      {:error, :not_configured} ->
        {:error,
         Error.new(:not_configured, "gitspace is not configured", hint: "run `gitspace setup`")}

      {:error, reason} ->
        {:error,
         Error.new(:invalid_config, "cannot read configuration: #{Helpers.format_reason(reason)}")}
    end
  end

  defp apply_setting(%Config{} = config, "paths.data", value, opts) do
    path = Path.expand(value)

    with :ok <- check_sync_root(path, opts) do
      {:ok, %Config{config | data_dir: path},
       "the index and mirrors are not moved; they will be created under the new data path"}
    end
  end

  defp apply_setting(%Config{} = config, "projects.root", value, opts) do
    path = Path.expand(value)

    with :ok <- check_sync_root(path, opts) do
      {:ok, %Config{config | projects_root: path},
       "existing projects keep their stored paths; only new projects use this root"}
    end
  end

  defp apply_setting(%Config{} = config, "branch.template", value, _opts) do
    case Layout.branch_for("work", value) do
      {:ok, _branch} -> {:ok, %Config{config | branch_template: value}, nil}
      {:error, reason} -> {:error, Error.new(:usage, "invalid branch template: #{reason}")}
    end
  end

  defp apply_setting(%Config{} = config, "git.minimum_version", value, _opts) do
    if match?({:ok, _}, Version.parse(normalize_version(value))) do
      {:ok, %Config{config | git_minimum: value}, nil}
    else
      {:error,
       Error.new(:usage, "invalid version: #{value}", hint: "use a version such as 2.40.0")}
    end
  end

  defp apply_setting(%Config{} = config, "status.max_age_seconds", value, _opts) do
    case Integer.parse(value) do
      {seconds, ""} when seconds > 0 ->
        {:ok, %Config{config | status_max_age: seconds}, nil}

      _ ->
        {:error, Error.new(:usage, "status.max_age_seconds must be a positive integer")}
    end
  end

  defp apply_setting(%Config{} = config, "log.max_commits", value, _opts) do
    case Integer.parse(value) do
      {count, ""} when count > 0 ->
        {:ok, %Config{config | log_max_commits: count}, nil}

      _ ->
        {:error, Error.new(:usage, "log.max_commits must be a positive integer")}
    end
  end

  defp apply_setting(_config, key, _value, _opts) do
    {:error,
     Error.new(:usage, "unknown configuration key: #{key}",
       hint: "keys: #{Enum.join(@keys, ", ")}"
     )}
  end

  defp check_sync_root(path, opts) do
    if Config.sync_root?(path) and !opts[:force] do
      {:error,
       Error.new(:refused, "#{path} is inside a file-sync root",
         hint: "sync tools corrupt git worktrees; choose another path or pass --force"
       )}
    else
      :ok
    end
  end

  defp values(config) do
    %{
      "paths.data" => config.data_dir,
      "projects.root" => config.projects_root,
      "branch.template" => config.branch_template,
      "git.minimum_version" => config.git_minimum,
      "status.max_age_seconds" => config.status_max_age,
      "log.max_commits" => config.log_max_commits
    }
  end

  defp sources(config) do
    file? = File.exists?(Config.config_path())

    values(config)
    |> Map.new(fn {key, value} ->
      source =
        cond do
          env_override?(key) -> "env"
          is_nil(value) -> "unset"
          file? -> "file"
          true -> "default"
        end

      {key, source}
    end)
  end

  defp value_for(config, key) do
    case Map.fetch(values(config), key) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, unknown_key(key)}
    end
  end

  defp value_for!(config, key) do
    {:ok, value} = value_for(config, key)
    value
  end

  defp unknown_key(key) do
    Error.new(:usage, "unknown configuration key: #{key}",
      hint: "keys: #{Enum.join(@keys, ", ")}"
    )
  end

  defp key_and_value([key, value]), do: {:ok, key, value}

  defp key_and_value(_rest) do
    {:error, Error.new(:usage, "usage: gitspace config set <key> <value>")}
  end

  defp one_arg([arg], _usage), do: {:ok, arg}
  defp one_arg(_rest, usage), do: {:error, Error.new(:usage, "usage: #{usage}")}

  defp env_override?("paths.data"), do: env_set?("GITSPACE_DATA")

  defp env_override?("projects.root"),
    do: env_set?("GITSPACE_PROJECTS_ROOT") or env_set?("GITSPACE_CHECKOUTS")

  defp env_override?(_key), do: false

  defp env_set?(variable) do
    case System.get_env(variable) do
      nil -> false
      "" -> false
      _ -> true
    end
  end

  defp normalize_version(version) do
    case String.split(version, ".") do
      [major, minor] -> "#{major}.#{minor}.0"
      _ -> version
    end
  end

  defp render_list(data) do
    IO.puts("config:     #{data.config_path}")
    IO.puts("configured: #{if data.configured, do: "yes", else: "no"}")

    Enum.each(@keys, fn key ->
      value = Map.get(data.values, key)
      source = Map.get(data.sources, key)
      IO.puts("#{String.pad_trailing(key, 22)} #{Output.format_value(value)}  (#{source})")
    end)
  end

  defp render_get(%{key: key, value: value}) do
    IO.puts("#{key} = #{Output.format_value(value)}")
  end

  defp render_set(data) do
    IO.puts("#{data.key} = #{Output.format_value(data.value)}")

    if data.note do
      IO.puts("note: #{data.note}")
    end
  end

  defp help do
    """
    USAGE
      gitspace config                 show effective configuration
      gitspace config list
      gitspace config get <key>
      gitspace config set <key> <value> [--force]

    KEYS
      paths.data
      projects.root
      branch.template
      git.minimum_version
      status.max_age_seconds
      log.max_commits
    """
  end
end
