defmodule Gitspace.CLI.Doctor do
  @moduledoc false

  import Ecto.Query

  alias Gitspace.{Config, Git, Index, Keep, Marker, Projects, Repo, Repos, Safety}
  alias Gitspace.Git.Worktree
  alias Gitspace.Index.{Checkout, Workspace}
  alias Gitspace.CLI.Helpers

  def run(_global, args) do
    with {:ok, opts, rest} <- Helpers.parse(args, strict()),
         :ok <- Helpers.no_extra_args(rest),
         {:ok, config} <- Helpers.load_config(),
         :ok <- Helpers.start_index(config) do
      fixes = if opts[:fix], do: fix(config), else: []
      reindex = if opts[:reindex], do: reindex(config), else: nil
      checks = checks(config)
      summary = summarize(checks)

      {:ok,
       %{
         checks: checks,
         fixes: fixes,
         reindex: reindex,
         summary: summary,
         ready: summary.fail == 0
       }, &render/1}
    end
  end

  defp strict, do: [fix: :boolean, reindex: :boolean] ++ Helpers.global_strict()

  defp checks(config) do
    [
      check_git(config),
      check_paths(config),
      check_index(),
      check_repositories(config),
      check_mirrors(config),
      check_checkouts(),
      check_workspaces(config),
      check_keep(config),
      check_sync(config)
    ]
  end

  defp check_git(config) do
    case Git.run(["version"]) do
      {:ok, %{stdout: output}} ->
        version = git_version(output)
        minimum = normalize_version(config.git_minimum)

        cond do
          is_nil(version) ->
            check("git", "fail", "cannot parse git version: #{String.trim(output)}")

          Version.parse(version) == :error or Version.parse(minimum) == :error ->
            check(
              "git",
              "fail",
              "cannot compare git #{version} with minimum #{config.git_minimum}"
            )

          Version.compare(version, minimum) in [:eq, :gt] ->
            check("git", "ok", "#{version} (minimum #{config.git_minimum})")

          true ->
            check("git", "fail", "#{version} is below the minimum #{config.git_minimum}")
        end

      {:error, result} ->
        check("git", "fail", "git is unavailable: #{result.stderr}")
    end
  end

  defp check_paths(config) do
    paths =
      [
        {"data", config.data_dir},
        {"projects", config.projects_root},
        {"repos", Config.repos_dir(config)}
      ] ++
        Enum.map(Projects.list(config), fn project ->
          {"project #{project.name}", project.path}
        end)

    problems =
      Enum.flat_map(paths, fn {label, path} ->
        cond do
          not File.dir?(path) -> ["#{label} missing: #{path}"]
          not writable?(path) -> ["#{label} not writable: #{path}"]
          true -> []
        end
      end)

    if problems == [] do
      check("paths", "ok", "data, projects and repos are writable")
    else
      check("paths", "fail", Enum.join(problems, "; "))
    end
  end

  defp check_index do
    migrations = Ecto.Migrator.migrations(Repo, Index.migrations_path())
    pending = Enum.count(migrations, fn {direction, _version, _name} -> direction == :down end)
    journal = journal_mode()

    cond do
      pending > 0 ->
        check("index", "fail", "#{pending} pending migration(s)")

      journal != "wal" ->
        check("index", "warn", "journal_mode is #{journal || "unknown"}, expected wal")

      true ->
        check("index", "ok", "schema current, #{length(migrations)} migration(s), wal")
    end
  rescue
    error -> check("index", "fail", "cannot inspect the index: #{Exception.message(error)}")
  end

  defp check_mirrors(config) do
    audit = Repos.audit_mirrors(config)
    counts = Enum.frequencies_by(audit.issues, & &1.kind)

    if audit.issues == [] do
      check(
        "mirrors",
        "ok",
        "#{audit.mirrors} hash mirror(s), remotes.txt in sync (#{audit.text} entries)"
      )
    else
      check(
        "mirrors",
        "warn",
        "#{audit.mirrors} mirror(s), #{audit.text} text entries; " <>
          Enum.map_join(counts, ", ", fn {kind, count} -> "#{count} #{kind}" end) <>
          "; run `gitspace doctor --fix` or `gitspace reindex`"
      )
    end
  end

  defp check_repositories(config) do
    rows = Repos.list(config)

    results =
      Enum.map(rows, fn %{repo: repo} ->
        cond do
          repo.state == "external" ->
            :external

          is_nil(repo.bare_path) or not File.dir?(repo.bare_path) ->
            :missing_mirror

          true ->
            case Worktree.list(repo.bare_path) do
              {:ok, entries} -> {:prunable, Enum.count(entries, & &1.prunable)}
              {:error, _} -> :broken
            end
        end
      end)

    managed = Enum.count(results, &(&1 != :external))
    external = Enum.count(results, &(&1 == :external))
    missing = Enum.count(results, &(&1 == :missing_mirror))
    broken = Enum.count(results, &(&1 == :broken))

    prunable =
      Enum.reduce(results, 0, fn
        {:prunable, count}, acc -> acc + count
        _, acc -> acc
      end)

    failed_fetches = Enum.count(rows, fn %{repo: repo} -> repo.last_fetch_error end)

    cond do
      missing > 0 or broken > 0 ->
        check(
          "repositories",
          "fail",
          "#{managed} managed, #{external} external, #{missing} missing mirrors, #{broken} unreadable"
        )

      prunable > 0 or failed_fetches > 0 ->
        check(
          "repositories",
          "warn",
          "#{managed} managed, #{external} external, #{prunable} prunable worktree(s), #{failed_fetches} fetch error(s)"
        )

      true ->
        check("repositories", "ok", "#{managed} managed, #{external} external")
    end
  end

  defp legacy_marker?({_dir, marker}) do
    name = marker["workspace"]
    not (is_binary(name) and String.contains?(name, "@"))
  end

  defp check_checkouts do
    checkouts = Repo.all(Checkout)
    missing = Enum.count(checkouts, &(not File.dir?(&1.path)))
    broken = Enum.count(checkouts, &(&1.state == "broken"))
    stale = Enum.count(checkouts, &is_nil(&1.last_status_at))

    cond do
      missing > 0 ->
        check(
          "checkouts",
          "warn",
          "#{length(checkouts)} indexed, #{missing} missing director(ies)"
        )

      broken > 0 ->
        check("checkouts", "fail", "#{length(checkouts)} indexed, #{broken} broken")

      stale > 0 ->
        check("checkouts", "ok", "#{length(checkouts)} indexed, #{stale} without cached status")

      true ->
        check("checkouts", "ok", "#{length(checkouts)} indexed")
    end
  end

  defp check_keep(config) do
    summary = Keep.summary(config)

    cond do
      summary.total == 0 ->
        check("keep", "ok", "no keep refs")

      summary.redundant > 0 ->
        check(
          "keep",
          "warn",
          "#{summary.total} keep ref(s), #{summary.redundant} redundant; run gitspace keep prune"
        )

      true ->
        oldest = if summary.oldest_days, do: ", oldest #{summary.oldest_days}d", else: ""
        check("keep", "ok", "#{summary.total} keep ref(s)#{oldest}")
    end
  end

  defp check_workspaces(config) do
    active = Repo.aggregate(from(w in Workspace, where: w.state == "active"), :count)

    {markers, bad} =
      config
      |> Projects.list()
      |> Enum.reduce({[], []}, fn project, {markers, bad} ->
        if File.dir?(project.path) do
          {:ok, found, invalid} = Marker.find_all(project.path)
          {markers ++ found, bad ++ invalid}
        else
          {markers, bad ++ [{project.path, :missing_project_path}]}
        end
      end)

    legacy = Enum.count(markers, &legacy_marker?/1)

    marker_paths =
      MapSet.new(markers, fn {dir, _} -> Path.join(dir, Marker.marker_filename()) end)

    orphans =
      from(w in Workspace, where: w.state == "active", select: {w.name, w.marker_path})
      |> Repo.all()
      |> Enum.reject(fn {_name, path} -> path && MapSet.member?(marker_paths, path) end)

    cond do
      bad != [] ->
        check(
          "workspaces",
          "warn",
          "#{active} active, #{length(markers)} markers, #{length(bad)} invalid marker(s)"
        )

      legacy > 0 ->
        check(
          "workspaces",
          "warn",
          "#{active} active, #{legacy} legacy project/topic marker(s); recreate as project@topic"
        )

      orphans != [] ->
        check(
          "workspaces",
          "warn",
          "#{active} active, #{length(markers)} markers, #{length(orphans)} without marker"
        )

      true ->
        check("workspaces", "ok", "#{active} active, #{length(markers)} marker(s)")
    end
  end

  defp check_sync(config) do
    synced =
      [config.data_dir, config.projects_root | Enum.map(Projects.list(config), & &1.path)]
      |> Enum.uniq()
      |> Enum.filter(&Config.sync_root?/1)

    if synced == [] do
      check("sync", "ok", "no sync roots in use")
    else
      check("sync", "warn", "inside a file-sync root: #{Enum.join(synced, ", ")}")
    end
  end

  defp fix(config) do
    discovery = Repos.discover(config)

    prunes =
      Repo.all(Gitspace.Index.Repository)
      |> Enum.filter(&(&1.bare_path && File.dir?(&1.bare_path)))
      |> Enum.map(&anchor_and_prune/1)

    keep = Keep.prune(config, older_than: nil)

    [
      %{
        kind: :mirrors,
        discovered: discovery.discovered,
        issues: length(discovery.issues)
      },
      %{kind: :keep, pruned: length(keep.pruned), errors: length(keep.errors)}
      | prunes
    ]
  end

  defp anchor_and_prune(repo) do
    case Worktree.list(repo.bare_path) do
      {:ok, entries} ->
        prunable = Enum.filter(entries, & &1.prunable)
        anchored = Enum.count(prunable, &anchor_if_needed(repo.bare_path, &1))

        case Worktree.prune(repo.bare_path) do
          {:ok, _} ->
            %{repo: repo.slug, prunable: length(prunable), anchored: anchored, pruned: true}

          {:error, result} ->
            %{
              repo: repo.slug,
              prunable: length(prunable),
              anchored: anchored,
              error: result.stderr
            }
        end

      {:error, result} ->
        %{repo: repo.slug, error: result.stderr}
    end
  end

  defp anchor_if_needed(bare, entry) do
    cond do
      is_nil(entry.head) ->
        false

      reachable?(bare, entry.head) ->
        false

      true ->
        ref =
          "refs/gitspace/keep/doctor/#{String.slice(entry.head, 0, 8)}-#{System.system_time(:second)}"

        Safety.anchor!(bare, ref, entry.head)
        true
    end
  end

  defp reachable?(bare, sha) do
    case Git.run(["rev-list", "-1", sha, "--not", "--branches", "--remotes", "--tags"], cd: bare) do
      # Empty output means every commit is already reachable from a ref.
      {:ok, %{stdout: out}} -> String.trim(out) == ""
      {:error, _} -> false
    end
  end

  defp reindex(config) do
    {:ok, summary} = Index.reindex(config)
    summary
  end

  defp journal_mode do
    case Ecto.Adapters.SQL.query(Repo, "PRAGMA journal_mode", []) do
      {:ok, %{rows: [[mode]]}} -> mode
      _ -> nil
    end
  end

  defp writable?(dir) do
    probe = Path.join(dir, ".gitspace-doctor-#{System.unique_integer([:positive])}")

    case File.write(probe, "") do
      :ok ->
        _ = File.rm(probe)
        true

      {:error, _} ->
        false
    end
  end

  defp git_version(output) do
    case Regex.run(~r/(\d+\.\d+\.\d+)/, output) do
      [_, version] -> version
      _ -> nil
    end
  end

  defp normalize_version(version) do
    case String.split(version, ".") do
      [major, minor] -> "#{major}.#{minor}.0"
      _ -> version
    end
  end

  defp check(name, status, detail), do: %{name: name, status: status, detail: detail}

  defp summarize(checks) do
    %{
      ok: Enum.count(checks, &(&1.status == "ok")),
      warn: Enum.count(checks, &(&1.status == "warn")),
      fail: Enum.count(checks, &(&1.status == "fail"))
    }
  end

  defp render(data) do
    IO.puts("gitspace doctor")

    Enum.each(data.checks, fn check ->
      IO.puts("  [#{check.status}] #{String.pad_trailing(check.name, 14)} #{check.detail}")
    end)

    Enum.each(data.fixes, fn fix ->
      cond do
        fix[:kind] == :mirrors ->
          IO.puts("  fixed mirrors: #{fix.discovered} registered, #{fix.issues} issue(s) remain")

        fix[:error] ->
          IO.puts(:stderr, "fix #{fix.repo}: #{fix.error}")

        true ->
          IO.puts("  fixed #{fix.repo}: #{fix.anchored} anchored, #{fix.prunable} prunable")
      end
    end)

    if data.reindex do
      IO.puts(
        "  reindexed: #{data.reindex.repositories} repositories, #{data.reindex.workspaces} workspaces"
      )
    end

    IO.puts("#{data.summary.ok} ok · #{data.summary.warn} warn · #{data.summary.fail} fail")
  end
end
