defmodule Gitspace.Layout do
  @moduledoc """
  Work names, branch templates and checkout paths.

  The work name is the primary input: it names the directory and derives the
  branch. This module is pure so it can be property-tested without git.
  """

  @max_length 60
  @invalid ~r/[^A-Za-z0-9._-]+/
  @scp_remote ~r/^(?:[^@\/]+@)?([^:\/]+):(.+)$/
  @default_ports %{"http" => 80, "https" => 443, "ssh" => 22, "git" => 9418, "ftp" => 21}

  @doc """
  Turns a piece of work into a path-safe slug.

  Preserves case so ticket names stay recognizable. Collapses invalid runs to
  `-`, trims separators, and truncates with a hash suffix.
  """
  @spec work_slug(String.t()) :: {:ok, String.t()} | {:error, atom()}
  def work_slug(name) when is_binary(name) do
    trimmed = String.trim(name)

    if trimmed in [".", ".."] do
      {:error, :invalid}
    else
      slug =
        trimmed
        |> String.replace(@invalid, "-")
        |> collapse()
        |> trim_separators()
        |> String.trim_leading(".")

      cond do
        slug == "" -> {:error, :empty}
        true -> {:ok, truncate(slug)}
      end
    end
  end

  @spec work_slug!(String.t()) :: String.t()
  def work_slug!(name) do
    case work_slug(name) do
      {:ok, slug} -> slug
      {:error, reason} -> raise ArgumentError, "invalid work name #{inspect(name)}: #{reason}"
    end
  end

  @doc "Slug for a ref used as a default work name (`hotfix/timeout` -> `hotfix-timeout`)."
  @spec ref_slug(String.t()) :: {:ok, String.t()} | {:error, atom()}
  def ref_slug(ref), do: ref |> String.replace("/", "-") |> work_slug()

  @doc """
  Derives the branch from the work name.

  The default template is `feature/{topic}`. `{work}` is accepted as a
  backwards-compatible placeholder for `{topic}`.
  """
  @spec branch_for(String.t(), String.t()) :: {:ok, String.t()} | {:error, atom()}
  def branch_for(work, template \\ "feature/{topic}") do
    with {:ok, slug} <- work_slug(work) do
      branch =
        template
        |> String.replace("{topic}", slug)
        |> String.replace("{work}", slug)

      if valid_branch?(branch), do: {:ok, branch}, else: {:error, :invalid_branch}
    end
  end

  @doc "Absolute checkout path for an owned member."
  @spec path(Path.t(), String.t(), String.t()) :: {:ok, Path.t()} | {:error, atom()}
  def path(root, work, repo) do
    with {:ok, work_slug} <- work_slug(work),
         {:ok, repo_slug} <- repo_slug(repo) do
      root = Path.expand(root)
      path = Path.join([root, work_slug, repo_slug])

      if within?(path, root), do: {:ok, path}, else: {:error, :outside_root}
    end
  end

  @spec marker_path(Path.t(), String.t()) :: {:ok, Path.t()} | {:error, atom()}
  def marker_path(root, work) do
    with {:ok, work_slug} <- work_slug(work) do
      {:ok, Path.join([Path.expand(root), work_slug, ".gitspace.json"])}
    end
  end

  @doc "A repo name must be a single path segment."
  @spec repo_slug(String.t()) :: {:ok, String.t()} | {:error, atom()}
  def repo_slug(repo) when is_binary(repo) do
    if String.contains?(repo, ["/", "\\", "\0"]) do
      {:error, :invalid_repo}
    else
      work_slug(repo)
    end
  end

  @doc """
  Derives a repository slug from a remote URL or local path.

  Handles scp-like (`git@host:org/repo.git`), URL, and plain path forms.
  """
  @spec repo_slug_from_url(String.t()) :: {:ok, String.t()} | {:error, atom()}
  def repo_slug_from_url(source) when is_binary(source) do
    case remote_path(source) do
      nil ->
        {:error, :invalid_remote}

      path ->
        base =
          path
          |> String.trim_trailing("/")
          |> Path.basename()
          |> String.replace_suffix(".git", "")

        repo_slug(base)
    end
  end

  @spec repo_slug_from_url!(String.t()) :: String.t()
  def repo_slug_from_url!(source) do
    case repo_slug_from_url(source) do
      {:ok, slug} -> slug
      {:error, reason} -> raise ArgumentError, "invalid remote #{inspect(source)}: #{reason}"
    end
  end

  @doc """
  Canonical key for matching the same repository across remote syntaxes.

  Credentials are dropped, `.git` and trailing slashes are stripped, and the
  host is lowercased. Local paths are expanded.
  """
  @spec normalize_remote(String.t()) :: String.t()
  def normalize_remote(source) when is_binary(source) do
    source = String.trim(source)

    cond do
      source == "" ->
        ""

      scheme?(source) ->
        uri = URI.parse(source)
        normalize_uri(uri, source)

      match = Regex.run(@scp_remote, source) ->
        [_, host, path] = match
        clean_key(String.downcase(host) <> "/" <> path)

      true ->
        clean_key(Path.expand(source))
    end
  end

  defp normalize_uri(
         %URI{scheme: scheme, host: host, path: path, port: port},
         _source
       )
       when scheme in ["http", "https", "ssh", "git"] and is_binary(host) do
    clean_key(host_with_port(scheme, String.downcase(host), port) <> (path || ""))
  end

  defp normalize_uri(%URI{scheme: "file", path: path}, _source), do: clean_key(Path.expand(path))

  defp normalize_uri(%URI{path: path}, source) when is_binary(path) do
    cond do
      String.starts_with?(source, ["/", "./", "../", "~"]) -> clean_key(Path.expand(path))
      true -> clean_key(source)
    end
  end

  defp normalize_uri(_uri, source), do: clean_key(source)

  defp clean_key(value) do
    value
    |> String.trim_trailing("/")
    |> String.replace_suffix(".git", "")
  end

  defp host_with_port(_scheme, host, nil), do: host

  defp host_with_port(scheme, host, port) do
    if Map.get(@default_ports, scheme) == port do
      host
    else
      "#{host}:#{port}"
    end
  end

  defp remote_path(source) do
    source = String.trim(source)

    cond do
      source == "" ->
        nil

      scheme?(source) ->
        case URI.parse(source) do
          %URI{path: path} -> path
        end

      match = Regex.run(@scp_remote, source) ->
        [_, _host, path] = match
        path

      true ->
        source
    end
  end

  defp scheme?(source), do: Regex.match?(~r/^[A-Za-z][A-Za-z0-9+.-]*:\/\//, source)

  @spec valid_branch?(String.t()) :: boolean()
  def valid_branch?(branch) when is_binary(branch) do
    branch != "" and
      not String.contains?(branch, [" ", "..", "@{", "\\", "\0", "~", "^", ":"]) and
      not String.starts_with?(branch, ["-", "/", "."]) and
      not String.ends_with?(branch, ["/", ".", ".lock"]) and
      Regex.match?(~r/^[A-Za-z0-9._\/-]+$/, branch)
  end

  @doc """
  Validation for a user-supplied git ref.

  Broader than a branch name: tags and commit SHAs are allowed, but the
  characters that make a ref ambiguous or option-like are not.
  """
  @spec valid_ref?(String.t()) :: boolean()
  def valid_ref?(ref) when is_binary(ref) do
    ref != "" and
      not String.contains?(ref, [" ", "..", "@{", "\\", "\0", "~", "^", ":", "?", "*", "["]) and
      not String.contains?(ref, "//") and
      not String.starts_with?(ref, ["-", "/", "."]) and
      not String.ends_with?(ref, ["/", ".", ".lock"]) and
      not Regex.match?(~r/[\x00-\x1f\x7f]/, ref)
  end

  @doc "Stable SHA-256 of a canonical remote key, lowercase hex."
  @spec remote_hash(String.t()) :: String.t()
  def remote_hash(remote_key) when is_binary(remote_key) do
    :crypto.hash(:sha256, remote_key)
    |> Base.encode16(case: :lower)
  end

  defp within?(path, root) do
    path == root or String.starts_with?(path, root <> "/")
  end

  defp collapse(value), do: Regex.replace(~r/-{2,}/, value, "-")

  defp trim_separators(value), do: Regex.replace(~r/^[.\-]+|[.\-]+$/, value, "")

  defp truncate(slug) when byte_size(slug) <= @max_length, do: slug

  defp truncate(slug) do
    hash =
      :crypto.hash(:sha256, slug)
      |> Base.encode16(case: :lower)
      |> binary_part(0, 8)

    String.slice(slug, 0, @max_length - 9) <> "-" <> hash
  end
end
