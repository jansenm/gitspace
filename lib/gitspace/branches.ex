defmodule Gitspace.Branches do
  @moduledoc """
  Read model for the refs of a repository: local branches, remote branches and
  optionally tags, with the checked-out path and the default branch marked.
  """

  alias Gitspace.{Checkouts, Config, Error, Git, Repos}
  alias Gitspace.Git.Worktree

  @format "%(refname)%00%(objectname:short)%00%(committerdate:short)%00%(subject)"

  @spec list(Config.t(), String.t(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def list(%Config{} = config, selector, opts \\ []) do
    with {:ok, repo} <- Repos.get(config, selector),
         {:ok, root} <- root(config, repo),
         {:ok, refs} <- read_refs(root),
         {:ok, filter} <- filter(opts) do
      checked = checked_out(config, repo, root)

      branches =
        refs
        |> Enum.map(&classify/1)
        |> Enum.reject(&is_nil/1)
        |> maybe_tags(opts[:tags])
        |> Enum.filter(&matches?(&1.name, filter))
        |> Enum.map(&decorate(&1, repo, checked))
        |> Enum.sort_by(&{kind_order(&1.kind), &1.name})

      {:ok,
       %{
         repo: repo.slug,
         remote: repo.remote_url,
         identity: repo.remote_key,
         default_branch: repo.default_branch,
         branches: branches
       }}
    end
  end

  defp root(_config, %{bare_path: bare}) when is_binary(bare) do
    if File.dir?(bare) do
      {:ok, bare}
    else
      {:error, Error.new(:not_found, "mirror is missing: #{bare}")}
    end
  end

  defp root(config, repo) do
    case Checkouts.list(config, repo: repo.slug) do
      [checkout | _] ->
        {:ok, checkout.path}

      [] ->
        {:error,
         Error.new(:not_found, "repository #{repo.slug} has no mirror or checkout",
           hint: "register it with `gitspace repo add` or `repo import`"
         )}
    end
  end

  defp read_refs(root) do
    args = [
      "for-each-ref",
      "--format=#{@format}",
      "refs/heads",
      "refs/remotes/origin",
      "refs/tags"
    ]

    case Git.run(args, cd: root) do
      {:ok, %{stdout: out}} ->
        refs =
          out
          |> String.split("\n", trim: true)
          |> Enum.flat_map(fn line ->
            case String.split(line, "\0", parts: 4) do
              [ref, sha, date, subject] ->
                [%{ref: ref, sha: sha, date: date, subject: subject}]

              _ ->
                []
            end
          end)

        {:ok, refs}

      {:error, result} ->
        {:error,
         Error.new(:error, "cannot list branches: #{String.trim(result.stderr)}",
           details: %{path: root}
         )}
    end
  end

  defp classify(%{ref: "refs/remotes/origin/HEAD"}), do: nil

  defp classify(%{ref: "refs/heads/" <> name} = ref),
    do: Map.merge(ref, %{kind: :local, name: name})

  defp classify(%{ref: "refs/remotes/origin/" <> name} = ref),
    do: Map.merge(ref, %{kind: :remote, name: name})

  defp classify(%{ref: "refs/tags/" <> name} = ref),
    do: Map.merge(ref, %{kind: :tag, name: name})

  defp classify(_ref), do: nil

  defp maybe_tags(branches, true), do: branches
  defp maybe_tags(branches, _), do: Enum.reject(branches, &(&1.kind == :tag))

  defp filter(opts) do
    cond do
      is_binary(opts[:match]) and is_binary(opts[:regex]) ->
        {:error, Error.new(:usage, "--match and --regex are mutually exclusive")}

      is_binary(opts[:match]) ->
        {:ok, {:glob, glob_to_regex(opts[:match])}}

      is_binary(opts[:regex]) ->
        case Regex.compile(opts[:regex]) do
          {:ok, regex} ->
            {:ok, {:regex, regex}}

          {:error, reason} ->
            {:error,
             Error.new(:usage, "invalid regex #{inspect(opts[:regex])}", hint: inspect(reason))}
        end

      true ->
        {:ok, :all}
    end
  end

  defp matches?(_name, :all), do: true
  defp matches?(name, {:glob, regex}), do: Regex.match?(regex, name)
  defp matches?(name, {:regex, regex}), do: Regex.match?(regex, name)

  defp glob_to_regex(glob) do
    Regex.compile!(
      "^" <>
        (glob
         |> Regex.escape()
         |> String.replace("\\*", ".*")
         |> String.replace("\\?", ".")) <>
        "$"
    )
  end

  defp decorate(branch, repo, checked) do
    branch
    |> Map.put(:default, branch.kind in [:local, :remote] and branch.name == repo.default_branch)
    |> Map.put(:checked_out, Map.get(checked, branch.name))
  end

  defp kind_order(:local), do: 0
  defp kind_order(:remote), do: 1
  defp kind_order(:tag), do: 2

  defp checked_out(_config, %{bare_path: bare}, _root) when is_binary(bare) do
    case Worktree.list(bare) do
      {:ok, entries} ->
        entries
        |> Enum.flat_map(fn entry ->
          case Worktree.branch_name(entry) do
            nil -> []
            branch -> [{branch, entry.path}]
          end
        end)
        |> Map.new()

      {:error, _} ->
        %{}
    end
  end

  defp checked_out(config, _repo, _root) do
    config
    |> Checkouts.list()
    |> Enum.flat_map(fn checkout ->
      case checkout.branch do
        nil -> []
        branch -> [{branch, checkout.path}]
      end
    end)
    |> Map.new()
  end
end
