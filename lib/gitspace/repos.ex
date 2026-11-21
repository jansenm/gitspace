defmodule Gitspace.Repos do
  @moduledoc "Registered repositories, aliases and their hashed bare mirrors."

  import Ecto.Query

  alias Gitspace.{Aliases, Config, Error, Git, Layout, MirrorIndex, Projects, Repo}
  alias Gitspace.Git.Mirror
  alias Gitspace.Index.Checkout
  alias Gitspace.Index.Repository

  @type result :: {:ok, Repository.t()} | {:error, Error.t()}

  @doc """
  Registers a remote for mirroring.

  `source` may be a URL or an existing checkout. For a checkout with one remote,
  that remote's URL is registered. With several remotes, pass `remote: "name"`;
  otherwise the call fails and lists the available remotes.
  """
  @spec add(Config.t(), String.t(), keyword()) :: {:ok, Repository.t()} | {:error, Error.t()}
  def add(%Config{} = config, source, opts \\ []) do
    source = String.trim(source)

    with :ok <- validate_url(source),
         {:ok, url, reference} <- resolve_source(source, opts[:remote]),
         key = Layout.normalize_remote(url),
         :ok <- validate_remote_key(key),
         {:ok, requested_alias} <- requested_alias(opts[:name]),
         bare = mirror_path(config, key),
         {:ok, repo, upgrade?} <- prepare(config, url, key, bare),
         mirror_reference = if(opts[:no_fetch], do: nil, else: reference),
         {:ok, saved} <-
           create_or_upgrade(config, repo, url, upgrade?, opts, mirror_reference) do
      overrides =
        if requested_alias do
          %{saved.id => %{alias: requested_alias, source: "explicit"}}
        else
          %{}
        end

      case rebalance_aliases(config, overrides) do
        {:ok, _summary} ->
          saved = Repo.get!(Repository, saved.id)

          cond do
            is_binary(opts[:project]) ->
              with {:ok, _project} <- Projects.ensure_project(config, opts[:project]),
                   {:ok, _project} <- Projects.add_members(config, opts[:project], [saved.slug]) do
                finish_add(config, saved, reference, opts)
              end

            true ->
              finish_add(config, saved, reference, opts)
          end

        {:error, %Error{} = error} ->
          rollback_new_repo(saved, upgrade?, error)
      end
    end
  end

  defp finish_add(config, saved, reference, opts) do
    cond do
      opts[:no_fetch] ->
        with :ok <- sync_index(config), do: {:ok, saved}

      reference ->
        mark_fetched(saved)

      true ->
        case fetch(config, saved) do
          {:ok, fetched} ->
            {:ok, fetched}

          {:error, %Error{} = error} ->
            {:error,
             %{
               error
               | details: Map.merge(error.details, %{repo: saved.slug, registered: true})
             }}
        end
    end
  end

  @spec list(Config.t()) :: [map()]
  def list(%Config{} = _config) do
    counts =
      from(c in Checkout,
        group_by: c.repository_id,
        select: {c.repository_id, count(c.id)}
      )
      |> Repo.all()
      |> Map.new()

    from(r in Repository, order_by: [asc: r.slug])
    |> Repo.all()
    |> Enum.map(fn repo ->
      %{repo: repo, checkouts: Map.get(counts, repo.id, 0)}
    end)
  end

  @spec get(Config.t(), String.t()) :: {:ok, Repository.t()} | {:error, Error.t()}
  def get(%Config{} = _config, selector) do
    selector = String.trim(selector)

    repo =
      Repo.get_by(Repository, slug: selector) ||
        case Ecto.UUID.cast(selector) do
          {:ok, _} -> Repo.get(Repository, selector)
          :error -> nil
        end

    case repo do
      %Repository{} = repo ->
        {:ok, repo}

      nil ->
        resolve_selector(selector)
    end
  end

  @spec get!(Config.t(), String.t()) :: Repository.t()
  def get!(config, selector) do
    case get(config, selector) do
      {:ok, repo} -> repo
      {:error, error} -> raise error
    end
  end

  @spec find_by_remote(String.t()) :: Repository.t() | nil
  def find_by_remote(url) do
    Repo.get_by(Repository, remote_key: Layout.normalize_remote(url))
  end

  @doc "Permanently sets an explicit alias for a repository."
  @spec set_alias(Config.t(), String.t(), String.t()) ::
          {:ok, Repository.t()} | {:error, Error.t()}
  def set_alias(%Config{} = config, selector, alias_name) do
    with {:ok, alias_name} <- requested_alias(alias_name),
         {:ok, repo} <- get(config, selector) do
      case rebalance_aliases(config, %{repo.id => %{alias: alias_name, source: "explicit"}}) do
        {:ok, _summary} ->
          with :ok <- sync_index(config) do
            {:ok, Repo.get!(Repository, repo.id)}
          end

        {:error, error} ->
          {:error, error}
      end
    end
  end

  @doc """
  Recomputes auto aliases for the current repository set.

  Existing checkout directories are never moved. Markers carry the canonical
  remote and the chosen checkout name, so an alias change only affects future
  commands and checkouts.
  """
  @spec rebalance_aliases(Config.t(), map()) :: {:ok, map()} | {:error, Error.t()}
  def rebalance_aliases(%Config{} = config, overrides \\ %{}) do
    repos = Repo.all(Repository)

    effective =
      Enum.map(repos, fn repo ->
        case Map.get(overrides, repo.id) do
          nil ->
            repo

          %{alias: alias_name, source: source} ->
            %{repo | slug: alias_name, alias_source: source}
        end
      end)

    case Aliases.resolve(effective) do
      {:ok, desired} ->
        sources = Map.new(effective, &{&1.id, &1.alias_source})
        apply_alias_changes(config, repos, desired, sources)

      {:error, error} ->
        {:error, error}
    end
  end

  @doc "Writes the hash-to-remote text index from the registered mirrors."
  @spec sync_index(Config.t()) :: :ok | {:error, Error.t()}
  def sync_index(%Config{} = config) do
    repos =
      from(r in Repository, where: not is_nil(r.bare_path))
      |> Repo.all()

    case MirrorIndex.write(config, repos) do
      :ok ->
        :ok

      {:error, reason} ->
        {:error,
         Error.new(:error, "cannot write #{MirrorIndex.path(config)}: #{inspect(reason)}")}
    end
  end

  @doc """
  Registers mirrors found under the data directory.

  The directory and the mirror's `remote.origin.url` are authoritative; the
  text index is rebuilt from them. Mismatches are reported, not hidden.
  """
  @spec discover(Config.t()) :: %{discovered: non_neg_integer(), issues: [map()]}
  def discover(%Config{} = config) do
    entries = mirror_entries(config)
    {registered, issues, overrides} = register_entries(entries)

    issues =
      case rebalance_aliases(config, overrides) do
        {:ok, _summary} -> issues
        {:error, error} -> issues ++ [%{kind: :alias, reason: error.message}]
      end

    _ = sync_index(config)

    %{discovered: length(registered), issues: issues}
  end

  @doc """
  Read-only audit of mirror directories against the index and `remotes.txt`.

  Mirrors and their `remote.origin.url` are authoritative. The audit reports
  hash-name mismatches, unregistered mirrors, stale text entries, and mirrors
  that disagree with the text index; `discover/1` repairs the caches.
  """
  @spec audit_mirrors(Config.t()) :: %{
          mirrors: non_neg_integer(),
          text: non_neg_integer(),
          issues: [map()]
        }
  def audit_mirrors(%Config{} = config) do
    entries = mirror_entries(config)
    indexed = Repo.all(Repository)
    indexed_paths = MapSet.new(indexed, & &1.bare_path)
    indexed_keys = MapSet.new(indexed, & &1.remote_key)
    entry_keys = MapSet.new(entries, & &1.remote_key)

    text =
      case MirrorIndex.read(config) do
        {:ok, text_entries} -> text_entries
        {:error, _} -> []
      end

    text_keys = MapSet.new(text, & &1.remote_key)
    text_by_key = Map.new(text, &{&1.remote_key, &1})

    entry_issues =
      Enum.flat_map(entries, fn entry ->
        []
        |> maybe_issue(
          entry.expected_hash != entry.actual_hash,
          %{
            kind: :hash_mismatch,
            path: entry.bare_path,
            expected: entry.expected_hash,
            actual: entry.actual_hash,
            remote: entry.remote_key
          }
        )
        |> maybe_issue(
          is_nil(entry.origin),
          %{kind: :missing_remote, path: entry.bare_path, repo: entry.alias || entry.remote_key}
        )
        |> maybe_issue(
          not MapSet.member?(indexed_paths, entry.bare_path) and
            not MapSet.member?(indexed_keys, entry.remote_key),
          %{kind: :unregistered_mirror, path: entry.bare_path, remote: entry.remote_key}
        )
        |> maybe_issue(
          not MapSet.member?(text_keys, entry.remote_key),
          %{kind: :missing_from_text, path: entry.bare_path, remote: entry.remote_key}
        )
        |> maybe_text_issue(Map.get(text_by_key, entry.remote_key), entry)
      end)

    stale_text =
      text
      |> Enum.reject(&MapSet.member?(entry_keys, &1.remote_key))
      |> Enum.map(fn entry ->
        %{kind: :stale_text, remote: entry.remote_key, hash: entry.hash}
      end)

    missing_mirrors =
      indexed
      |> Enum.filter(&((&1.state == "managed" and &1.bare_path) && not File.dir?(&1.bare_path)))
      |> Enum.map(fn repo ->
        %{kind: :missing_mirror, repo: repo.slug, path: repo.bare_path}
      end)

    %{
      mirrors: length(entries),
      text: length(text),
      issues: entry_issues ++ stale_text ++ missing_mirrors
    }
  end

  defp maybe_issue(issues, true, issue), do: issues ++ [issue]
  defp maybe_issue(issues, false, _issue), do: issues

  defp maybe_text_issue(issues, nil, _entry), do: issues

  defp maybe_text_issue(issues, text_entry, entry) do
    issues
    |> maybe_issue(
      text_entry.hash != entry.expected_hash,
      %{
        kind: :text_hash_mismatch,
        remote: entry.remote_key,
        text_hash: text_entry.hash,
        expected: entry.expected_hash
      }
    )
    |> maybe_issue(
      is_binary(entry.alias) and text_entry.alias != entry.alias,
      %{
        kind: :text_alias_mismatch,
        remote: entry.remote_key,
        text: text_entry.alias,
        mirror: entry.alias
      }
    )
  end

  @spec fetch(Config.t(), Repository.t()) :: {:ok, Repository.t()} | {:error, Error.t()}
  def fetch(%Config{} = _config, %Repository{} = repo) do
    cond do
      is_nil(repo.bare_path) ->
        {:error,
         Error.new(:refused, "#{repo.slug} has no mirror",
           hint: "it is an external repository; register the remote with `gitspace repo add`"
         )}

      not File.dir?(repo.bare_path) ->
        {:error,
         Error.new(:not_found, "mirror for #{repo.slug} is missing at #{repo.bare_path}",
           hint: "run `gitspace repo add <url> --name #{repo.slug}` again"
         )}

      true ->
        do_fetch(repo)
    end
  end

  @spec fetch_selector(Config.t(), String.t() | :all) ::
          {:ok, [Repository.t()]} | {:error, Error.t()}
  def fetch_selector(config, :all) do
    repos = Repo.all(Repository)

    results =
      Enum.map(repos, fn repo ->
        case fetch(config, repo) do
          {:ok, repo} -> {:ok, repo}
          {:error, error} -> {:error, repo.slug, error}
        end
      end)

    ok = for {:ok, repo} <- results, do: repo
    errors = for {:error, slug, error} <- results, do: {slug, error}

    if errors == [] do
      {:ok, ok}
    else
      {:partial, ok, errors}
    end
  end

  def fetch_selector(config, selector) do
    with {:ok, repo} <- get(config, selector),
         {:ok, repo} <- fetch(config, repo) do
      {:ok, [repo]}
    end
  end

  @spec remove(Config.t(), String.t(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def remove(%Config{} = config, selector, opts \\ []) do
    with {:ok, repo} <- get(config, selector) do
      project_names = Projects.projects_for_repo(config, repo)

      cond do
        project_names != [] ->
          {:error,
           Error.new(:refused, "#{repo.slug} is a member of: #{Enum.join(project_names, ", ")}",
             hint: "remove it from the project first with `gitspace project remove`",
             details: %{projects: project_names}
           )}

        repo.state == "external" ->
          {:error,
           Error.new(:refused, "#{repo.slug} is an external repository",
             hint: "use `gitspace unlink <path>` for its checkouts"
           )}

        true ->
          count = Repo.aggregate(from(c in Checkout, where: c.repository_id == ^repo.id), :count)

          cond do
            count > 0 and !opts[:force] ->
              {:error,
               Error.new(
                 :refused,
                 "#{repo.slug} is used by #{count} checkout(s)",
                 hint:
                   "re-run with --force to remove the mirror and unindex those checkouts; directories are not deleted",
                 details: %{checkouts: count}
               )}

            true ->
              bare = repo.bare_path
              {:ok, _} = Repo.delete(repo)
              if bare && File.dir?(bare), do: File.rm_rf!(bare)
              _ = sync_index(config)

              {:ok,
               %{
                 repository: repo.slug,
                 removed_checkouts: count,
                 mirror_removed: bare,
                 checkouts_kept: count
               }}
          end
      end
    end
  end

  @doc "Imports the mirror's worktrees into the index and marks vanished ones missing."
  @spec sync(Config.t(), Repository.t()) :: {:ok, map()} | {:error, Error.t()}
  def sync(%Config{} = config, %Repository{} = repo) do
    if is_nil(repo.bare_path) or not File.dir?(repo.bare_path) do
      {:error, Error.new(:not_found, "mirror for #{repo.slug} is unavailable")}
    else
      Gitspace.Checkouts.sync_repo(config, repo)
    end
  end

  defp resolve_selector(selector) do
    normalized = normalized_selector(selector)
    last = last_selector_segment(selector, normalized)
    repos = Repo.all(Repository)

    exact =
      Enum.filter(repos, fn repo ->
        repo.slug == selector or
          repo.remote_key == selector or
          (normalized != nil and repo.remote_key == normalized)
      end)

    suffix =
      Enum.filter(repos, fn repo -> suffix_match?(repo.remote_key, selector) end)

    fallback =
      if last do
        Enum.filter(repos, fn repo ->
          Aliases.describe(repo.remote_key).basename == last or repo.slug == last
        end)
      else
        []
      end

    cond do
      exact != [] ->
        resolve_matches(exact, selector)

      suffix != [] ->
        resolve_matches(suffix, selector)

      fallback != [] ->
        resolve_matches(fallback, selector)

      true ->
        {:error,
         Error.new(:not_found, "repository not found: #{selector}",
           hint: "run `gitspace repo ls` to see aliases and remotes"
         )}
    end
  end

  defp resolve_matches([repo], _selector), do: {:ok, repo}

  defp resolve_matches(many, selector) do
    candidates =
      Enum.map(many, fn repo ->
        %{alias: repo.slug, remote: repo.remote_key, mirror: repo.bare_path}
      end)

    {:error,
     Error.new(:ambiguous, "repository selector is ambiguous: #{selector}",
       hint: "use one of: #{Enum.map_join(many, ", ", & &1.slug)}",
       details: %{candidates: candidates}
     )}
  end

  defp normalized_selector(selector) do
    if String.contains?(selector, "://") or String.starts_with?(selector, "/") or
         Regex.match?(~r/^[^@\/]+@[^:\/]+:/, selector) do
      Layout.normalize_remote(selector)
    end
  end

  defp last_selector_segment(selector, normalized) do
    if is_nil(normalized) and String.contains?(selector, "/") do
      selector |> String.split("/", trim: true) |> List.last()
    end
  end

  defp suffix_match?(key, selector) do
    key == selector or
      String.ends_with?(key, "/" <> selector) or
      Aliases.describe(key).basename == selector
  end

  defp prepare(_config, url, key, bare) do
    existing =
      Repo.get_by(Repository, remote_key: key) ||
        Repo.get_by(Repository, bare_path: bare)

    case existing do
      nil ->
        %Repository{
          slug: temp_alias(key),
          remote_url: url,
          remote_key: key,
          bare_path: bare,
          state: "managed",
          alias_source: "auto"
        }

      %Repository{state: "external", bare_path: nil} = repo when repo.remote_key == key ->
        {:ok, %{repo | remote_url: url, bare_path: bare, state: "managed"}, true}

      repo ->
        {:error,
         Error.new(:conflict, "repository already exists: #{repo.slug}",
           hint: "use `gitspace repo fetch #{repo.slug}` to update it",
           details: %{alias: repo.slug, remote: repo.remote_url, mirror: repo.bare_path}
         )}
    end
    |> case do
      {:ok, repo, upgrade?} ->
        {:ok, repo, upgrade?}

      %Repository{} = repo ->
        {:ok, repo, false}

      {:error, error} ->
        {:error, error}
    end
  end

  defp create_or_upgrade(config, repo, url, upgrade?, _opts, reference) do
    bare = repo.bare_path

    if File.exists?(bare) do
      {:error,
       Error.new(:conflict, "mirror path already exists: #{bare}",
         hint: "the mirror is not in the index; run `gitspace reindex` or remove it"
       )}
    else
      File.mkdir_p!(Path.dirname(bare))

      mirror_opts =
        if reference do
          [reference: reference]
        else
          [no_fetch: true]
        end

      with {:ok, _} <- safe_mirror(bare, url, mirror_opts),
           :ok <- set_mirror_identity(repo, repo.slug, repo.alias_source),
           {:ok, saved} <- save_repo(repo, upgrade?) do
        _ = sync_index(config)
        {:ok, saved}
      else
        {:error, %Error{} = error} ->
          _ = File.rm_rf(bare)
          {:error, error}
      end
    end
  end

  defp save_repo(repo, true) do
    repo
    |> Ecto.Changeset.change(%{
      state: "managed",
      bare_path: repo.bare_path,
      remote_url: repo.remote_url,
      remote_key: repo.remote_key
    })
    |> Repo.update()
    |> case do
      {:ok, repo} -> {:ok, repo}
      {:error, changeset} -> {:error, changeset_error(changeset)}
    end
  end

  defp save_repo(repo, false) do
    %Repository{}
    |> Repository.changeset(%{
      slug: repo.slug,
      remote_url: repo.remote_url,
      remote_key: repo.remote_key,
      bare_path: repo.bare_path,
      state: "managed",
      alias_source: repo.alias_source
    })
    |> Repo.insert()
    |> case do
      {:ok, repo} -> {:ok, repo}
      {:error, changeset} -> {:error, changeset_error(changeset)}
    end
  end

  defp apply_alias_changes(config, repos, desired, sources) do
    changes =
      Enum.filter(repos, fn repo ->
        Map.get(desired, repo.id, repo.slug) != repo.slug or
          Map.get(sources, repo.id, repo.alias_source) != repo.alias_source
      end)

    if changes == [] do
      {:ok, %{changed: []}}
    else
      now = DateTime.utc_now()

      result =
        Repo.transaction(fn ->
          Enum.each(changes, fn repo ->
            from(r in Repository, where: r.id == ^repo.id)
            |> Repo.update_all(set: [slug: temp_slug(repo.id), updated_at: now])
          end)

          Enum.each(changes, fn repo ->
            from(r in Repository, where: r.id == ^repo.id)
            |> Repo.update_all(
              set: [
                slug: Map.fetch!(desired, repo.id),
                alias_source: Map.fetch!(sources, repo.id),
                updated_at: now
              ]
            )
          end)
        end)

      case result do
        {:ok, _} ->
          updated = Repo.all(Repository)

          issues =
            Enum.flat_map(updated, fn repo ->
              case set_mirror_identity(
                     repo,
                     Map.get(desired, repo.id, repo.slug),
                     repo.alias_source
                   ) do
                :ok -> []
                {:error, error} -> [%{repo: repo.slug, reason: error.message}]
              end
            end)

          _ = sync_index(config)

          if issues == [] do
            {:ok, %{changed: Enum.map(changes, &Map.fetch!(desired, &1.id))}}
          else
            {:error,
             Error.new(:partial, "aliases changed but mirror metadata was not fully written",
               details: %{issues: issues}
             )}
          end

        {:error, reason} ->
          {:error, Error.new(:error, "cannot update repository aliases: #{inspect(reason)}")}
      end
    end
  end

  defp set_mirror_identity(%Repository{bare_path: nil}, _alias, _source), do: :ok

  defp set_mirror_identity(repo, alias_name, source) do
    with {:ok, _} <- Git.run(["config", "gitspace.alias", alias_name], cd: repo.bare_path),
         {:ok, _} <- Git.run(["config", "gitspace.alias-source", source], cd: repo.bare_path),
         {:ok, _} <-
           Git.run(["config", "gitspace.remote-key", repo.remote_key], cd: repo.bare_path) do
      :ok
    else
      {:error, result} ->
        {:error,
         Error.new(:error, "cannot write mirror alias for #{repo.slug}: #{result.stderr}")}
    end
  end

  defp mirror_entries(config) do
    dir = Config.repos_dir(config)

    case File.ls(dir) do
      {:ok, entries} ->
        entries
        |> Enum.filter(&String.ends_with?(&1, ".git"))
        |> Enum.map(&Path.join(dir, &1))
        |> Enum.filter(&bare_repo?/1)
        |> Enum.map(&mirror_entry/1)

      {:error, _} ->
        []
    end
  end

  defp mirror_entry(bare) do
    remote = read_config(bare, ["config", "--get", "remote.origin.url"])
    remote_url = remote || bare
    key = Layout.normalize_remote(remote_url)
    expected_hash = Layout.remote_hash(key)
    actual_hash = bare |> Path.basename() |> String.replace_suffix(".git", "")
    alias_name = read_config(bare, ["config", "--get", "gitspace.alias"])

    source =
      normalize_alias_source(read_config(bare, ["config", "--get", "gitspace.alias-source"]))

    %{
      bare_path: bare,
      origin: remote,
      remote_url: remote_url,
      remote_key: key,
      expected_hash: expected_hash,
      actual_hash: actual_hash,
      alias: alias_name,
      alias_source: source
    }
  end

  defp register_entries(entries) do
    Enum.reduce(entries, {[], [], %{}}, fn entry, {registered, issues, overrides} ->
      issues =
        if entry.actual_hash != entry.expected_hash do
          [
            %{
              kind: :hash_mismatch,
              path: entry.bare_path,
              expected: entry.expected_hash,
              actual: entry.actual_hash,
              remote: entry.remote_key
            }
            | issues
          ]
        else
          issues
        end

      issues =
        if is_nil(entry.origin) do
          [%{kind: :missing_remote, path: entry.bare_path, remote: entry.remote_key} | issues]
        else
          issues
        end

      case register_entry(entry) do
        {:ok, repo} ->
          overrides =
            if entry.alias_source == "explicit" and is_binary(entry.alias) do
              Map.put(overrides, repo.id, %{alias: entry.alias, source: "explicit"})
            else
              overrides
            end

          {[repo.id | registered], issues, overrides}

        {:error, error} ->
          {registered, [%{kind: :repository, reason: error.message} | issues], overrides}
      end
    end)
  end

  defp register_entry(entry) do
    existing =
      Repo.get_by(Repository, remote_key: entry.remote_key) ||
        Repo.get_by(Repository, bare_path: entry.bare_path)

    attrs = %{
      bare_path: entry.bare_path,
      remote_url: entry.remote_url,
      remote_key: entry.remote_key,
      state: "managed"
    }

    attrs =
      if is_binary(entry.alias) do
        Map.put(attrs, :alias_source, entry.alias_source)
      else
        attrs
      end

    cond do
      existing && is_nil(entry.origin) ->
        existing
        |> Ecto.Changeset.change(%{
          bare_path: entry.bare_path,
          state: "managed",
          default_branch: default_branch_or_existing(entry, existing)
        })
        |> Repo.update()

      existing ->
        existing
        |> Ecto.Changeset.change(
          Map.put(attrs, :default_branch, default_branch_or_existing(entry, existing))
        )
        |> Repo.update()

      is_nil(entry.origin) ->
        {:error,
         Error.new(:error, "mirror has no remote.origin.url: #{entry.bare_path}",
           hint: "restore the origin remote in the mirror or remove it"
         )}

      true ->
        %Repository{}
        |> Repository.changeset(
          Map.merge(attrs, %{
            slug: temp_alias(entry.remote_key),
            alias_source: Map.get(attrs, :alias_source, "auto"),
            default_branch: Mirror.default_branch(entry.bare_path)
          })
        )
        |> Repo.insert()
    end
    |> case do
      {:ok, repo} -> {:ok, repo}
      {:error, changeset} -> {:error, changeset_error(changeset)}
    end
  end

  defp default_branch_or_existing(entry, existing) do
    existing.default_branch || Mirror.default_branch(entry.bare_path)
  end

  defp normalize_alias_source("explicit"), do: "explicit"
  defp normalize_alias_source(_), do: "auto"

  defp read_config(bare, args) do
    case Git.run(args, cd: bare) do
      {:ok, %{stdout: out}} ->
        case String.trim(out) do
          "" -> nil
          value -> value
        end

      {:error, _} ->
        nil
    end
  end

  defp do_fetch(repo) do
    Mirror.fetch!(repo.bare_path, timeout: 300_000)
    mark_fetched(repo)
  rescue
    error in Git.Error ->
      message = Exception.message(error)

      repo
      |> Ecto.Changeset.change(%{last_fetch_error: message})
      |> Repo.update!()

      {:error,
       Error.new(:error, "fetch failed for #{repo.slug}: #{message}",
         hint: "check the remote and credentials; the mirror is unchanged"
       )}
  end

  defp mark_fetched(repo) do
    default_branch = Mirror.default_branch(repo.bare_path) || repo.default_branch

    updated =
      repo
      |> Ecto.Changeset.change(%{
        last_fetched_at: DateTime.utc_now(),
        last_fetch_error: nil,
        default_branch: default_branch
      })
      |> Repo.update!()

    invalidate_statuses(repo.id)
    {:ok, updated}
  end

  defp invalidate_statuses(repository_id) do
    from(c in Checkout, where: c.repository_id == ^repository_id)
    |> Repo.update_all(set: [last_status_at: nil])
  end

  defp safe_mirror(bare, url, opts) do
    {:ok, Mirror.init!(bare, url, opts)}
  rescue
    error in Git.Error ->
      {:error,
       Error.new(:error, "cannot create mirror: #{Exception.message(error)}",
         hint: "check the URL and that the remote is reachable"
       )}
  end

  defp rollback_new_repo(repo, false, error) do
    _ = Repo.delete(repo)
    if repo.bare_path && File.dir?(repo.bare_path), do: File.rm_rf!(repo.bare_path)
    {:error, error}
  end

  defp rollback_new_repo(_repo, true, error), do: {:error, error}

  defp requested_alias(nil), do: {:ok, nil}

  defp requested_alias(name) do
    case Layout.repo_slug(name) do
      {:ok, slug} ->
        {:ok, slug}

      {:error, reason} ->
        {:error, Error.new(:usage, "invalid repository alias #{inspect(name)}: #{reason}")}
    end
  end

  defp mirror_path(config, key) do
    Path.join(Config.repos_dir(config), Layout.remote_hash(key) <> ".git")
  end

  defp temp_alias(key) do
    base = "tmp-" <> String.slice(Layout.remote_hash(key), 0, 12)

    if Repo.get_by(Repository, slug: base) do
      base <> "-" <> Integer.to_string(System.unique_integer([:positive]))
    else
      base
    end
  end

  defp temp_slug(id), do: "tmp-" <> String.replace(id, "-", "")

  defp validate_remote_key(""),
    do: {:error, Error.new(:usage, "cannot derive a canonical remote from this URL")}

  defp validate_remote_key(_key), do: :ok

  defp validate_url(""), do: {:error, Error.new(:usage, "repository URL is required")}
  defp validate_url(_), do: :ok

  defp resolve_source(source, remote_name) do
    path = Path.expand(source)

    cond do
      File.dir?(path) ->
        case list_remotes(path) do
          :not_a_repository ->
            {:error,
             Error.new(:usage, "not a git checkout: #{source}",
               hint: "pass a remote URL or point at an existing checkout"
             )}

          [] ->
            {:error,
             Error.new(:usage, "checkout has no remotes: #{path}",
               hint: "add a remote to the checkout or pass its remote URL instead"
             )}

          names ->
            select_remote(path, names, remote_name)
        end

      remote_name ->
        {:error, Error.new(:usage, "--remote requires an existing local git checkout: #{source}")}

      true ->
        {:ok, source, nil}
    end
  end

  defp list_remotes(path) do
    case Git.run(["remote"], cd: path) do
      {:ok, %{stdout: out}} -> out |> String.split("\n", trim: true)
      {:error, _} -> :not_a_repository
    end
  end

  defp select_remote(path, [name], nil) do
    with {:ok, url} <- remote_url_for(path, name), do: {:ok, url, path}
  end

  defp select_remote(path, names, nil) do
    remotes = Enum.map(names, &remote_candidate(path, &1))

    {:error,
     Error.new(:usage, "checkout has multiple remotes: #{Enum.join(names, ", ")}",
       hint: "choose one with `--remote <name>`",
       details: %{path: path, remotes: remotes}
     )}
  end

  defp select_remote(path, names, name) do
    if name in names do
      with {:ok, url} <- remote_url_for(path, name), do: {:ok, url, path}
    else
      {:error,
       Error.new(:usage, "checkout has no remote named #{name}",
         hint: "available remotes: #{Enum.join(names, ", ")}",
         details: %{path: path, remotes: names}
       )}
    end
  end

  defp remote_url_for(path, name) do
    case read_config(path, ["config", "--get", "remote.#{name}.url"]) do
      nil ->
        {:error,
         Error.new(:usage, "remote #{name} has no URL", details: %{path: path, remote: name})}

      url ->
        {:ok, resolve_local_remote(url, repository_root(path))}
    end
  end

  defp remote_candidate(path, name) do
    %{name: name, url: read_config(path, ["config", "--get", "remote.#{name}.url"])}
  end

  defp repository_root(path) do
    case Git.run(["rev-parse", "--show-toplevel"], cd: path) do
      {:ok, %{stdout: out}} ->
        String.trim(out)

      {:error, _} ->
        case Git.run(["rev-parse", "--absolute-git-dir"], cd: path) do
          {:ok, %{stdout: out}} -> String.trim(out)
          {:error, _} -> path
        end
    end
  end

  defp resolve_local_remote(url, root) do
    if remote_url?(url), do: url, else: Path.expand(url, root)
  end

  defp remote_url?(url) do
    Regex.match?(~r/^[A-Za-z][A-Za-z0-9+.-]*:\/\//, url) or
      Regex.match?(~r/^(?:[^@\/]+@)?[^:\/]+:.+$/, url) or
      Path.type(url) == :absolute
  end

  defp bare_repo?(path) do
    File.dir?(Path.join(path, "objects")) and
      File.regular?(Path.join(path, "HEAD")) and
      File.dir?(Path.join(path, "refs"))
  end

  defp changeset_error(changeset) do
    Error.new(:conflict, "cannot save repository",
      details: %{errors: Ecto.Changeset.traverse_errors(changeset, fn {msg, _} -> msg end)}
    )
  end
end
