defmodule Gitspace.CLI.Output do
  @moduledoc "Text tables, JSON envelopes and terminal detection."

  alias Gitspace.Error

  @schema_version 1

  @spec emit(
          {:ok, term(), fun()}
          | {:error, Error.t()}
          | {:partial, term(), fun(), Error.t()}
          | {:exit, non_neg_integer()},
          map()
        ) :: non_neg_integer()
  def emit({:exit, code}, _global), do: code

  def emit({:ok, data, _renderer}, %{json: true}) do
    IO.puts(
      Jason.encode!(%{
        schema_version: @schema_version,
        ok: true,
        data: json_safe(data)
      })
    )

    0
  end

  def emit({:ok, data, renderer}, _global) do
    renderer.(data)
    0
  end

  def emit({:error, %Error{} = error}, %{json: true}) do
    IO.puts(
      Jason.encode!(%{
        schema_version: @schema_version,
        ok: false,
        error: %{
          code: Atom.to_string(error.code),
          message: error.message,
          hint: error.hint,
          details: json_safe(error.details)
        }
      })
    )

    error.exit_code
  end

  def emit({:error, %Error{} = error}, _global) do
    IO.puts(:stderr, "error: #{error.message}")
    if error.hint, do: IO.puts(:stderr, "hint: #{error.hint}")
    error.exit_code
  end

  def emit({:partial, _data, _renderer, %Error{} = error}, %{json: true}) do
    emit({:error, error}, %{json: true})
  end

  def emit({:partial, data, renderer, %Error{} = error}, _global) do
    renderer.(data)
    IO.puts(:stderr, "error: #{error.message}")
    if error.hint, do: IO.puts(:stderr, "hint: #{error.hint}")
    error.exit_code
  end

  @spec tty?() :: boolean()
  def tty? do
    if System.get_env("GITSPACE_NO_PROMPT") in ["1", "true", "yes"] do
      false
    else
      terminal?()
    end
  end

  defp terminal? do
    case File.read_link("/proc/self/fd/0") do
      {:ok, target} -> tty_path?(target)
      {:error, _} -> match?({:ok, _}, :io.columns())
    end
  end

  defp tty_path?(target) do
    String.starts_with?(target, ["/dev/pts/", "/dev/tty"]) or target == "/dev/console"
  end

  @spec confirm?(String.t()) :: boolean()
  def confirm?(question) do
    case IO.gets(question <> " [y/N]: ") do
      :eof -> false
      {:error, _} -> false
      input -> String.downcase(String.trim(input)) in ["y", "yes"]
    end
  end

  @spec table([String.t()], [[term()]]) :: :ok
  def table(headers, rows) do
    formatted = Enum.map(rows, fn row -> Enum.map(row, &format_value/1) end)

    widths =
      [headers | formatted]
      |> Enum.zip_with(fn column -> column |> Enum.map(&display_width/1) |> Enum.max() end)

    header_line =
      headers
      |> Enum.zip(widths)
      |> Enum.map_join("  ", fn {value, width} -> pad(value, width) end)

    divider = Enum.map_join(widths, "  ", &String.duplicate("-", &1))

    IO.puts(header_line)
    IO.puts(divider)

    if formatted == [] do
      IO.puts("(none)")
    else
      Enum.each(formatted, fn row ->
        IO.puts(
          row
          |> Enum.zip(widths)
          |> Enum.map_join("  ", fn {value, width} -> pad(value, width) end)
        )
      end)
    end

    :ok
  end

  @spec format_value(term()) :: String.t()
  def format_value(nil), do: "-"
  def format_value(true), do: "yes"
  def format_value(false), do: "no"
  def format_value(value) when is_binary(value), do: value
  def format_value(value) when is_integer(value), do: Integer.to_string(value)
  def format_value(value) when is_atom(value), do: Atom.to_string(value)
  def format_value(%DateTime{} = value), do: DateTime.to_iso8601(value)
  def format_value(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  def format_value(value) when is_list(value), do: Enum.map_join(value, ", ", &format_value/1)

  def format_value(value) when is_map(value) do
    value
    |> Enum.sort_by(fn {key, _} -> to_string(key) end)
    |> Enum.map_join(" ", fn {key, val} -> "#{key}=#{format_value(val)}" end)
  end

  def format_value(value), do: inspect(value)

  @spec json_safe(term()) :: term()
  def json_safe(%DateTime{} = value), do: DateTime.to_iso8601(value)
  def json_safe(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  def json_safe(%Ecto.Association.NotLoaded{}), do: nil

  def json_safe(%_{} = struct) do
    struct
    |> Map.from_struct()
    |> json_safe()
  end

  def json_safe(%{} = map) do
    Map.new(map, fn {key, value} -> {key, json_safe(value)} end)
  end

  def json_safe(list) when is_list(list), do: Enum.map(list, &json_safe/1)
  def json_safe(tuple) when is_tuple(tuple), do: tuple |> Tuple.to_list() |> json_safe()
  def json_safe(value) when is_pid(value) or is_reference(value) or is_function(value), do: nil
  def json_safe(value), do: value

  defp display_width(value), do: String.length(value)

  defp pad(value, width) do
    value <> String.duplicate(" ", max(width - String.length(value), 0))
  end
end
