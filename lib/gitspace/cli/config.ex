defmodule Gitspace.CLI.Config do
  @moduledoc false

  alias Gitspace.{Bundle, Config, Error, Layout}
  alias Gitspace.CLI.{Helpers, Output}

  @keys ~w(paths.data projects.root branch.template git.minimum_version status.max_age_seconds log.max_commits)

  def run(global, args) do
    case args do
      [] -> list([])
      ["list" | rest] -> list(rest)
      ["get" | rest] -> get(rest)
      ["set" | rest] -> set(rest)
      ["export" | rest] -> export_bundle(global, rest)
      ["import" | rest] -> import_bundle(global, rest)
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

  defp export_bundle(global, args) do
    with {:ok, opts, rest} <- Helpers.parse(args, [output: :string] ++ Helpers.global_strict()),
         :ok <- Helpers.no_extra_args(rest),
         :ok <- reject_export_json(global),
         {:ok, config} <- Helpers.load_config(),
         :ok <- Helpers.start_index(config) do
      bundle = Bundle.export(config)
      body = Jason.encode!(bundle, pretty: true) <> "\n"

      case opts[:output] do
        nil ->
          {:ok, %{bundle: bundle, body: body}, &render_export/1}

        path ->
          case File.write(path, body) do
            :ok ->
              {:ok,
               %{
                 path: path,
                 projects: length(bundle["projects"]),
                 repos: length(bundle["repos"]),
                 skipped: length(bundle["skipped"])
               }, &render_export_file/1}

            {:error, reason} ->
              {:error,
               Error.new(:error, "cannot write bundle: #{path}",
                 hint: :file.format_error(reason) |> to_string()
               )}
          end
      end
    end
  end

  defp reject_export_json(%{json: true}) do
    {:error,
     Error.new(:usage, "--json is not supported for config export",
       hint: "use --output FILE or redirect stdout"
     )}
  end

  defp reject_export_json(_global), do: :ok

  defp import_bundle(global, args) do
    with {:ok, opts, rest} <- Helpers.parse(args, import_strict()),
         {:ok, source} <- one_arg(rest, "gitspace config import <file|->"),
         {:ok, config} <- Helpers.load_config(),
         :ok <- Helpers.start_index(config),
         :ok <- confirm_import(global, opts, source),
         {:ok, data} <- read_bundle(source) do
      case Bundle.import_bundle(config, data,
             dry_run: !!opts[:dry_run],
             no_fetch: !!opts[:no_fetch]
           ) do
        {:ok, summary} ->
          {:ok, summary, &render_import/1}

        {:partial, summary, warnings} ->
          {:partial, summary, &render_import/1,
           Error.new(:partial, "import was partial",
             hint: Enum.join(warnings, "; "),
             details: %{warnings: warnings}
           )}

        {:error, error} ->
          {:error, error}
      end
    end
  end

  defp import_strict, do: [dry_run: :boolean, no_fetch: :boolean] ++ Helpers.global_strict()

  defp confirm_import(global, opts, source) do
    if opts[:dry_run] do
      :ok
    else
      Helpers.require_confirmation(
        global,
        opts,
        "import projects and repositories from #{source}?"
      )
    end
  end

  defp read_bundle("-") do
    case IO.read(:stdio, :all) do
      {:error, reason} -> {:error, Error.new(:error, "cannot read stdin: #{inspect(reason)}")}
      body -> decode_bundle(body)
    end
  end

  defp read_bundle(path) do
    case File.read(path) do
      {:ok, body} ->
        decode_bundle(body)

      {:error, reason} ->
        {:error,
         Error.new(:not_found, "cannot read bundle: #{path}",
           hint: :file.format_error(reason) |> to_string()
         )}
    end
  end

  defp decode_bundle(body) do
    case Jason.decode(body) do
      {:ok, data} ->
        {:ok, data}

      {:error, error} ->
        {:error, Error.new(:invalid_config, "invalid bundle JSON: #{Exception.message(error)}")}
    end
  end

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

  defp render_export(%{body: body}), do: IO.write(body)

  defp render_export_file(data) do
    IO.puts(
      "exported #{data.projects} project(s) and #{data.repos} repositor#{if data.repos == 1, do: "y", else: "ies"}"
    )

    if data.skipped > 0, do: IO.puts("  skipped: #{data.skipped}")
    IO.puts("  file:    #{data.path}")
  end

  defp render_import(data) do
    prefix = if data.dry_run, do: "would ", else: ""

    IO.puts(if data.dry_run, do: "import plan", else: "imported")
    IO.puts("")

    if data.repos != [] do
      Output.table(
        ["REPO", "ACTION"],
        Enum.map(data.repos, fn repo -> [repo.alias, prefix <> Atom.to_string(repo.action)] end)
      )
    end

    if data.projects != [] do
      IO.puts("")

      Output.table(
        ["PROJECT", "ACTION", "MEMBERS"],
        Enum.map(data.projects, fn project ->
          [
            project.name,
            prefix <> Atom.to_string(project.action),
            Enum.join(project.members, ", ")
          ]
        end)
      )
    end

    if data.warnings != [] do
      IO.puts("")

      Enum.each(data.warnings, fn warning ->
        IO.puts(:stderr, "warning: #{warning}")
      end)
    end
  end

  defp help do
    """
    USAGE
      gitspace config                 show effective configuration
      gitspace config list
      gitspace config get <key>
      gitspace config set <key> <value> [--force]
      gitspace config export [--output FILE]
      gitspace config import <FILE|-> [--dry-run] [--no-fetch] [--yes]

    EXPORT AND IMPORT
      A bundle contains projects and their remote-backed repositories only.
      Workspaces, checkouts, labels, absolute paths and credentials are not
      included. Local repositories are skipped. Import creates only missing
      repositories and projects; existing entries are left untouched. A project
      whose member was skipped is created without that member and reported as
      partial.

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
