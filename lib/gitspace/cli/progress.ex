defmodule Gitspace.CLI.Progress do
  @moduledoc """
  Inline progress lines for long operations.

  Text mode prints one line per item, prefixed with a counter. JSON mode is
  silent so the output remains a single document. Domain functions receive a
  plain callback and never depend on this module.
  """

  @type event ::
          {:start, pos_integer(), non_neg_integer(), String.t()}
          | {:ok, pos_integer(), non_neg_integer(), String.t()}
          | {:error, pos_integer(), non_neg_integer(), String.t(), String.t()}

  @spec callback(map(), String.t()) :: (event() -> :ok) | nil
  def callback(%{json: true}, _label), do: nil

  def callback(_global, label) do
    fn
      {:start, index, total, name} ->
        IO.write("#{label} #{index}/#{total} #{name} ... ")

      {:ok, _index, _total, _name} ->
        IO.puts("ok")

      {:error, _index, _total, _name, reason} ->
        IO.puts("failed: #{reason}")
    end
  end

  @spec notify((event() -> :ok) | nil, event()) :: :ok
  def notify(nil, _event), do: :ok
  def notify(callback, event) when is_function(callback, 1), do: callback.(event)
end
