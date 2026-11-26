defmodule Gitspace.Aliases do
  @moduledoc """
  Repository aliases and disambiguation.

  A repository has a canonical remote key (`github.com/acme/config`) and an
  alias used in commands and checkout paths. Auto aliases use the basename when
  it is unique, and `group-basename` for every member of a clashing basename
  group. Explicit aliases win and may claim the bare basename as an opt-out.
  """

  alias Gitspace.{Error, Layout}

  @type repo :: %{
          required(:remote_key) => String.t(),
          required(:slug) => String.t(),
          optional(:id) => term(),
          optional(:alias_source) => String.t() | nil,
          optional(:basename) => String.t() | nil
        }

  @doc "Human-readable pieces of a canonical remote key."
  @spec describe(String.t()) :: %{
          host: String.t(),
          group: String.t(),
          basename: String.t() | nil,
          local?: boolean()
        }
  def describe(remote_key) when is_binary(remote_key) do
    key = String.trim(remote_key)

    cond do
      key == "" ->
        %{host: "local", group: "local", basename: "repo", local?: true}

      String.starts_with?(key, "local:") ->
        # `local:<uuid>` carries no name. The caller can pass a `:basename`
        # hint from the linked checkout; otherwise the existing alias is kept.
        %{host: "local", group: "local", basename: nil, local?: true}

      String.starts_with?(key, "/") ->
        local_descriptor(key)

      true ->
        remote_descriptor(key)
    end
  end

  @doc """
  Resolves aliases for a set of repositories.

  Returns a map keyed by `:id` (or whatever key the caller supplied). Explicit
  aliases are fixed; auto aliases are recomputed to be globally unique.
  """
  @spec resolve([repo()]) :: {:ok, %{term() => String.t()}} | {:error, Error.t()}
  def resolve(repos) do
    repos = Enum.sort_by(repos, & &1.remote_key)
    explicit = Enum.filter(repos, &(alias_source(&1) == "explicit"))

    with :ok <- validate_explicit(explicit) do
      taken =
        explicit
        |> Enum.map(& &1.slug)
        |> MapSet.new()

      basenames =
        repos
        |> Enum.map(&describe(&1.remote_key).basename)
        |> Enum.frequencies()

      auto = Enum.reject(repos, &(alias_source(&1) == "explicit"))

      bases =
        Map.new(auto, fn repo ->
          descriptor = describe(repo.remote_key)
          {key(repo), base_alias(descriptor, repo, Map.get(basenames, descriptor.basename, 1))}
        end)

      tiers = [
        fn _descriptor, base, _repo -> base end,
        fn descriptor, base, _repo -> descriptor.host <> "-" <> base end,
        fn _descriptor, base, repo ->
          base <> "-" <> String.slice(Layout.remote_hash(repo.remote_key), 0, 8)
        end
      ]

      {assigned, taken, remaining} =
        Enum.reduce(tiers, {%{}, taken, auto}, fn candidate_fun, {assigned, taken, remaining} ->
          {new_assigned, new_taken, left} =
            assign_tier(remaining, bases, candidate_fun, taken)

          {Map.merge(assigned, new_assigned), new_taken, left}
        end)

      assigned = assign_hashed(remaining, assigned, taken)

      explicit_aliases = Map.new(explicit, fn repo -> {key(repo), repo.slug} end)

      {:ok, Map.merge(assigned, explicit_aliases)}
    end
  end

  defp assign_tier(repos, bases, candidate_fun, taken) do
    repos
    |> Enum.group_by(fn repo ->
      descriptor = describe(repo.remote_key)
      base = Map.fetch!(bases, key(repo))
      candidate_fun.(descriptor, base, repo)
    end)
    |> Enum.sort_by(fn {candidate, _repos} -> candidate end)
    |> Enum.reduce({%{}, taken, []}, fn {_candidate, group}, {assigned, taken, left} ->
      case group do
        [repo] ->
          descriptor = describe(repo.remote_key)
          base = Map.fetch!(bases, key(repo))
          candidate = sanitize(candidate_fun.(descriptor, base, repo), "repo")

          if not MapSet.member?(taken, candidate) do
            {Map.put(assigned, key(repo), candidate), MapSet.put(taken, candidate), left}
          else
            {assigned, taken, [repo | left]}
          end

        many ->
          {assigned, taken, many ++ left}
      end
    end)
  end

  defp assign_hashed(repos, assigned, taken) do
    Enum.reduce(repos, assigned, fn repo, assigned ->
      hash = String.slice(Layout.remote_hash(repo.remote_key), 0, 16)
      candidate = sanitize("repo-" <> hash, "repo")

      if MapSet.member?(taken, candidate) do
        Map.put(
          assigned,
          key(repo),
          sanitize(
            "repo-" <> hash <> "-" <> Integer.to_string(System.unique_integer([:positive])),
            "repo"
          )
        )
      else
        Map.put(assigned, key(repo), candidate)
      end
    end)
  end

  @spec describe_remote(String.t()) :: %{
          host: String.t(),
          group: String.t(),
          basename: String.t(),
          local?: boolean()
        }
  def describe_remote(remote_key), do: describe(remote_key)

  defp local_descriptor(path) do
    basename = sanitize(Path.basename(path), "repo")
    parent = sanitize(Path.basename(Path.dirname(path)), "local")
    %{host: "local", group: parent, basename: basename, local?: true}
  end

  defp remote_descriptor(key) do
    case String.split(key, "/", trim: true) do
      [] ->
        %{host: "local", group: "local", basename: "repo", local?: true}

      [host] ->
        %{
          host: sanitize(host, "host"),
          group: "local",
          basename: sanitize(host, "repo"),
          local?: false
        }

      [host, repo] ->
        %{
          host: sanitize(host, "host"),
          group: "local",
          basename: sanitize(repo, "repo"),
          local?: false
        }

      [host | rest] ->
        repo = List.last(rest)
        group = rest |> Enum.drop(-1) |> Enum.join("-")

        %{
          host: sanitize(host, "host"),
          group: sanitize(group, "local"),
          basename: sanitize(repo, "repo"),
          local?: false
        }
    end
  end

  defp sanitize(value, fallback) do
    value = value || fallback

    case Layout.work_slug(value) do
      {:ok, slug} -> slug
      {:error, _} -> fallback
    end
  end

  defp base_alias(%{basename: nil}, repo, _count) do
    Map.get(repo, :basename) || existing_alias(repo)
  end

  defp base_alias(descriptor, _repo, count) do
    if count > 1 do
      descriptor.group <> "-" <> descriptor.basename
    else
      descriptor.basename
    end
  end

  # A local identity has no name of its own. Keep the alias that was chosen
  # when it was created; placeholder aliases from discovery are replaced.
  defp existing_alias(repo) do
    slug = Map.get(repo, :slug)

    if is_binary(slug) and slug != "pending" and not String.starts_with?(slug, "tmp-") do
      sanitize(slug, "local")
    else
      "local"
    end
  end

  defp validate_explicit(repos) do
    Enum.reduce_while(repos, :ok, fn repo, :ok ->
      cond do
        not match?({:ok, _}, Layout.repo_slug(repo.slug)) ->
          {:halt,
           {:error,
            Error.new(:usage, "invalid repository alias: #{repo.slug}",
              hint: "aliases must be one path segment"
            )}}

        true ->
          {:cont, :ok}
      end
    end)
    |> case do
      :ok ->
        duplicates =
          repos
          |> Enum.group_by(& &1.slug)
          |> Enum.filter(fn {_alias, repos} -> length(repos) > 1 end)

        case duplicates do
          [] ->
            :ok

          [{alias_name, _} | _] ->
            {:error,
             Error.new(:conflict, "repository alias is used more than once: #{alias_name}",
               hint: "aliases must be unique"
             )}
        end

      error ->
        error
    end
  end

  defp alias_source(repo), do: Map.get(repo, :alias_source) || "auto"
  defp key(repo), do: Map.get(repo, :id, :new)
end
