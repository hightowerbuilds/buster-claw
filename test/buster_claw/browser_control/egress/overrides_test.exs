defmodule BusterClaw.BrowserControl.Egress.OverridesTest do
  @moduledoc """
  The stored half of per-host egress levels: shipped defaults that upgrade with
  the app, the operator's entries layered over them, and the command surface
  that was missing entirely — `Policy.level_for/2` has always taken
  `:overrides`, and nothing could feed it.
  """
  # async: false — `Settings` is global state.
  use BusterClaw.DataCase, async: false

  alias BusterClaw.BrowserControl.Egress.Policy
  alias BusterClaw.Commands

  test "amazon ships as structure_only by default, and covers its subdomains" do
    assert {"amazon.com", :structure_only} in Policy.overrides()

    # The 07-25 field test's actual finding: complete Amazon pages, order
    # history included, went to the model at :full.
    assert Policy.level_for("www.amazon.com", overrides: Policy.overrides()) == :structure_only
    assert Policy.level_for("smile.amazon.com", overrides: Policy.overrides()) == :structure_only
  end

  test "defaults live in code, so the operator's file cannot freeze them" do
    # Nothing is stored yet, and the default is still in force. This is the
    # LAUNCH_ROADMAP V.8 problem avoided by construction: a seeded file would
    # have pinned this list forever on any install that already had one.
    assert Policy.stored_overrides() == []
    refute Enum.empty?(Policy.overrides())
  end

  test "an operator entry layers over the shipped default for the same host" do
    assert {:ok, _} = Policy.put_override("amazon.com", :never)

    assert Policy.overrides() == [{"amazon.com", :never}]
    assert Policy.level_for("www.amazon.com", overrides: Policy.overrides()) == :never

    # Clearing it returns the host to the shipped default rather than to :full.
    assert {:ok, []} = Policy.put_override("amazon.com", nil)
    assert {"amazon.com", :structure_only} in Policy.overrides()
  end

  test "a typo is refused rather than recorded as no rule" do
    assert {:error, {:bad_level, "structureonly"}} =
             Policy.put_override("shop.example.com", "structureonly")

    assert Policy.stored_overrides() == []
  end

  test "the command reads and writes, and reports what is actually in force" do
    assert {:ok, listing} = Commands.browser_egress_level()
    assert %{host: "amazon.com", level: "structure_only"} in listing.in_force
    assert listing.operator_set == []
    assert listing.levels == ["full", "structure_only", "never"]

    assert {:ok, _} =
             Commands.browser_egress_level(%{"host" => "shop.example.com", "level" => "never"})

    assert {:ok, listing} = Commands.browser_egress_level()
    assert %{host: "shop.example.com", level: "never"} in listing.operator_set
    assert %{host: "amazon.com", level: "structure_only"} in listing.in_force

    assert {:error, {:bad_level, "loud"}} =
             Commands.browser_egress_level(%{"host" => "shop.example.com", "level" => "loud"})
  end

  test "the command is in the catalog at a restricted tier" do
    assert Commands.command_tier("browser_egress_level") == :restricted
  end
end
