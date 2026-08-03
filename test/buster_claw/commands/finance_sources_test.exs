defmodule BusterClaw.Commands.FinanceSourcesTest do
  @moduledoc """
  The `finance_sources` command — the surface that makes the registry answerable
  from any conversation (`CHART_BUILD_WEB_DATA_ROADMAP` Phase 3).

  These assert on the *command*, not on `Sources`, because the registry being
  correct and the agent being able to ask about it are two different claims and
  only one of them was true before this command existed.
  """
  use ExUnit.Case, async: false

  alias BusterClaw.Commands

  setup do
    prev = Application.get_env(:buster_claw, :workspace_root)
    root = Path.join(System.tmp_dir!(), "bc-fsrc-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    Application.put_env(:buster_claw, :workspace_root, root)

    on_exit(fn ->
      Application.put_env(:buster_claw, :workspace_root, prev)
      File.rm_rf(root)
    end)

    {:ok, root: root}
  end

  test "lists every source with its status and the date anyone last checked" do
    assert {:ok, %{count: count, sources: sources}} = Commands.finance_sources()
    assert count == length(sources)
    assert count > 1

    bls = Enum.find(sources, &(&1.key == "bls"))
    assert bls.status == "verified"
    # A :verified claim with no date is a claim nobody can check.
    assert bls.verified_on == "2026-08-03"
    assert bls.fetchable

    # And the decisions are listed too, not just the working ones — the point of
    # recording a :blocked or :unsanctioned source is that the next person finds
    # the decision instead of rediscovering the endpoint.
    assert Enum.find(sources, &(&1.key == "fred")).status == "blocked"
    assert Enum.find(sources, &(&1.key == "yahoo_unofficial")).status == "unsanctioned"
  end

  test "listing is not permission — `fetchable` is far shorter than the catalogue" do
    assert {:ok, %{fetchable: fetchable, sources: sources}} = Commands.finance_sources()

    assert "bls" in fetchable
    assert length(fetchable) < length(sources)

    # Every source agrees with the top-level list about its own fetchability.
    for source <- sources do
      assert source.fetchable == source.key in fetchable
    end

    # A :candidate has never been called, so its response shape is a guess.
    refute Enum.find(sources, &(&1.key == "bea")).fetchable
  end

  test "filters to one status, so an operator can ask what is merely a candidate" do
    assert {:ok, %{sources: candidates}} = Commands.finance_sources(%{"status" => "candidate"})

    assert candidates != []
    assert Enum.all?(candidates, &(&1.status == "candidate"))
    refute Enum.any?(candidates, &(&1.key == "bls"))
  end

  test "an unrecognised status filters to nothing rather than silently listing all" do
    assert {:ok, %{count: 0, sources: []}} = Commands.finance_sources(%{"status" => "excellent"})
  end

  # `sources/` is on-demand with no seeder, so without this the override folder
  # would never exist and the feature would be reachable only by an operator who
  # guessed the directory name.
  test "asking about sources creates the folder you would add one to", %{root: root} do
    refute File.exists?(Path.join(root, "sources"))

    assert {:ok, %{overrides_dir: dir}} = Commands.finance_sources()

    assert dir == Path.join(root, "sources")
    assert File.dir?(dir)
  end

  test "an override written to that folder shows up on the very next call" do
    assert {:ok, %{overrides_dir: dir}} = Commands.finance_sources()

    File.write!(Path.join(dir, "coingecko.md"), """
    ---
    status: dead
    ---
    Shut the free tier on us.
    """)

    assert {:ok, %{sources: sources}} = Commands.finance_sources()
    coingecko = Enum.find(sources, &(&1.key == "coingecko"))

    assert coingecko.status == "dead"
    assert coingecko.note == "Shut the free tier on us."
    # The shipped fields it did not mention survive — an override corrects an
    # entry, it does not replace it.
    assert coingecko.base_url == "https://api.coingecko.com/api/v3"
  end
end
