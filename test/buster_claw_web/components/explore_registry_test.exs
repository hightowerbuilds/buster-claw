defmodule BusterClawWeb.Explore.RegistryTest do
  @moduledoc """
  The contract `Explore.Registry` has always claimed and never had.

  `@command_stats` is kept as a literal on purpose — reading the catalog from a
  presentation component would make the web layer depend on the command
  dispatch layer — and the comment above it says the Explore contract test
  "derives the same values from `Commands.list_commands/0` and fails on drift."

  No such test existed. Written 08-08-26 during the Explore split, after the
  numbers were checked by hand and found correct; four commands landed the same
  afternoon and moved three of them, which is the whole argument for the file.
  """
  use ExUnit.Case, async: true

  alias BusterClaw.Commands
  alias BusterClawWeb.Explore.Registry

  test "the Command List tutorial's counts match the real command surface" do
    catalog = Commands.list_commands()

    actual = %{
      total: length(catalog),
      read: Enum.count(catalog, &(&1.type == :read)),
      trigger: Enum.count(catalog, &(&1.type == :trigger)),
      mutate: Enum.count(catalog, &(&1.type == :mutate)),
      safe: Enum.count(catalog, &(&1.tier == :safe)),
      restricted: Enum.count(catalog, &(&1.tier == :restricted)),
      gated: Enum.count(catalog, &Map.get(&1, :gated))
    }

    assert actual == Registry.command_stats(), """
    The Explore Command List tutorial quotes counts that no longer match the catalog.

    You almost certainly just added, removed or re-tiered a command. The tutorial
    states these figures in prose and in its funnel diagram, so update
    @command_stats in lib/buster_claw_web/components/explore/registry.ex:

      #{inspect(actual, pretty: true)}

    It currently says:

      #{inspect(Registry.command_stats(), pretty: true)}
    """
  end

  test "every type and tier in the catalog is one the tutorial accounts for" do
    catalog = Commands.list_commands()

    # The tutorial's prose splits the surface exactly three ways by type and
    # exactly two ways by tier. A new type or tier would make its arithmetic
    # silently wrong rather than merely stale, so it fails here instead.
    assert Enum.all?(catalog, &(&1.type in [:read, :trigger, :mutate])),
           "a command has a type the Explore tutorial does not describe"

    assert Enum.all?(catalog, &(&1.tier in [:safe, :restricted])),
           "a command has a trust tier the Explore tutorial does not describe"
  end

  test "the sub-tab registries agree with each other" do
    keys = Enum.map(Registry.tabs(), &elem(&1, 0))

    # The rail, the Intro grid and the parent's whitelist all read from here.
    # A tile without a rail entry is a button that opens nothing; a rail entry
    # without a tile is a tab the launcher cannot reach.
    assert Enum.sort(keys) == Enum.sort(["intro" | Enum.map(Registry.tiles(), & &1.key)])

    assert keys == Enum.uniq(keys), "a sub-tab key is registered twice"

    for stub <- Registry.stubs() do
      assert stub.key in keys, "stub #{stub.key} has no rail entry"
      assert String.starts_with?(stub.path, "/"), "stub #{stub.key} needs an in-app path"
    end
  end
end
