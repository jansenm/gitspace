defmodule Gitspace.Scan do
  @moduledoc """
  Read-only discovery of existing clones, worktrees and bare repositories.

  Scanning never fetches, never writes to a checkout, and never changes the
  index. `link/3` is the explicit step that indexes an external checkout.
  """

  import Ecto.Query

  alias Gitspace.{Checkouts, Config, Error, Git, Layout, Projects, Repo, Repos}
  alias Gitspace.Index.{Checkout, Repository}

  @default_ignores ~w(
    .git .hg .svn .idea .vscode .cache .venv venv
    node_modules target _build deps dist build vendor
  )

  @spec scan(Config.t(), [Path.t()], keyword()) :: {:ok, [map()]} | {:error, Error.t()}
  def scan(%Config{} = config, paths, opts \\ []) do
    started =
      if(paths == [],
        do: Enum.uniq([config.projects_root | Enum.map(Projects.list(config), & &1.path)]),
        else: paths
      )
      |> Enum.map(&Path.expand/1)

    max_depth = Keyword.get(opts, :max_depth, 6)
    excludes = Keyword.get(opts, :exclude, [])

    with :ok <- validate_paths(started),
         :ok <- validate_depth(max_depth) do
      indexed = indexed_paths()
      bare = indexed_bare_paths()

      entries =
        started
        |> Enum.flat_map(fn path -> walk(Path.expand(path), 0, max_depth, excludes, []) end)
        |> Enum.uniq_by(& &1.path)
        |> Enum.map(&annotate(&1, indexed, bare))
        |> Enum.sort_by(& &1.path)

      {:ok, entries}
    end
  end

  @doc "Inspects one path. Used by `link`; returns `:none` when it is not a repository."
  @spec detect(Path.t()) :: {:repo, map()} | {:bare, map()} | :none
  def detect(path) do
    path = Path.expand(path)

    cond do
      File.exists?(Path.join(path, ".git")) -> detect_worktree(path)
      bare_repo?(path) -> detect_bare(path)
      true -> :none
    end
  end

  @spec link(Config.t(), Path.t(), keyword()) ::
          {:ok, %{checkout: Checkout.t(), repo: Repository.t(), reused: boolean()}}
          | {:error, Error.t()}
  def link(%Config{} = config, path, opts \\ []) do
    path = Path.expand(path)

    case detect(path) do
      {:repo, entry} ->
        with {:ok, repo} <- find_or_create_repo(config, entry, opts) do
          source =
            if repo.state == "external", do: "external", else: managed_source(config, entry.path)

          case Checkouts.import(config, repo, entry.path, kind: entry.kind, source: source) do
            {:ok, checkout, created?} ->
              {:ok, %{checkout: checkout, repo: repo, reused: not created?}}

            {:error, error} ->
              {:error, error}
          end
        end

      {:bare, entry} ->
        {:error,
         Error.new(:usage, "cannot link a bare repository: #{entry.path}",
           hint: "register it with `gitspace repo add #{entry.remote_url || entry.path}`"
         )}

      :none ->
        {:error, Error.new(:not_found, "not a git checkout: #{path}")}
    end
  end

  @spec unlink(Config.t(), Path.t()) :: {:ok, map()} | {:error, Error.t()}
  def unlink(%Config{} = _config, path) do
    path = Path.expand(path)

    with {:ok, checkout} <- Checkouts.get_by_path(path) do
      if checkout.source == "managed" do
        {:error,
         Error.new(:refused, "#{checkout.path} is a managed checkout",
           hint:
             "use `gitspace workspace rm` or `gitspace prune`; unlink only forgets external checkouts"
         )}
      else
        repo = Repo.get(Repository, checkout.repository_id)
        {:ok, _} = Repo.delete(checkout)

        if (repo && repo.state == "external") and
             Repo.aggregate(from(c in Checkout, where: c.repository_id == ^repo.id), :count) == 0 do
          _ = Repo.delete(repo)
        end

        {:ok, %{path: checkout.path, repository: repo && repo.slug}}
      end
    end
  end

  defp walk(dir, depth, max_depth, excludes, acc) do
    cond do
      depth > max_depth ->
        acc

      excluded?(dir, excludes) ->
        acc

      true ->
        case detect(dir) do
          {:repo, entry} -> [entry | acc]
          {:bare, entry} -> [entry | acc]
          :none -> walk_children(dir, depth + 1, max_depth, excludes, acc)
        end
    end
  end

  defp walk_children(dir, depth, max_depth, excludes, acc) do
    case File.ls(dir) do
      {:ok, names} ->
        names
        |> Enum.reject(&ignored?/1)
        |> Enum.sort()
        |> Enum.reduce(acc, fn name, acc ->
          path = Path.join(dir, name)

          case File.lstat(path) do
            {:ok, %File.Stat{type: :directory}} ->
              walk(path, depth, max_depth, excludes, acc)

            _ ->
              acc
          end
        end)

      {:error, _} ->
        acc
    end
  end

  defp detect_worktree(dir) do
    case Git.run(["rev-parse", "--show-toplevel"], cd: dir) do
      {:ok, %{stdout: top}} ->
        top = Path.expand(String.trim(top))
        kind = if File.regular?(Path.join(top, ".git")), do: "worktree", else: "clone"
        {:repo, build_entry(top, kind)}

      {:error, _} ->
        :none
    end
  end

  defp detect_bare(dir) do
    case Git.run(["rev-parse", "--is-bare-repository"], cd: dir) do
      {:ok, %{stdout: "true" <> _}} -> {:bare, build_entry(dir, "bare")}
      _ -> :none
    end
  end

  defp build_entry(path, kind) do
    branch =
      case Git.run(["rev-parse", "--abbrev-ref", "HEAD"], cd: path) do
        {:ok, %{stdout: out}} ->
          case String.trim(out) do
            "HEAD" -> nil
            "" -> nil
            name -> name
          end

        _ ->
          nil
      end

    head =
      case Git.run(["rev-parse", "HEAD"], cd: path) do
        {:ok, %{stdout: out}} -> String.trim(out)
        _ -> nil
      end

    remote =
      case Git.run(["remote", "get-url", "origin"], cd: path) do
        {:ok, %{stdout: out}} -> out |> String.trim() |> nil_if_empty()
        _ -> nil
      end

    source = remote || path

    %{
      path: path,
      kind: kind,
      branch: branch,
      head: head,
      detached: is_nil(branch),
      remote_url: remote,
      repo_key: Layout.normalize_remote(source),
      repo_slug: slug_or_nil(source)
    }
  end

  defp find_or_create_repo(_config, entry, opts) do
    case Checkouts.get_by_path(entry.path) do
      {:ok, checkout} ->
        {:ok, Repo.get!(Repository, checkout.repository_id)}

      {:error, _} ->
        do_find_or_create_repo(entry, opts)
    end
  end

  defp do_find_or_create_repo(entry, opts) do
    remote_url = entry.remote_url || entry.path

    cond do
      is_nil(entry.remote_url) ->
        find_or_create_local_external(entry, opts)

      repo = Repos.find_by_remote(remote_url) ->
        {:ok, repo}

      slug = opts[:repo] ->
        with {:ok, slug} <- slug!(slug) do
          case Repo.get_by(Repository, slug: slug) do
            nil ->
              create_external(slug, remote_url, entry)

            repo ->
              if repo.remote_key == Layout.normalize_remote(remote_url) do
                {:ok, repo}
              else
                {:error,
                 Error.new(:conflict, "repository #{slug} points at a different remote",
                   hint: "choose another name with --repo",
                   details: %{existing: repo.remote_url, new: remote_url}
                 )}
              end
          end
        end

      true ->
        slug = entry.repo_slug || Path.basename(entry.path)

        case Repo.get_by(Repository, slug: slug) do
          nil ->
            create_external(slug, remote_url, entry)

          repo ->
            if repo.remote_key == entry.repo_key do
              {:ok, repo}
            else
              {:error,
               Error.new(:conflict, "repository #{slug} points at a different remote",
                 hint: "choose another name with --repo",
                 details: %{existing: repo.remote_url, new: remote_url}
               )}
            end
        end
    end
  end

  defp find_or_create_local_external(entry, opts) do
    slug = opts[:repo] || entry.repo_slug || Path.basename(entry.path)

    with {:ok, slug} <- slug!(slug) do
      case Repo.get_by(Repository, slug: slug) do
        nil ->
          attrs = %{
            slug: slug,
            remote_url: "",
            remote_key: "local:" <> Ecto.UUID.generate(),
            origin_kind: "local",
            state: "external",
            bare_path: nil,
            default_branch: entry.branch
          }

          %Repository{}
          |> Repository.changeset(attrs)
          |> Repo.insert()
          |> case do
            {:ok, repo} ->
              {:ok, repo}

            {:error, changeset} ->
              {:error,
               Error.new(:conflict, "cannot index local repository #{slug}",
                 hint: "choose a repository name with --repo",
                 details: %{
                   errors: Ecto.Changeset.traverse_errors(changeset, fn {msg, _} -> msg end)
                 }
               )}
          end

        %Repository{origin_kind: "local"} = repo ->
          {:ok, repo}

        repo ->
          {:error,
           Error.new(:conflict, "repository #{slug} points at a different remote",
             hint: "choose another name with --repo",
             details: %{existing: repo.remote_url, new: entry.path}
           )}
      end
    end
  end

  defp create_external(slug, remote_url, entry) do
    with {:ok, slug} <- external_slug(slug) do
      insert_external(slug, remote_url, entry)
    end
  end

  defp external_slug(slug) do
    case Layout.repo_slug(slug) do
      {:ok, slug} ->
        {:ok, slug}

      {:error, _reason} ->
        {:error,
         Error.new(:usage, "cannot derive a repository name: #{inspect(slug)}",
           hint: "choose one with --repo NAME"
         )}
    end
  end

  defp insert_external(slug, remote_url, entry) do
    %Repository{}
    |> Repository.changeset(%{
      slug: slug,
      remote_url: remote_url,
      remote_key: Layout.normalize_remote(remote_url),
      state: "external",
      default_branch: entry.branch,
      bare_path: nil
    })
    |> Repo.insert()
    |> case do
      {:ok, repo} ->
        {:ok, repo}

      {:error, changeset} ->
        {:error,
         Error.new(:conflict, "cannot index external repository #{slug}",
           hint: "choose a repository name with --repo",
           details: %{errors: Ecto.Changeset.traverse_errors(changeset, fn {msg, _} -> msg end)}
         )}
    end
  end

  defp annotate(entry, indexed_checkouts, indexed_bare) do
    {indexed, repo} =
      if entry.kind == "bare" do
        {Map.has_key?(indexed_bare, entry.path), Map.get(indexed_bare, entry.path)}
      else
        {MapSet.member?(indexed_checkouts, entry.path), nil}
      end

    entry
    |> Map.put(:indexed, indexed)
    |> Map.put(:indexed_repo, repo)
  end

  defp indexed_paths do
    from(c in Checkout, select: c.path)
    |> Repo.all()
    |> MapSet.new()
  end

  defp indexed_bare_paths do
    from(r in Repository, where: not is_nil(r.bare_path), select: {r.bare_path, r.slug})
    |> Repo.all()
    |> Map.new()
  end

  defp managed_source(config, path) do
    expanded = Path.expand(path)

    managed? =
      Enum.any?([config.projects_root | Enum.map(Projects.list(config), & &1.path)], fn root ->
        root = Path.expand(root)
        expanded == root or String.starts_with?(expanded, root <> "/")
      end)

    if managed?, do: "managed", else: "external"
  end

  defp bare_repo?(path) do
    File.dir?(Path.join(path, "objects")) and
      File.regular?(Path.join(path, "HEAD")) and
      File.dir?(Path.join(path, "refs"))
  end

  defp excluded?(dir, excludes) do
    Enum.any?(excludes, fn pattern ->
      glob_match?(dir, pattern) or glob_match?(Path.basename(dir), pattern)
    end)
  end

  defp glob_match?(value, pattern) do
    regex =
      pattern
      |> Regex.escape()
      |> String.replace("\\*", ".*")
      |> String.replace("\\?", ".")

    Regex.match?(~r/^#{regex}$/, value)
  end

  defp ignored?(name), do: name in @default_ignores or String.starts_with?(name, ".")

  defp validate_paths([]),
    do: {:error, Error.new(:usage, "no scan path", hint: "run `gitspace setup` first")}

  defp validate_paths(paths) do
    case Enum.find(paths, &(not File.exists?(&1))) do
      nil -> :ok
      missing -> {:error, Error.new(:not_found, "path does not exist: #{missing}")}
    end
  end

  defp validate_depth(depth) when is_integer(depth) and depth >= 0, do: :ok

  defp validate_depth(_),
    do: {:error, Error.new(:usage, "--max-depth must be a non-negative integer")}

  defp slug!(slug) do
    case Layout.repo_slug(slug) do
      {:ok, slug} -> {:ok, slug}
      {:error, reason} -> {:error, Error.new(:usage, "invalid repository name: #{reason}")}
    end
  end

  defp slug_or_nil(source) do
    case Layout.repo_slug_from_url(source) do
      {:ok, slug} -> slug
      {:error, _} -> nil
    end
  end

  defp nil_if_empty(""), do: nil
  defp nil_if_empty(value), do: value
end
