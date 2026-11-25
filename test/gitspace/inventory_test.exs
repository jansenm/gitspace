defmodule Gitspace.InventoryTest do
  use Gitspace.IndexCase, async: false

  alias Gitspace.{Checkouts, Fixtures, Inventory, Repos}

  defp orphan_checkout!(config, repo, state) do
    path = Path.join([config.projects_root, "loose", repo.slug])
    File.mkdir_p!(path)

    {:ok, checkout} =
      Checkouts.ensure_missing(repo, path, %{
        state: state,
        last_status_at: DateTime.utc_now()
      })

    checkout
  end

  test "inbox lists a clean orphan checkout under working", %{config: config} do
    source = Fixtures.source_repo!()
    {:ok, repo} = Repos.add(config, Fixtures.repo_url(source), name: "demo")
    checkout = orphan_checkout!(config, repo, "ok")

    inbox = Inventory.inbox(config)

    assert inbox.counts.checkouts == 1
    assert inbox.needs == []
    assert Enum.any?(inbox.working, &(&1.kind == :checkout and &1.id == checkout.id))
  end

  test "inbox puts a risky orphan checkout under needs", %{config: config} do
    source = Fixtures.source_repo!()
    {:ok, repo} = Repos.add(config, Fixtures.repo_url(source), name: "demo")
    checkout = orphan_checkout!(config, repo, "missing")

    inbox = Inventory.inbox(config)

    assert [%{kind: :checkout, id: id, risk: %{at_risk: true}}] = inbox.needs
    assert id == checkout.id
    assert inbox.working == []
  end
end
