defmodule Gitspace.RebaseJournal do
  @moduledoc """
  Remembers the last rebase batch so completed rebases can be rolled back.

  The journal lives at `<data>/rebase.json`. Each entry records the branch, the
  head before the rebase, and the head after it. `--abort` uses it to restore
  worktrees whose rebase already finished, but only while they are still at the
  recorded post-rebase head and their working tree is clean.
  """

  alias Gitspace.Config

  @spec path(Config.t()) :: Path.t()
  def path(%Config{} = config), do: Path.join(config.data_dir, "rebase.json")

  @spec load(Config.t()) :: map() | nil
  def load(%Config{} = config) do
    case File.read(path(config)) do
      {:ok, body} ->
        case Jason.decode(body) do
          {:ok, %{} = data} -> data
          _ -> nil
        end

      {:error, _} ->
        nil
    end
  end

  @spec save(Config.t(), map()) :: :ok
  def save(%Config{} = config, data) when is_map(data) do
    path = path(config)
    tmp = path <> ".tmp"
    File.mkdir_p!(Path.dirname(path))

    with :ok <- File.write(tmp, Jason.encode!(data)),
         :ok <- File.rename(tmp, path) do
      :ok
    else
      _ ->
        _ = File.rm(tmp)
        :ok
    end
  rescue
    _ -> :ok
  end

  @spec entry(map() | nil, String.t()) :: map() | nil
  def entry(nil, _path), do: nil

  def entry(journal, path) do
    journal
    |> Map.get("entries", [])
    |> Enum.find(&(&1["path"] == path))
  end

  @spec record(Config.t(), String.t(), map()) :: :ok
  def record(%Config{} = config, path, attrs) do
    journal = load(config) || %{"entries" => []}
    entries = Map.get(journal, "entries", [])
    existing = Enum.find(entries, &(&1["path"] == path))
    merged = Map.merge(existing || %{"path" => path}, attrs)

    entries =
      if existing do
        Enum.map(entries, fn entry -> if entry["path"] == path, do: merged, else: entry end)
      else
        entries ++ [merged]
      end

    save(config, Map.put(journal, "entries", entries))
  end
end
