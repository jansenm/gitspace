defmodule Gitspace.CLI.Scan do
  @moduledoc false

  alias Gitspace.{Error, Scan}
  alias Gitspace.CLI.{Helpers, Output}

  def scan(_global, args) do
    with {:ok, opts, paths} <- Helpers.parse(args, strict_scan()),
         {:ok, config} <- Helpers.load_config(),
         :ok <- Helpers.start_index(config),
         {:ok, entries} <-
           Scan.scan(config, paths,
             max_depth: opts[:max_depth] || 6,
             exclude: List.wrap(opts[:exclude] || [])
           ) do
      {:ok, %{entries: entries}, &render_scan/1}
    end
  end

  def link(_global, args) do
    with {:ok, opts, rest} <- Helpers.parse(args, strict_link()),
         {:ok, path} <- one_arg(rest, "gitspace link <path>"),
         {:ok, config} <- Helpers.load_config(),
         :ok <- Helpers.start_index(config),
         {:ok, result} <- Scan.link(config, path, repo: opts[:repo]) do
      {:ok,
       %{
         checkout: checkout_map(result.checkout),
         repository: result.repo.slug,
         reused: result.reused
       }, &render_link/1}
    end
  end

  def unlink(_global, args) do
    with {:ok, _opts, rest} <- Helpers.parse(args, Helpers.global_strict()),
         {:ok, path} <- one_arg(rest, "gitspace unlink <path>"),
         {:ok, config} <- Helpers.load_config(),
         :ok <- Helpers.start_index(config),
         {:ok, result} <- Scan.unlink(config, path) do
      {:ok, result, &render_unlink/1}
    end
  end

  defp strict_scan,
    do: [max_depth: :integer, exclude: :keep] ++ Helpers.global_strict()

  defp strict_link, do: [repo: :string] ++ Helpers.global_strict()

  defp one_arg([arg], _usage), do: {:ok, arg}
  defp one_arg(_rest, usage), do: {:error, Error.new(:usage, "usage: #{usage}")}

  defp checkout_map(checkout) do
    %{
      id: checkout.id,
      path: checkout.path,
      kind: checkout.kind,
      source: checkout.source,
      state: checkout.state,
      branch: checkout.branch,
      head: checkout.head_sha
    }
  end

  defp render_scan(%{entries: entries}) do
    Output.table(
      ["KIND", "REPO", "BRANCH", "INDEXED", "PATH"],
      Enum.map(entries, fn entry ->
        [
          entry.kind,
          entry.indexed_repo || entry.repo_slug,
          entry.branch || "(detached)",
          if(entry.indexed, do: "yes", else: "no"),
          entry.path
        ]
      end)
    )
  end

  defp render_link(data) do
    action = if data.reused, do: "already indexed", else: "linked"
    IO.puts("#{action}: #{data.checkout.path}")
    IO.puts("  repository: #{data.repository}")
    IO.puts("  branch:     #{data.checkout.branch || "(detached)"}")
    IO.puts("  source:     #{data.checkout.source}")
  end

  defp render_unlink(data) do
    IO.puts("unlinked #{data.path}")
    if data.repository, do: IO.puts("  repository: #{data.repository}")
  end
end
