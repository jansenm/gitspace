defmodule Gitspace.MirrorIndex do
  @moduledoc """
  Human-readable map of mirror hashes to canonical remotes.

  `remotes.txt` is a cache, not the source of truth: mirror directories and their
  `remote.origin.url` win when they disagree. Reindex and doctor rebuild it.
  """

  alias Gitspace.{Config, Layout}

  @filename "remotes.txt"
  @header "# sha256\tidentity\talias\talias-source\n"

  @spec path(Config.t()) :: Path.t()
  def path(%Config{} = config), do: Path.join(Config.repos_dir(config), @filename)

  @spec write(Config.t(), [map()]) :: :ok | {:error, term()}
  def write(%Config{} = config, repos) do
    path = path(config)
    File.mkdir_p!(Path.dirname(path))
    tmp = path <> ".tmp"

    body =
      repos
      |> Enum.sort_by(& &1.remote_key)
      |> Enum.map_join("", fn repo ->
        [
          mirror_hash(repo),
          "\t",
          repo.remote_key,
          "\t",
          repo.slug || "",
          "\t",
          Map.get(repo, :alias_source) || "auto",
          "\n"
        ]
        |> IO.iodata_to_binary()
      end)

    with :ok <- File.write(tmp, @header <> body),
         :ok <- File.rename(tmp, path) do
      :ok
    else
      {:error, reason} ->
        _ = File.rm(tmp)
        {:error, reason}
    end
  end

  @spec read(Config.t()) :: {:ok, [map()]} | {:error, term()}
  def read(%Config{} = config) do
    case File.read(path(config)) do
      {:ok, body} ->
        entries =
          body
          |> String.split("\n", trim: true)
          |> Enum.reject(&String.starts_with?(&1, "#"))
          |> Enum.flat_map(fn line ->
            case String.split(line, "\t") do
              [hash, remote_key | rest] ->
                [alias_name, source] =
                  case rest do
                    [alias_name, source] -> [alias_name, source]
                    [alias_name] -> [alias_name, "auto"]
                    [] -> [nil, "auto"]
                  end

                [
                  %{
                    hash: hash,
                    remote_key: remote_key,
                    alias: empty_to_nil(alias_name),
                    alias_source: source
                  }
                ]

              _ ->
                []
            end
          end)

        {:ok, entries}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp mirror_hash(%{bare_path: bare}) when is_binary(bare) do
    bare |> Path.basename() |> String.replace_suffix(".git", "")
  end

  defp mirror_hash(%{remote_key: key}), do: String.slice(Layout.remote_hash(key), 0, 64)

  defp empty_to_nil(""), do: nil
  defp empty_to_nil(value), do: value
end
