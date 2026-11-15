defmodule Gitspace.CLI.PromptTest do
  use ExUnit.Case, async: true

  alias Gitspace.CLI.Prompt

  @context %{branch: "feature_x", path: "/data/work/other/repo", repo: "repo"}

  test "occupied choices map to creation decisions" do
    assert prompt("1\n") == :borrow
    assert prompt("3\n") == :detach
    assert prompt("4\n") == :cancel
  end

  test "a new branch uses the offered default or the typed name" do
    assert prompt("2\n\n") == {:branch, "feature_x-2"}
    assert prompt("2\nmy-branch\n") == {:branch, "my-branch"}
  end

  defp prompt(input) do
    parent = self()

    ExUnit.CaptureIO.capture_io(:stderr, fn ->
      {decision, _output} =
        ExUnit.CaptureIO.with_io([input: input, capture_prompt: true], fn ->
          Prompt.occupied(@context)
        end)

      send(parent, {:decision, decision})
    end)

    assert_receive {:decision, decision}
    decision
  end
end
