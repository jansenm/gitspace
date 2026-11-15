defmodule Gitspace.Layout do
  @moduledoc """
  Work names, branch templates and checkout paths.

  The work name is the primary input: it names the directory and derives the
  branch. This module is pure so it can be property-tested without git.
  """

  @max_length 60
  @invalid ~r/[^A-Za-z0-9._-]+/

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
        |> String.trim("-.")
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

  The default template is `feature_{work}`; the result must be a valid branch.
  """
  @spec branch_for(String.t(), String.t()) :: {:ok, String.t()} | {:error, atom()}
  def branch_for(work, template \\ "feature_{work}") do
    with {:ok, slug} <- work_slug(work) do
      branch = String.replace(template, "{work}", slug)

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

  @spec valid_branch?(String.t()) :: boolean()
  def valid_branch?(branch) when is_binary(branch) do
    branch != "" and
      not String.contains?(branch, [" ", "..", "@{", "\\", "\0", "~", "^", ":"]) and
      not String.starts_with?(branch, ["-", "/", "."]) and
      not String.ends_with?(branch, ["/", ".", ".lock"]) and
      Regex.match?(~r/^[A-Za-z0-9._\/-]+$/, branch)
  end

  defp within?(path, root) do
    path == root or String.starts_with?(path, root <> "/")
  end

  defp collapse(value), do: Regex.replace(~r/-{2,}/, value, "-")

  defp truncate(slug) when byte_size(slug) <= @max_length, do: slug

  defp truncate(slug) do
    hash =
      :crypto.hash(:sha256, slug)
      |> Base.encode16(case: :lower)
      |> binary_part(0, 8)

    String.slice(slug, 0, @max_length - 9) <> "-" <> hash
  end
end
