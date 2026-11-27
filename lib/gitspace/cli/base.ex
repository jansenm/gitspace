defmodule Gitspace.CLI.Base do
  @moduledoc false

  alias Gitspace.{Checkouts, Error, Targets}
  alias Gitspace.CLI.{Helpers, Output}
  alias Gitspace.Git
  alias Gitspace.Git.{Refs, Status}

  def run(_global, args) do
    with {:ok, opts, rest} <- Helpers.parse(args, strict()),
         {:ok, target, ref} <- target_and_ref(rest, opts),
         {:ok, config} <- Helpers.load_config(),
         :ok <- Helpers.start_index(config),
         {:ok, entries} <- entries(config, target) do
      case ref do
        :show -> report(entries)
        :clear -> clear(entries)
        ref -> set(entries, ref)
      end
    end
  end

  defp strict, do: [clear: :boolean] ++ Helpers.global_strict()

  defp target_and_ref([target], opts) do
    cond do
      opts[:clear] -> {:ok, target, :clear}
      true -> {:ok, target, :show}
    end
  end

  defp target_and_ref([target, ref], opts) do
    cond do
      opts[:clear] ->
        {:error, Error.new(:usage, "--clear and a ref are mutually exclusive")}

      String.trim(ref) == "" ->
        {:error, Error.new(:usage, "ref cannot be empty")}

      true ->
        {:ok, target, String.trim(ref)}
    end
  end

  defp target_and_ref(_rest, _opts) do
    {:error,
     Error.new(:usage, "usage: gitspace base <target> [<ref>|--clear]",
       hint: "targets: workspace, workspace:member, checkout or repo"
     )}
  end

  defp entries(config, target) do
    with {:ok, resolved} <- Targets.resolve(config, target) do
      case resolved do
        {:workspace, workspace} ->
          {:ok, Enum.map(workspace.members, &from_member(workspace, &1))}

        {:member, workspace, member} ->
          entry = from_member(workspace, member)
          if entry.borrowed, do: {:error, borrowed(entry)}, else: {:ok, [entry]}

        {:checkout, checkout} ->
          {:ok, [from_checkout(checkout)]}

        {:repo, repo} ->
          {:ok, config |> Checkouts.list(repo: repo.slug) |> Enum.map(&from_checkout/1)}

        _ ->
          {:error,
           Error.new(:usage, "base needs a workspace, workspace:member, checkout or repo target")}
      end
    end
  end

  defp from_member(workspace, member) do
    %{
      handle: "#{workspace.name}:#{member_name(member)}",
      path: member.checkout.path,
      repo: repo_name(member.checkout),
      borrowed: member.ownership == "borrowed"
    }
  end

  defp from_checkout(checkout) do
    %{
      handle: repo_name(checkout),
      path: checkout.path,
      repo: repo_name(checkout),
      borrowed: false
    }
  end

  defp member_name(member) do
    case member.checkout.repository do
      %Gitspace.Index.Repository{} = repo -> member.name || repo.slug
      _ -> member.name || Path.basename(member.checkout.path)
    end
  end

  defp repo_name(checkout) do
    case repository(checkout) do
      %Gitspace.Index.Repository{} = repo -> repo.slug
      _ -> Path.basename(checkout.path)
    end
  end

  defp repository(%{repository: %Gitspace.Index.Repository{} = repo}), do: repo
  defp repository(%{repository_id: id}), do: Gitspace.Repo.get(Gitspace.Index.Repository, id)

  defp report(entries) do
    with {:ok, rows} <- collect(entries) do
      {:ok, %{entries: rows}, &render/1}
    end
  end

  defp collect(entries) do
    entries
    |> Enum.reject(& &1.borrowed)
    |> Enum.reduce_while({:ok, []}, fn entry, {:ok, acc} ->
      case describe(entry) do
        {:ok, row} -> {:cont, {:ok, [row | acc]}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
    |> case do
      {:ok, rows} -> {:ok, Enum.reverse(rows)}
      {:error, error} -> {:error, error}
    end
  end

  defp describe(entry) do
    if File.dir?(entry.path) do
      describe_checkout(entry)
    else
      row(entry, nil, nil, "checkout missing")
    end
  end

  defp describe_checkout(entry) do
    case Status.read(entry.path) do
      {:ok, %Status{detached: true}} ->
        row(entry, nil, nil, "detached")

      {:ok, %Status{branch: nil}} ->
        row(entry, nil, nil, "no branch")

      {:ok, %Status{branch: branch} = status} ->
        recorded = Refs.recorded_base(entry.path, status)
        effective = Refs.rebase_base(entry.path, status)

        {base, source} =
          case {recorded, effective} do
            {{:ok, base}, _} -> {base, "recorded"}
            {{:stale, base}, _} -> {base, "recorded (missing)"}
            {:none, {:ok, base}} -> {base, "upstream"}
            {:none, {:missing, base}} -> {base, "upstream (missing)"}
            {:none, :none} -> {nil, nil}
          end

        row(entry, branch, base, source)

      {:error, result} ->
        {:error,
         Error.new(:error, "cannot read #{entry.handle}: #{last_line(result)}",
           details: %{path: entry.path}
         )}
    end
  end

  defp row(entry, branch, base, source) do
    {:ok,
     %{
       handle: entry.handle,
       repo: entry.repo,
       path: entry.path,
       branch: branch,
       base: base,
       source: source
     }}
  end

  defp set(entries, ref) do
    with {:ok, targets} <- validate(entries, ref),
         :ok <- write(targets, ref) do
      report(entries)
    end
  end

  defp clear(entries) do
    with {:ok, targets} <- validate(entries, nil),
         :ok <- unset(targets) do
      report(entries)
    end
  end

  defp validate(entries, ref) do
    entries
    |> Enum.reject(& &1.borrowed)
    |> Enum.reduce_while({:ok, []}, fn entry, {:ok, acc} ->
      case branch_for(entry, ref) do
        {:ok, target} -> {:cont, {:ok, [target | acc]}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
    |> case do
      {:ok, []} ->
        {:error, Error.new(:not_found, "no owned checkout to update")}

      {:ok, targets} ->
        {:ok, Enum.reverse(targets)}

      {:error, error} ->
        {:error, error}
    end
  end

  defp branch_for(entry, ref) do
    cond do
      not File.dir?(entry.path) ->
        {:error,
         Error.new(:error, "#{entry.handle}: checkout directory is missing",
           details: %{path: entry.path}
         )}

      true ->
        case Status.read(entry.path) do
          {:ok, %Status{detached: true}} ->
            {:error,
             Error.new(:refused, "#{entry.handle} is detached",
               hint: "check out a branch before changing its base"
             )}

          {:ok, %Status{branch: nil}} ->
            {:error,
             Error.new(:refused, "#{entry.handle} has no branch checked out",
               hint: "check out a branch before changing its base"
             )}

          {:ok, %Status{branch: branch}} ->
            if is_nil(ref) or ref_exists?(entry.path, ref) do
              {:ok, {entry, branch}}
            else
              {:error,
               Error.new(:not_found, "ref #{ref} not found in #{entry.handle}",
                 hint: "fetch it first with `gitspace repo fetch #{entry.repo}`",
                 details: %{path: entry.path, repo: entry.repo}
               )}
            end

          {:error, result} ->
            {:error,
             Error.new(:error, "cannot read #{entry.handle}: #{last_line(result)}",
               details: %{path: entry.path}
             )}
        end
    end
  end

  defp ref_exists?(path, ref) do
    case Git.run(["rev-parse", "--verify", "--quiet", ref <> "^{commit}"], cd: path) do
      {:ok, %{stdout: out}} -> String.trim(out) != ""
      {:error, _} -> false
    end
  end

  defp write(targets, ref) do
    Enum.reduce_while(targets, :ok, fn {entry, branch}, :ok ->
      case Refs.set_recorded_base(entry.path, branch, ref) do
        :ok ->
          {:cont, :ok}

        {:error, result} ->
          {:halt,
           {:error,
            Error.new(:error, "cannot update #{entry.handle}: #{last_line(result)}",
              details: %{path: entry.path}
            )}}
      end
    end)
  end

  defp unset(targets) do
    Enum.reduce_while(targets, :ok, fn {entry, branch}, :ok ->
      case Refs.clear_recorded_base(entry.path, branch) do
        :ok ->
          {:cont, :ok}

        {:error, result} ->
          {:halt,
           {:error,
            Error.new(:error, "cannot update #{entry.handle}: #{last_line(result)}",
              details: %{path: entry.path}
            )}}
      end
    end)
  end

  defp last_line(result) do
    (result.stdout <> result.stderr)
    |> String.split("\n", trim: true)
    |> List.last()
    |> case do
      nil -> "git config failed"
      line -> line |> String.replace_prefix("error: ", "") |> String.replace_prefix("fatal: ", "")
    end
  end

  defp borrowed(entry) do
    Error.new(:refused, "#{entry.handle} is borrowed",
      hint: "borrowed checkouts are not managed by gitspace"
    )
  end

  defp render(%{entries: entries}) do
    rows =
      Enum.map(entries, fn entry ->
        [entry.handle, entry.branch, entry.base, entry.source]
      end)

    Output.table(["HANDLE", "BRANCH", "BASE", "SOURCE"], rows)
  end
end
