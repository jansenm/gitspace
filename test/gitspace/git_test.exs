defmodule Gitspace.GitTest do
  use ExUnit.Case, async: false

  alias Gitspace.{Fixtures, Git}

  test "runs git in a directory and captures stdout" do
    dir = Fixtures.source_repo!()
    assert Git.run!(["rev-parse", "--is-inside-work-tree"], cd: dir) |> String.trim() == "true"
  end

  test "keeps stdout and stderr separate" do
    dir = Fixtures.source_repo!()

    assert {:error, result} = Git.run(["rev-parse", "--verify", "does-not-exist"], cd: dir)
    assert result.exit != 0
    assert result.stdout == ""
    assert result.stderr =~ "Needed a single revision"
  end

  test "run! raises with the command and stderr" do
    dir = Fixtures.source_repo!()

    assert_raise Git.Error, ~r/rev-parse/, fn ->
      Git.run!(["rev-parse", "--verify", "does-not-exist"], cd: dir)
    end
  end

  test "scrubs GIT_DIR so an inherited value cannot redirect the command" do
    dir = Fixtures.source_repo!()
    System.put_env("GIT_DIR", "/nonexistent")

    try do
      assert Git.run!(["rev-parse", "--show-toplevel"], cd: dir)
             |> String.trim() == Path.expand(dir)
    after
      System.delete_env("GIT_DIR")
    end
  end

  test "passes extra environment to the child" do
    dir = Fixtures.source_repo!()
    out = Git.run!(["var", "GIT_AUTHOR_IDENT"], cd: dir, env: [{"GIT_AUTHOR_NAME", "Agent"}])
    assert out =~ "Agent"
  end
end
