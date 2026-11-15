defmodule Gitspace.CLI.Prompt do
  @moduledoc false

  alias Gitspace.Layout

  @doc "Interactive choice when a branch is already checked out somewhere else."
  @spec occupied(map()) :: :borrow | :detach | :cancel | {:branch, String.t()}
  def occupied(context) do
    IO.puts(:stderr, "")
    IO.puts(:stderr, "branch '#{context.branch}' is already checked out at #{context.path}")
    IO.puts(:stderr, "  1) borrow that checkout")
    IO.puts(:stderr, "  2) create a new branch")
    IO.puts(:stderr, "  3) detach at the same commit")
    IO.puts(:stderr, "  4) cancel")

    case IO.gets("choose [1-4]: ") do
      :eof ->
        :cancel

      {:error, _} ->
        :cancel

      input ->
        case String.trim(input) do
          "1" -> :borrow
          "2" -> prompt_branch(context)
          "3" -> :detach
          _ -> :cancel
        end
    end
  end

  defp prompt_branch(context) do
    default = "#{context.branch}-2"

    case IO.gets("new branch name [#{default}]: ") do
      :eof ->
        :cancel

      {:error, _} ->
        :cancel

      input ->
        branch =
          case String.trim(input) do
            "" -> default
            value -> value
          end

        if Layout.valid_branch?(branch) do
          {:branch, branch}
        else
          IO.puts(:stderr, "invalid branch name: #{branch}")
          prompt_branch(context)
        end
    end
  end
end
