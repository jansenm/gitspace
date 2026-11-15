defmodule Gitspace.Error do
  @moduledoc """
  A stable, user-facing error with a machine-readable code and an exit code.

  The exit-code mapping is part of the CLI contract and must not change
  casually. Unknown errors use 1.
  """

  defexception [:code, :message, :hint, :details, :exit_code]

  @exit_codes %{
    usage: 2,
    not_found: 3,
    ambiguous: 3,
    conflict: 4,
    branch_occupied: 4,
    refused: 5,
    confirmation_required: 6,
    partial: 7,
    not_configured: 7,
    invalid_config: 7
  }

  @type t :: %__MODULE__{
          code: atom(),
          message: String.t(),
          hint: String.t() | nil,
          details: map(),
          exit_code: pos_integer()
        }

  @spec new(atom(), String.t(), keyword()) :: t()
  def new(code, message, opts \\ []) when is_atom(code) and is_binary(message) do
    %__MODULE__{
      code: code,
      message: message,
      hint: opts[:hint],
      details: Map.new(opts[:details] || %{}),
      exit_code: Map.get(@exit_codes, code, 1)
    }
  end

  @spec exit_code(t() | term()) :: pos_integer()
  def exit_code(%__MODULE__{exit_code: exit_code}), do: exit_code
  def exit_code(_), do: 1

  @impl true
  def exception(opts) do
    new(Keyword.fetch!(opts, :code), Keyword.fetch!(opts, :message), opts)
  end

  @impl true
  def message(%__MODULE__{message: message}), do: message
end
