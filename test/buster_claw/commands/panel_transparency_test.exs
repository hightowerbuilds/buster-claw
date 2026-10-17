defmodule BusterClaw.Commands.PanelTransparencyTest do
  # async: false — writes a shared Settings row and broadcasts on a global topic.
  use BusterClaw.DataCase, async: false

  alias BusterClaw.Commands
  alias BusterClaw.Commands.Catalog
  alias BusterClaw.PanelTransparency

  test "panel_transparency_get reports the value in force, the default and the range" do
    assert {:ok, %{percent: 32, default: 32, min: 0, max: 100, panel_fill: 68}} =
             Commands.call("panel_transparency_get", %{})
  end

  test "panel_transparency_set changes it live, and the Work Area hears it" do
    PanelTransparency.subscribe()

    assert {:ok, %{percent: 60, panel_fill: 40, applied: true}} =
             Commands.call("panel_transparency_set", %{"percent" => 60})

    assert_receive {:panel_transparency, 60}
    assert PanelTransparency.get() == 60

    assert {:ok, %{percent: 32}} =
             Commands.call("panel_transparency_set", %{"percent" => "default"})
  end

  test "refusals are sentences that say what would work" do
    for {args, needle} <- [
          {%{"percent" => 150}, "outside 0–100"},
          {%{"percent" => "very"}, "not a whole number"},
          {%{}, "needs `percent`"}
        ] do
      assert {:error, message} = Commands.call("panel_transparency_set", args)
      assert is_binary(message)
      assert message =~ needle
    end

    assert PanelTransparency.get() == 32
  end

  test "the read is safe and the write is restricted, ungated" do
    entries = Enum.filter(Catalog.entries(), &String.starts_with?(&1.name, "panel_transparency_"))

    assert Enum.map(entries, & &1.name) |> Enum.sort() ==
             ["panel_transparency_get", "panel_transparency_set"]

    assert %{type: :read, tier: :safe} =
             Enum.find(entries, &(&1.name == "panel_transparency_get"))

    set = Enum.find(entries, &(&1.name == "panel_transparency_set"))
    assert %{type: :mutate, tier: :restricted} = set
    refute Map.get(set, :gated, false)

    assert {:ok, _} = Commands.call("panel_transparency_get", %{}, caller: :mcp)

    assert {:error, :requires_confirmation} =
             Commands.call("panel_transparency_set", %{"percent" => 80}, caller: :mcp)

    assert PanelTransparency.get() == 32
  end
end
