defmodule GitspaceTest do
  use ExUnit.Case
  doctest Gitspace

  test "greets the world" do
    assert Gitspace.hello() == :world
  end
end
