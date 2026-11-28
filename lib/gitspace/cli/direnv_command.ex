defmodule Gitspace.CLI.DirenvCommand do
  @moduledoc false

  alias Gitspace.{Direnv, Error}
  alias Gitspace.CLI.Helpers

  def run(_global, args) do
    with {:ok, opts, rest} <- Helpers.parse(args, strict()),
         :ok <- validate(opts, rest),
         {:ok, target} <- target(rest, opts),
         {:ok, config} <- Helpers.load_config(),
         :ok <- Helpers.start_index(config),
         {:ok, plans} <- Direnv.plans(config, target, opts) do
      if opts[:write] do
        write(plans, opts)
      else
        [plan] = plans
        {:ok, %{path: plan.path, body: plan.body}, &render_body/1}
      end
    end
  end

  defp strict do
    [write: :boolean, force: :boolean, members: :boolean, all: :boolean, dry_run: :boolean] ++
      Helpers.global_strict()
  end

  defp validate(opts, rest) do
    cond do
      !!opts[:all] and !!opts[:members] ->
        {:error, Error.new(:usage, "--all and --members are mutually exclusive")}

      !!opts[:all] and rest != [] ->
        {:error, Error.new(:usage, "--all does not take a target")}

      not (!!opts[:write]) and
          (!!opts[:force] or !!opts[:members] or !!opts[:all] or !!opts[:dry_run]) ->
        {:error, Error.new(:usage, "--force, --members, --all and --dry-run need --write")}

      true ->
        :ok
    end
  end

  defp target([], _opts), do: {:ok, "."}
  defp target([target], _opts), do: {:ok, target}

  defp target(_rest, _opts) do
    {:error, Error.new(:usage, "usage: gitspace direnv [target] [--write] [--members|--all]")}
  end

  defp write(plans, opts) do
    case Enum.reduce_while(plans, {:ok, []}, fn plan, {:ok, written} ->
           case Direnv.write(plan, opts) do
             {:ok, plan} -> {:cont, {:ok, [plan | written]}}
             {:error, error} -> {:halt, {:error, error}}
           end
         end) do
      {:ok, written} ->
        data = %{
          dry_run: !!opts[:dry_run],
          plans:
            written
            |> Enum.reverse()
            |> Enum.map(fn plan -> %{path: plan.path, target: plan.target} end)
        }

        {:ok, data, &render_write/1}

      {:error, error} ->
        {:error, error}
    end
  end

  defp render_body(data), do: IO.write(data.body)

  defp shell_quote(value) do
    "'" <> String.replace(value, "'", "'\\''") <> "'"
  end

  defp render_write(data) do
    verb = if data.dry_run, do: "would write", else: "wrote"

    Enum.each(data.plans, fn plan ->
      IO.puts("#{verb} #{plan.path}")
    end)

    unless data.dry_run do
      IO.puts("")

      Enum.each(data.plans, fn plan ->
        IO.puts("direnv allow #{shell_quote(Path.dirname(plan.path))}")
      end)
    end
  end
end
