defmodule Gitspace.Marker do
  @moduledoc """
  The workspace recovery marker.

  `<project.path>/<topic>/.gitspace.json` makes a workspace self-describing so
  the index can be rebuilt after deletion or corruption. It is tool-owned,
  never a user-facing manifest, and must never contain secrets.
  """

  @marker_file ".gitspace.json"
  @schema_version 1

  alias Gitspace.Layout

  @spec write!(Path.t(), map()) :: Path.t()
  def write!(work_dir, marker) when is_map(marker) do
    File.mkdir_p!(work_dir)

    marker =
      marker
      |> stringify_keys()
      |> Map.put_new("schema_version", @schema_version)

    path = Path.join(work_dir, @marker_file)
    File.write!(path, Jason.encode!(marker, pretty: true) <> "\n")
    path
  end

  @spec read(Path.t()) :: {:ok, map()} | {:error, term()}
  def read(work_dir) do
    path = Path.join(work_dir, @marker_file)

    with {:ok, contents} <- File.read(path),
         {:ok, marker} <- Jason.decode(contents),
         :ok <- validate(marker) do
      {:ok, marker}
    end
  end

  @spec read!(Path.t()) :: map()
  def read!(work_dir) do
    case read(work_dir) do
      {:ok, marker} -> marker
      {:error, reason} -> raise "invalid marker in #{work_dir}: #{inspect(reason)}"
    end
  end

  @doc "Finds every marker under a checkout root. Bad markers are reported, not hidden."
  @spec find_all(Path.t()) :: {:ok, [{Path.t(), map()}], [{Path.t(), term()}]}
  def find_all(root) do
    results =
      root
      |> Path.join("*")
      |> Path.join(@marker_file)
      |> Path.wildcard(match_dot: true)
      |> Enum.map(fn path ->
        case read(Path.dirname(path)) do
          {:ok, marker} -> {:ok, {Path.dirname(path), marker}}
          {:error, reason} -> {:error, {path, reason}}
        end
      end)

    {ok, bad} = Enum.split_with(results, &match?({:ok, _}, &1))

    {:ok, Enum.map(ok, fn {:ok, entry} -> entry end),
     Enum.map(bad, fn {:error, entry} -> entry end)}
  end

  @spec validate(term()) :: :ok | {:error, term()}
  def validate(%{
        "schema_version" => @schema_version,
        "workspace" => workspace,
        "members" => members
      })
      when is_binary(workspace) and is_list(members) do
    cond do
      workspace == "" -> {:error, :empty_workspace}
      not valid_members?(members) -> {:error, :invalid_members}
      true -> :ok
    end
  end

  def validate(%{"schema_version" => version}) when version != @schema_version,
    do: {:error, {:unsupported_schema, version}}

  def validate(_), do: {:error, :missing_fields}

  defp valid_members?(members) do
    Enum.all?(members, fn
      %{"repo" => repo, "ownership" => "owned", "rel_path" => rel} when is_binary(repo) ->
        is_binary(rel) and safe_relative?(rel)

      %{"repo" => repo, "ownership" => "borrowed", "path" => path} when is_binary(repo) ->
        is_binary(path) and Path.type(path) == :absolute

      _ ->
        false
    end)
  end

  defp safe_relative?(rel) do
    rel != "" and
      Path.type(rel) != :absolute and
      not String.contains?(rel, ["..", "\0"])
  end

  defp stringify_keys(map) do
    Map.new(map, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), value}
      {key, value} -> {key, value}
    end)
  end

  @doc "Default marker payload for a workspace."
  @spec build(String.t(), keyword() | map()) :: map()
  def build(workspace, attrs \\ %{}) do
    attrs = Map.new(attrs)

    %{
      "schema_version" => @schema_version,
      "workspace" => workspace,
      "project" => Map.get(attrs, :project),
      "topic" => Map.get(attrs, :topic),
      "description" => Map.get(attrs, :description),
      "labels" => Map.get(attrs, :labels, []),
      "created_at" => Map.get(attrs, :created_at, DateTime.utc_now() |> DateTime.to_iso8601()),
      "members" => Map.get(attrs, :members, [])
    }
  end

  @doc false
  def marker_filename, do: @marker_file

  @doc false
  def marker_path(root, work) do
    {:ok, path} = Layout.marker_path(root, work)
    path
  end
end
