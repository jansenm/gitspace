defmodule Gitspace.CLI.Helpers do
  @moduledoc false

  alias Gitspace.{Config, Error, Index}
  alias Gitspace.CLI.Output

  @global_strict [
    json: :boolean,
    no_color: :boolean,
    verbose: :boolean,
    yes: :boolean,
    help: :boolean
  ]

  def global_strict, do: @global_strict

  @spec load_config() :: {:ok, Config.t()} | {:error, Error.t()}
  def load_config do
    case Config.load() do
      {:ok, config} ->
        {:ok, config}

      {:error, :not_configured} ->
        {:error,
         Error.new(:not_configured, "gitspace is not configured", hint: "run `gitspace setup`")}

      {:error, reason} ->
        {:error,
         Error.new(:invalid_config, "cannot load configuration: #{format_reason(reason)}",
           hint: "fix #{Config.config_path()} or run `gitspace setup`"
         )}
    end
  end

  @spec start_index(Config.t()) :: :ok | {:error, Error.t()}
  def start_index(%Config{} = config) do
    Index.ensure_started(config)
    :ok
  rescue
    error ->
      {:error,
       Error.new(:error, "cannot open the index: #{Exception.message(error)}",
         hint: "run `gitspace doctor --reindex`"
       )}
  end

  @spec parse([String.t()], keyword(), keyword()) ::
          {:ok, keyword(), [String.t()]} | {:error, Error.t()}
  def parse(args, strict, aliases \\ []) do
    {opts, rest, invalid} = OptionParser.parse(args, strict: strict, aliases: aliases)

    case invalid do
      [] ->
        {:ok, opts, rest}

      [{flag, _value} | _] ->
        {:error, Error.new(:usage, "unknown option: #{flag}", hint: "run `gitspace help`")}
    end
  end

  @spec no_extra_args([String.t()]) :: :ok | {:error, Error.t()}
  def no_extra_args([]), do: :ok

  def no_extra_args(rest) do
    {:error, Error.new(:usage, "unexpected argument: #{Enum.join(rest, " ")}")}
  end

  @spec require_confirmation(map(), keyword(), String.t()) :: :ok | {:error, Error.t()}
  def require_confirmation(global, opts, question) do
    cond do
      opts[:yes] || global.yes ->
        :ok

      global.json ->
        {:error,
         Error.new(:confirmation_required, "confirmation required", hint: "re-run with --yes")}

      Output.tty?() ->
        if Output.confirm?(question) do
          :ok
        else
          {:error, Error.new(:refused, "cancelled")}
        end

      true ->
        {:error,
         Error.new(:confirmation_required, "confirmation required without a terminal",
           hint: "re-run with --yes"
         )}
    end
  end

  def format_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  def format_reason(reason) when is_binary(reason), do: reason
  def format_reason(reason), do: inspect(reason)
end
