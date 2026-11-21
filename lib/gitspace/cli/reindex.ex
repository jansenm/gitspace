defmodule Gitspace.CLI.Reindex do
  @moduledoc false

  alias Gitspace.Index
  alias Gitspace.CLI.Helpers

  def run(_global, args) do
    with {:ok, _opts, rest} <- Helpers.parse(args, Helpers.global_strict()),
         :ok <- Helpers.no_extra_args(rest),
         {:ok, config} <- Helpers.load_config(),
         :ok <- Helpers.start_index(config),
         {:ok, summary} <- Index.reindex(config) do
      {:ok, summary, &render/1}
    end
  end

  defp render(summary) do
    IO.puts("reindexed")
    IO.puts("  projects:          #{Map.get(summary, :projects, 0)}")
    IO.puts("  repositories:     #{summary.repositories}")
    IO.puts("  discovered:       #{summary.discovered_repositories}")
    IO.puts("  imported:         #{summary.imported_checkouts}")
    IO.puts("  missing:          #{summary.missing_checkouts}")
    IO.puts("  workspaces:       #{summary.workspaces}")
    IO.puts("  workspace members: #{summary.workspace_members}")

    Enum.each(summary.issues, fn issue ->
      IO.puts(:stderr, "issue: #{format_issue(issue)}")
    end)

    Enum.each(summary.orphaned_workspaces, fn orphan ->
      IO.puts(:stderr, "warning: #{orphan.workspace} has no marker (run `gitspace doctor`)")
    end)
  end

  defp format_issue(%{kind: :missing_project_path, project: project, path: path}),
    do: "missing_project_path #{project}: #{path}"

  defp format_issue(%{kind: :hash_mismatch} = issue) do
    "hash_mismatch #{issue.path}: expected #{String.slice(issue.expected, 0, 12)}, got #{String.slice(issue.actual, 0, 12)}"
  end

  defp format_issue(%{kind: :missing_from_text} = issue),
    do: "missing_from_text #{issue.remote}"

  defp format_issue(%{kind: :stale_text} = issue), do: "stale_text #{issue.remote}"
  defp format_issue(%{kind: kind, repo: repo, reason: reason}), do: "#{kind} #{repo}: #{reason}"
  defp format_issue(%{kind: kind, path: path, reason: reason}), do: "#{kind} #{path}: #{reason}"
  defp format_issue(%{kind: kind, repo: repo}), do: "#{kind} #{repo}"
  defp format_issue(%{kind: kind, reason: reason}), do: "#{kind}: #{reason}"
  defp format_issue(issue), do: inspect(issue)
end
