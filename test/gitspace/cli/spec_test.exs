defmodule Gitspace.CLI.SpecTest do
  use ExUnit.Case, async: true

  alias Gitspace.CLI.Spec

  test "top help contains every visible command" do
    help = Spec.top_help()

    for command <- Spec.commands(), not command.hidden do
      assert help =~ command.name
    end
  end

  test "completion includes aliases and help but not hidden subcommands" do
    names = Spec.completion_commands()

    assert "checkout" in names
    assert "co" in names
    assert "help" in names
    refute "workspace status" in names

    workspace = Spec.command("workspace")
    visible = Spec.visible_subcommands(workspace) |> Enum.map(& &1.name)

    assert "new" in visible
    assert "add" in visible
    refute "status" in visible
    assert %{name: "status"} = Spec.subcommand("workspace", "status")
  end

  test "flags and value flags come from the spec" do
    assert "--force" in Spec.flag_names("push")
    assert "--force-with-lease" in Spec.flag_names("push")
    refute "--label" in Spec.flag_names("workspace", "add")
    assert "--diff-lines" in Spec.value_flags()
    assert "--output" in Spec.value_flags()
    assert "--older-than" in Spec.value_flags()
  end

  test "the manpage mentions every visible command and subcommand" do
    man = File.read!("man/gitspace.1")

    for command <- Spec.commands(), not command.hidden, command.group != :meta do
      assert man =~ "gitspace #{command.name}"

      for sub <- Spec.visible_subcommands(command), sub.name != "help" do
        assert man =~ "gitspace #{command.name} #{sub.name}"
      end
    end
  end
end
