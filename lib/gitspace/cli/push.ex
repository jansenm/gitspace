defmodule Gitspace.CLI.Push do
  @moduledoc false

  alias Gitspace.{Checkouts, Error, Targets}
  alias Gitspace.CLI.Helpers
  alias Gitspace.Git.Publish
  alias Gitspace.Index.Repository

  def run(_global, args) do
    with {:ok, opts, rest} <- Helpers.parse(args, strict()),
         {:ok, target} <- one_arg(rest),
         {:ok, force} <- force_mode(opts),
         {:ok, config} <- Helpers.load_config(),
         :ok <- Helpers.start_index(config),
         {:ok, resolved} <- Targets.resolve(config, target),
         {:ok, entries} <- entries(resolved) do
      results =
        entries
        |> Enum.map(&push_entry(&1, opts, force))
        |> Enum.map(&refresh(&1, config))

      data = %{
        target: target,
        dry_run: !!opts[:dry_run],
        force: force,
        entries: Enum.map(results, &Map.drop(&1, [:checkout]))
      }

      respond(data)
    end
  end

  defp strict do
    [dry_run: :boolean, remote: :string, force: :boolean, force_with_lease: :boolean] ++
      Helpers.global_strict()
  end

  defp force_mode(opts) do
    cond do
      !!opts[:force] and !!opts[:force_with_lease] ->
        {:error, Error.new(:usage, "--force and --force-with-lease are mutually exclusive")}

      opts[:force] ->
        {:ok, :force}

      opts[:force_with_lease] ->
        {:ok, :force_with_lease}

      true ->
        {:ok, nil}
    end
  end

  defp one_arg([arg]), do: {:ok, arg}

  defp one_arg(_rest) do
    {:error, Error.new(:usage, "usage: gitspace push <workspace|workspace:member|checkout>")}
  end

  defp entries({:workspace, workspace}) do
    {:ok, Enum.map(workspace.members, &entry_for(workspace, &1))}
  end

  defp entries({:member, workspace, member}) do
    if member.ownership == "borrowed" do
      {:error,
       Error.new(:refused, "#{workspace.name}:#{member_name(member)} is borrowed",
         hint: "borrowed checkouts are never pushed"
       )}
    else
      {:ok, [entry_for(workspace, member)]}
    end
  end

  defp entries({:checkout, checkout}) do
    {:ok, [checkout_entry(checkout)]}
  end

  defp entries(_resolved) do
    {:error, Error.new(:usage, "push needs a workspace, workspace:member or checkout target")}
  end

  defp entry_for(workspace, member) do
    %{
      handle: "#{workspace.name}:#{member_name(member)}",
      path: member.checkout.path,
      ownership: member.ownership,
      checkout: member.checkout
    }
  end

  defp checkout_entry(checkout) do
    %{
      handle: checkout_handle(checkout),
      path: checkout.path,
      ownership: nil,
      checkout: checkout
    }
  end

  defp member_name(member) do
    case member.checkout.repository do
      %Repository{} = repo -> member.name || repo.slug
      _ -> member.name || Path.basename(member.checkout.path)
    end
  end

  defp checkout_handle(checkout) do
    case checkout.repository do
      %Repository{} = repo -> repo.slug
      _ -> Path.basename(checkout.path)
    end
  end

  defp push_entry(%{ownership: "borrowed"} = entry, _opts, _force) do
    Map.merge(entry, %{
      status: :skipped,
      reason: "borrowed",
      branch: nil,
      remote: nil,
      upstream: nil,
      commits: 0
    })
  end

  defp push_entry(entry, opts, force) do
    base = Map.drop(entry, [:checkout])

    if not File.dir?(entry.path) do
      Map.merge(base, %{
        status: :failed,
        kind: :error,
        error: "checkout directory is missing",
        hint: nil,
        branch: nil,
        remote: nil,
        upstream: nil,
        commits: 0
      })
    else
      run_push(base, entry.path, opts, force)
    end
  end

  defp run_push(base, path, opts, force) do
    case Publish.run(path, dry_run: opts[:dry_run], remote: opts[:remote], force: force) do
      {:ok, %{status: :rejected} = result} ->
        Map.merge(base, Map.put(result, :kind, :conflict))

      {:ok, result} ->
        Map.merge(base, result)

      {:error, failure} ->
        Map.merge(base, %{
          status: :failed,
          kind: failure.kind,
          error: failure.message,
          hint: failure.hint,
          branch: nil,
          remote: nil,
          upstream: nil,
          commits: 0
        })
    end
  end

  defp refresh(%{checkout: checkout, status: :pushed} = entry, config) do
    _ = Checkouts.refresh(config, checkout)
    entry
  end

  defp refresh(entry, _config), do: entry

  defp respond(%{entries: entries} = data) do
    failures = Enum.filter(entries, &(&1.status in [:failed, :rejected]))

    cond do
      failures == [] ->
        {:ok, data, &render/1}

      length(entries) == 1 ->
        failure = hd(failures)
        code = if failure.status == :rejected, do: :conflict, else: failure[:kind] || :refused

        {:error, Error.new(code, failure_message(failure), hint: failure[:hint], details: data)}

      true ->
        {:partial, data, &render/1,
         Error.new(:partial, "#{length(failures)} push(es) failed",
           hint: Enum.map_join(failures, ", ", & &1.handle),
           details: data
         )}
    end
  end

  defp failure_message(%{status: :rejected, reason: reason} = entry) do
    "push rejected for #{entry.handle}#{if reason, do: ": " <> reason, else: ""}"
  end

  defp failure_message(entry), do: "#{entry.handle}: #{entry[:error] || "push failed"}"

  defp render(%{entries: entries}) do
    Enum.each(entries, fn entry ->
      IO.puts("#{entry.handle}  #{entry.path}")

      if entry[:branch], do: IO.puts("  branch:   #{entry.branch}")
      if entry[:remote], do: IO.puts("  remote:   #{entry.remote} (#{entry.upstream})")
      IO.puts("  result:   #{result_text(entry)}")
      if entry[:note], do: IO.puts("  note:     #{entry.note}")
      if entry[:hint], do: IO.puts("  hint:     #{entry.hint}")

      if dirty?(entry) do
        IO.puts(
          "  note:     #{entry.dirty} modified and #{entry.untracked} untracked files are not pushed"
        )
      end

      IO.puts("")
    end)
  end

  defp result_text(%{status: :pushed, commits: commits} = entry),
    do: "pushed #{commits_text(commits)}" <> force_text(entry)

  defp result_text(%{status: :up_to_date}), do: "up to date"

  defp result_text(%{status: :rejected, reason: reason}),
    do: "rejected#{if reason, do: " — " <> reason}"

  defp result_text(%{status: :would_push, commits: commits} = entry),
    do: "would push #{commits_text(commits)}" <> force_text(entry)

  defp result_text(%{status: :would_reject, reason: reason}),
    do: "would be rejected#{if reason, do: " — " <> reason}"

  defp result_text(%{status: :skipped, reason: reason}), do: "skipped (#{reason})"
  defp result_text(%{status: :failed, error: error}), do: "failed — #{error}"
  defp result_text(entry), do: inspect(entry.status)

  defp force_text(%{force: :force}), do: " (forced)"
  defp force_text(%{force: :force_with_lease}), do: " (forced with lease)"
  defp force_text(_entry), do: ""

  defp commits_text(1), do: "1 commit"
  defp commits_text(count), do: "#{count} commits"

  defp dirty?(entry), do: (entry[:dirty] || 0) > 0 or (entry[:untracked] || 0) > 0
end
