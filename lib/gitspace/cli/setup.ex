defmodule Gitspace.CLI.Setup do
  @moduledoc false

  alias Gitspace.{Config, Error, Index}
  alias Gitspace.CLI.{Helpers, Output}

  defp strict do
    [data: :string, checkouts: :string, force: :boolean] ++ Helpers.global_strict()
  end

  def run(_global, args) do
    with {:ok, opts, rest} <- Helpers.parse(args, strict()),
         :ok <- Helpers.no_extra_args(rest),
         {:ok, config} <- load_existing() do
      if configured_file?() and is_nil(opts[:data]) and is_nil(opts[:checkouts]) do
        {:ok,
         %{
           config_path: Config.config_path(),
           data_dir: config.data_dir,
           checkouts_dir: config.checkouts_dir,
           db_path: Config.db_path(config),
           created: false
         }, &render/1}
      else
        configure(config, opts)
      end
    end
  end

  defp configured_file?, do: File.exists?(Config.config_path())

  defp load_existing do
    case Config.load_optional() do
      {:ok, config} ->
        {:ok, config}

      {:error, reason} ->
        {:error,
         Error.new(:invalid_config, "cannot read configuration: #{Helpers.format_reason(reason)}")}
    end
  end

  defp configure(config, opts) do
    data = opts[:data] || config.data_dir || Config.default_data_dir()

    with {:ok, data, checkouts} <- choose_paths(config, opts, data),
         :ok <- check_sync_roots(data, checkouts, opts),
         {:ok, saved} <- save(config, data, checkouts) do
      {:ok,
       %{
         config_path: Config.config_path(),
         data_dir: saved.data_dir,
         checkouts_dir: saved.checkouts_dir,
         db_path: Config.db_path(saved),
         created: true
       }, &render/1}
    end
  end

  defp choose_paths(config, opts, data) do
    existing = opts[:checkouts] || config.checkouts_dir

    cond do
      existing ->
        {:ok, Path.expand(data), Path.expand(existing)}

      Output.tty?() ->
        with {:ok, data} <- prompt("Data directory", data),
             {:ok, checkouts} <- prompt("Checkout root", Config.default_checkout_dir()) do
          {:ok, Path.expand(data), Path.expand(checkouts)}
        end

      true ->
        {:error,
         Error.new(:usage, "--checkouts is required without a terminal",
           hint: "re-run with --data <dir> --checkouts <dir>"
         )}
    end
  end

  defp check_sync_roots(data, checkouts, opts) do
    synced = Enum.filter([data, checkouts], &Config.sync_root?/1)

    cond do
      synced == [] ->
        :ok

      opts[:force] ->
        :ok

      true ->
        {:error,
         Error.new(:refused, "paths are inside a file-sync root: #{Enum.join(synced, ", ")}",
           hint: "sync tools corrupt git worktrees; choose another path or pass --force"
         )}
    end
  end

  defp save(%Config{} = config, data, checkouts) do
    config = %Config{
      config
      | path: Config.config_path(),
        data_dir: data,
        checkouts_dir: checkouts
    }

    with :ok <- Config.ensure_dirs(config),
         :ok <- Config.save(config),
         {:ok, _} <- ensure_index(config) do
      Index.stop()
      {:ok, config}
    end
  end

  defp ensure_index(config) do
    Index.ensure_started(config)
    {:ok, :started}
  rescue
    error ->
      {:error,
       Error.new(:error, "cannot create the index: #{Exception.message(error)}",
         hint: "check that #{Config.db_path(config)} is writable"
       )}
  end

  defp prompt(label, default) do
    case IO.gets("#{label} [#{default}]: ") do
      :eof ->
        {:error, Error.new(:usage, "setup cancelled")}

      {:error, reason} ->
        {:error, Error.new(:error, "cannot read input: #{inspect(reason)}")}

      input ->
        value = String.trim(input)
        {:ok, if(value == "", do: default, else: value)}
    end
  end

  defp render(%{created: false} = data) do
    IO.puts("gitspace is already configured")
    IO.puts("  config:    #{data.config_path}")
    IO.puts("  data:      #{data.data_dir}")
    IO.puts("  checkouts: #{data.checkouts_dir}")
    IO.puts("  index:     #{data.db_path}")
  end

  defp render(data) do
    IO.puts("gitspace configured")
    IO.puts("  config:    #{data.config_path}")
    IO.puts("  data:      #{data.data_dir}")
    IO.puts("  checkouts: #{data.checkouts_dir}")
    IO.puts("  index:     #{data.db_path}")
  end
end
