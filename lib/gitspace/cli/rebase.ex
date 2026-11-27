defmodule Gitspace.CLI.Rebase do
  @moduledoc false

  alias Gitspace.{Checkouts, Error, RebaseJournal, Repos, Targets}
  alias Gitspace.CLI.Helpers
  alias Gitspace.Git
  alias Gitspace.Git.{Operation, Rebase, Status}
  alias Gitspace.Index.Repository

  def run(global, args) do
    with {:ok, opts, rest} <- Helpers.parse(args, strict()),
         :ok <- validate_options(opts),
         {:ok, mode} <- mode(opts),
         :ok <- confirm_batch_abort(global, opts, mode, rest),
         {:ok, config} <- Helpers.load_config(),
         :ok <- Helpers.start_index(config),
         journal = journal(mode, config),
         {:ok, entries} <- entries(config, rest, mode, journal),
         {:ok, fetch_errors} <- fetch(config, entries, opts) do
      results =
        entries
        |> Enum.map(&execute(&1, mode, fetch_errors, journal))
        |> Enum.map(&refresh(&1, config))

      write_journal(config, mode, results)

      data = %{
        mode: mode,
        fetched: !!opts[:fetch],
        entries: Enum.map(results, &Map.drop(&1, [:checkout, :repo_struct]))
      }

      respond(data)
    end
  end

  defp journal(mode, config) when mode in [:abort, :continue], do: RebaseJournal.load(config)
  defp journal(_mode, _config), do: nil

  defp strict do
    [continue: :boolean, abort: :boolean, fetch: :boolean] ++ Helpers.global_strict()
  end

  defp validate_options(opts) do
    cond do
      opts[:continue] && opts[:abort] ->
        {:error, Error.new(:usage, "--continue and --abort are mutually exclusive")}

      opts[:fetch] && (opts[:continue] || opts[:abort]) ->
        {:error, Error.new(:usage, "--fetch only applies when starting a rebase")}

      true ->
        :ok
    end
  end

  defp mode(opts) do
    cond do
      opts[:continue] -> {:ok, :continue}
      opts[:abort] -> {:ok, :abort}
      true -> {:ok, :start}
    end
  end

  defp confirm_batch_abort(global, opts, :abort, []) do
    Helpers.require_confirmation(global, opts, "abort every in-progress rebase?")
  end

  defp confirm_batch_abort(_global, _opts, _mode, _rest), do: :ok

  defp entries(config, [], mode, journal) do
    checkouts = Checkouts.list(config, kind: "worktree", source: "managed")

    checkouts =
      cond do
        mode == :continue ->
          Enum.filter(checkouts, &Operation.rebase?(Operation.read(&1.path)))

        mode == :abort ->
          paths = journal_paths(journal)

          Enum.filter(
            checkouts,
            &(Operation.rebase?(Operation.read(&1.path)) or MapSet.member?(paths, &1.path))
          )

        true ->
          checkouts
      end

    {:ok, Enum.map(checkouts, &entry_for_checkout/1)}
  end

  defp entries(config, [target], mode, _journal) do
    with {:ok, resolved} <- Targets.resolve(config, target) do
      resolved_entries(resolved, mode)
    end
  end

  defp entries(_config, _rest, _mode, _journal) do
    {:error,
     Error.new(:usage, "usage: gitspace rebase [<target>] [--continue|--abort] [--fetch]")}
  end

  defp resolved_entries({:workspace, workspace}, mode) do
    entries =
      Enum.map(workspace.members, fn member ->
        entry_for_member(workspace, member)
      end)

    entries =
      if mode in [:continue, :abort] do
        Enum.map(entries, &maybe_skip(&1, mode))
      else
        entries
      end

    {:ok, entries}
  end

  defp resolved_entries({:member, workspace, member}, mode) do
    if member.ownership == "borrowed" do
      {:error,
       Error.new(:refused, "#{workspace.name}:#{member_name(member)} is borrowed",
         hint: "borrowed checkouts are never rebased"
       )}
    else
      entry = entry_for_member(workspace, member)
      {:ok, [maybe_skip(entry, mode)]}
    end
  end

  defp resolved_entries({:checkout, checkout}, mode) do
    {:ok, [maybe_skip(entry_for_checkout(checkout), mode)]}
  end

  defp resolved_entries(_resolved, _mode) do
    {:error, Error.new(:usage, "rebase needs a workspace, workspace:member or checkout target")}
  end

  defp entry_for_member(workspace, member) do
    %{
      handle: "#{workspace.name}:#{member_name(member)}",
      path: member.checkout.path,
      ownership: member.ownership,
      checkout: member.checkout,
      repo_struct: repository(member.checkout),
      repo: repo_name(member.checkout),
      skip: nil
    }
  end

  defp entry_for_checkout(checkout) do
    %{
      handle: repo_name(checkout),
      path: checkout.path,
      ownership: nil,
      checkout: checkout,
      repo_struct: repository(checkout),
      repo: repo_name(checkout),
      skip: nil
    }
  end

  defp member_name(member) do
    case member.checkout.repository do
      %Repository{} = repo -> member.name || repo.slug
      _ -> member.name || Path.basename(member.checkout.path)
    end
  end

  defp repo_name(checkout) do
    case repository(checkout) do
      %Repository{} = repo -> repo.slug
      _ -> Path.basename(checkout.path)
    end
  end

  defp repository(%{repository: %Repository{} = repo}), do: repo
  defp repository(%{repository_id: id}), do: Gitspace.Repo.get(Repository, id)

  defp maybe_skip(entry, mode) when mode in [:continue, :abort] do
    if entry.ownership != "borrowed" and not rebase_in_progress?(entry) do
      Map.put(entry, :skip, "no rebase in progress")
    else
      entry
    end
  end

  defp maybe_skip(entry, _mode), do: entry

  defp rebase_in_progress?(entry) do
    Operation.rebase?(Operation.read(entry.path))
  end

  defp fetch(config, entries, opts) do
    if opts[:fetch] do
      do_fetch(config, entries)
    else
      {:ok, %{}}
    end
  end

  defp do_fetch(config, entries) do
    entries
    |> Enum.map(& &1.repo_struct)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq_by(& &1.id)
    |> Enum.reduce(%{}, fn repo, errors ->
      cond do
        is_nil(repo.bare_path) ->
          # External checkouts have their own remote; there is no mirror to fetch.
          errors

        true ->
          case Repos.fetch(config, repo) do
            {:ok, _} -> errors
            {:error, error} -> Map.put(errors, repo.id, error.message)
          end
      end
    end)
    |> then(&{:ok, &1})
  end

  defp execute(entry, :abort, _fetch_errors, journal) do
    operation = Operation.read(entry.path)

    cond do
      entry.ownership == "borrowed" ->
        skipped(entry, "borrowed")

      not File.dir?(entry.path) ->
        failed(entry, :error, "checkout directory is missing", nil)

      operation && Operation.rebase?(operation) ->
        execute_rebase(entry, :abort)

      operation ->
        skipped(entry, Operation.describe(operation))

      true ->
        case RebaseJournal.entry(journal, entry.path) do
          nil -> skipped(entry, "no rebase in progress and no recorded rebase")
          record -> rollback(entry, record)
        end
    end
  end

  defp execute(entry, mode, fetch_errors, _journal) do
    operation = Operation.read(entry.path)

    cond do
      entry.ownership == "borrowed" ->
        skipped(entry, "borrowed")

      not File.dir?(entry.path) ->
        failed(entry, :error, "checkout directory is missing", nil)

      fetch_error = fetch_errors[repo_id(entry)] ->
        failed(entry, :error, "fetch failed: #{fetch_error}", "run `gitspace repo fetch` first")

      entry.skip ->
        skipped(entry, entry.skip)

      mode == :start and operation != nil ->
        skipped(entry, Operation.describe(operation))

      true ->
        execute_rebase(entry, mode)
    end
  end

  defp rollback(entry, record) do
    old = record["old_head"]
    new = record["new_head"]
    branch = record["branch"]

    cond do
      is_nil(old) ->
        skipped(entry, "no recorded pre-rebase head")

      is_nil(new) ->
        skipped(entry, "the recorded rebase did not complete")

      old == new ->
        skipped(entry, "nothing to roll back")

      true ->
        rollback_clean(entry, old, new, branch)
    end
  end

  defp rollback_clean(entry, old, new, branch) do
    case Status.read(entry.path) do
      {:error, reason} ->
        failed(entry, :error, error_text(reason), nil)

      {:ok, status} ->
        cond do
          status.head != new ->
            skipped(entry, "HEAD moved since the rebase; not rolling back")

          status.dirty > 0 or status.untracked > 0 ->
            skipped(entry, "working tree has changes; not rolling back")

          true ->
            reset(entry, old, new, branch)
        end
    end
  end

  defp reset(entry, old, new, branch) do
    anchor(entry.path, old)

    case Git.run(["reset", "--hard", old], cd: entry.path) do
      {:ok, _} ->
        Map.merge(base(entry), %{
          status: :rolled_back,
          branch: branch,
          old_head: new,
          new_head: old,
          commits: nil,
          step: nil,
          total: nil,
          files: [],
          hint: nil
        })

      {:error, result} ->
        failed(
          entry,
          :error,
          last_line(result.stdout <> result.stderr),
          "git reset --hard failed"
        )
    end
  end

  defp anchor(path, head) do
    ref =
      "refs/gitspace/keep/rebase/" <>
        Integer.to_string(System.system_time(:second)) <>
        "-" <>
        Integer.to_string(System.unique_integer([:positive])) <>
        "-" <> String.slice(head, 0, 12)

    _ = Git.run(["update-ref", ref, head], cd: path)
    :ok
  end

  defp repo_id(%{repo_struct: %Repository{id: id}}), do: id
  defp repo_id(_entry), do: nil

  defp execute_rebase(entry, mode) do
    result =
      case mode do
        :start -> Rebase.start(entry.path)
        :continue -> Rebase.continue(entry.path)
        :abort -> Rebase.abort(entry.path)
      end

    case result do
      {:ok, result} ->
        Map.merge(base(entry), Map.drop(result, [:output]))

      {:error, failure} ->
        Map.merge(base(entry), %{
          status: :failed,
          kind: failure.kind,
          error: failure.message,
          hint: failure.hint
        })
    end
  end

  defp skipped(entry, reason) do
    %{
      handle: entry.handle,
      path: entry.path,
      repo: entry.repo,
      ownership: entry.ownership,
      status: :skipped,
      reason: reason,
      checkout: entry.checkout
    }
  end

  defp failed(entry, kind, message, hint) do
    %{
      handle: entry.handle,
      path: entry.path,
      repo: entry.repo,
      ownership: entry.ownership,
      status: :failed,
      kind: kind,
      error: message,
      hint: hint,
      checkout: entry.checkout
    }
  end

  defp refresh(%{checkout: checkout} = entry, config) do
    _ = Checkouts.refresh(config, checkout)
    entry
  end

  defp refresh(entry, _config), do: entry

  defp respond(%{entries: entries} = data) do
    failures = Enum.filter(entries, &(&1.status in [:conflict, :failed]))

    cond do
      failures == [] ->
        {:ok, data, &render/1}

      length(entries) == 1 ->
        failure = hd(failures)
        code = if failure.status == :conflict, do: :conflict, else: failure[:kind] || :refused

        {:partial, data, &render/1,
         Error.new(code, failure_message(failure),
           hint: failure[:hint],
           details: data
         )}

      true ->
        {:partial, data, &render/1,
         Error.new(:partial, "#{length(failures)} rebase(s) need attention",
           hint: Enum.map_join(failures, ", ", & &1.handle),
           details: data
         )}
    end
  end

  defp failure_message(%{status: :conflict} = entry) do
    files = length(List.wrap(entry[:files]))
    "rebase conflict for #{entry.handle} (#{files} file(s))"
  end

  defp failure_message(entry), do: "#{entry.handle}: #{entry[:error] || "rebase failed"}"

  defp render(%{entries: entries, mode: mode}) do
    if entries == [] do
      IO.puts(empty_text(mode))
    else
      Enum.each(entries, fn entry ->
        IO.puts("#{entry.handle}  #{entry.path}")
        render_entry(entry)
        IO.puts("")
      end)
    end
  end

  defp empty_text(:start), do: "(no managed worktrees)"
  defp empty_text(_mode), do: "(no rebase in progress)"

  defp render_entry(entry) do
    if entry[:branch], do: IO.puts("  branch:   #{entry.branch}")
    if entry[:upstream], do: IO.puts("  upstream: #{entry.upstream}")
    IO.puts("  result:   #{result_text(entry)}")

    if entry[:files] not in [nil, []] do
      IO.puts("  files:    #{Enum.join(entry.files, ", ")}")
    end

    if entry[:hint], do: IO.puts("  hint:     #{entry.hint}")
  end

  defp result_text(%{status: :rebased} = entry) do
    "rebased" <> commits_text(entry) <> heads_text(entry)
  end

  defp result_text(%{status: :up_to_date}), do: "up to date"

  defp result_text(%{status: :conflict} = entry) do
    progress =
      if is_integer(entry[:step]) and is_integer(entry[:total]),
        do: " (#{entry.step}/#{entry.total})",
        else: ""

    "conflict#{progress}"
  end

  defp result_text(%{status: :aborted} = entry), do: "aborted" <> heads_text(entry)
  defp result_text(%{status: :rolled_back} = entry), do: "rolled back" <> heads_text(entry)
  defp result_text(%{status: :skipped, reason: reason}), do: "skipped (#{reason})"
  defp result_text(%{status: :failed, error: error}), do: "failed — #{error}"
  defp result_text(entry), do: inspect(entry.status)

  defp commits_text(%{commits: commits}) when is_integer(commits) and commits > 0 do
    if commits == 1, do: " 1 commit", else: " #{commits} commits"
  end

  defp commits_text(_entry), do: ""

  defp heads_text(%{old_head: old, new_head: new}) when is_binary(old) and is_binary(new) do
    " (#{short(old)} -> #{short(new)})"
  end

  defp heads_text(%{new_head: new}) when is_binary(new), do: " (-> #{short(new)})"
  defp heads_text(_entry), do: ""

  defp short(sha), do: String.slice(sha, 0, 7)

  defp base(entry) do
    %{
      handle: entry.handle,
      path: entry.path,
      repo: entry.repo,
      ownership: entry.ownership,
      checkout: entry.checkout
    }
  end

  defp last_line(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.reject(&String.starts_with?(&1, ["warning:", "hint:"]))
    |> List.last()
    |> case do
      nil -> "git reset --hard failed"
      line -> line |> String.replace_prefix("error: ", "") |> String.replace_prefix("fatal: ", "")
    end
  end

  defp journal_paths(nil), do: MapSet.new()

  defp journal_paths(journal) do
    journal
    |> Map.get("entries", [])
    |> Enum.map(& &1["path"])
    |> MapSet.new()
  end

  defp write_journal(config, :start, results) do
    entries =
      results
      |> Enum.flat_map(fn result ->
        case Map.get(result, :old_head) do
          head when is_binary(head) ->
            [
              %{
                "path" => result.path,
                "repo" => result[:repo],
                "branch" => result[:branch],
                "old_head" => head,
                "new_head" => result[:new_head],
                "status" => Atom.to_string(result.status)
              }
            ]

          _ ->
            []
        end
      end)

    RebaseJournal.save(config, %{
      "started_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "entries" => entries
    })
  end

  defp write_journal(config, :continue, results) do
    Enum.each(results, &record_continue(config, &1))
  end

  defp write_journal(_config, _mode, _results), do: :ok

  defp record_continue(config, %{status: :rebased} = result) do
    RebaseJournal.record(config, result.path, %{
      "branch" => result[:branch],
      "new_head" => result[:new_head],
      "status" => "rebased"
    })
  end

  defp record_continue(config, %{status: :conflict} = result) do
    RebaseJournal.record(config, result.path, %{"status" => "conflict"})
  end

  defp record_continue(_config, _result), do: :ok

  defp error_text(%{stderr: stderr}) when is_binary(stderr) and stderr != "",
    do: String.trim(stderr)

  defp error_text(other), do: inspect(other)
end
