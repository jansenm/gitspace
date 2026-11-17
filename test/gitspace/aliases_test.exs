defmodule Gitspace.AliasesTest do
  use ExUnit.Case, async: true

  alias Gitspace.Aliases

  test "a unique basename stays short" do
    repos = [repo("github.com/acme/config")]
    assert {:ok, aliases} = Aliases.resolve(repos)
    assert aliases == %{"github.com/acme/config" => "config"}
  end

  test "colliding basenames qualify every auto member with its group" do
    repos = [
      repo("github.com/acme/config"),
      repo("github.com/beta/config"),
      repo("gitlab.com/team/config")
    ]

    assert {:ok, aliases} = Aliases.resolve(repos)
    assert aliases["github.com/acme/config"] == "acme-config"
    assert aliases["github.com/beta/config"] == "beta-config"
    assert aliases["gitlab.com/team/config"] == "team-config"
  end

  test "same group across hosts qualifies both with the host" do
    repos = [
      repo("github.com/acme/config"),
      repo("gitlab.com/acme/config")
    ]

    assert {:ok, aliases} = Aliases.resolve(repos)
    assert aliases["github.com/acme/config"] == "github.com-acme-config"
    assert aliases["gitlab.com/acme/config"] == "gitlab.com-acme-config"
  end

  test "an explicit alias can claim the bare basename" do
    repos = [
      repo("github.com/acme/config"),
      repo("github.com/beta/config", "config", "explicit")
    ]

    assert {:ok, aliases} = Aliases.resolve(repos)
    assert aliases["github.com/beta/config"] == "config"
    assert aliases["github.com/acme/config"] == "acme-config"
  end

  test "explicit aliases must be unique" do
    repos = [
      repo("github.com/acme/config", "same", "explicit"),
      repo("github.com/beta/config", "same", "explicit")
    ]

    assert {:error, error} = Aliases.resolve(repos)
    assert error.code == :conflict
  end

  test "an explicit alias blocks an auto candidate and the auto falls back" do
    repos = [
      repo("github.com/acme/config"),
      repo("github.com/beta/config", "acme-config", "explicit")
    ]

    assert {:ok, aliases} = Aliases.resolve(repos)
    assert aliases["github.com/beta/config"] == "acme-config"
    assert aliases["github.com/acme/config"] == "github.com-acme-config"
  end

  test "local paths use their parent directory as group" do
    repos = [
      repo("/home/me/one/config"),
      repo("/home/me/two/config")
    ]

    assert {:ok, aliases} = Aliases.resolve(repos)
    assert aliases["/home/me/one/config"] == "one-config"
    assert aliases["/home/me/two/config"] == "two-config"
  end

  test "resolution is deterministic regardless of input order" do
    repos = [
      repo("github.com/beta/config"),
      repo("github.com/acme/config"),
      repo("gitlab.com/acme/config")
    ]

    assert {:ok, first} = Aliases.resolve(repos)
    assert {:ok, second} = Aliases.resolve(Enum.reverse(repos))
    assert first == second
  end

  defp repo(remote_key, alias_name \\ nil, source \\ "auto") do
    %{
      id: remote_key,
      remote_key: remote_key,
      slug: alias_name || "pending",
      alias_source: source
    }
  end
end
