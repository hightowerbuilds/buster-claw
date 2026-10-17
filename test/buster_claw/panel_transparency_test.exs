defmodule BusterClaw.PanelTransparencyTest do
  # async: false — writes a shared Settings row and broadcasts on a global topic.
  use BusterClaw.DataCase, async: false

  alias BusterClaw.PanelTransparency
  alias BusterClaw.Settings

  test "defaults to the shipped look: 32% transparent, panes 68% filled, sidebar 80%" do
    assert PanelTransparency.get() == 32
    assert PanelTransparency.fills(32) == %{panel: 68, menu: 80}
    assert PanelTransparency.style(32) == "--panel-fill: 68%; --panel-fill-menu: 80%;"
  end

  # The fallbacks in the stylesheets are the shipped numbers, so a page that does
  # not write the properties renders exactly as before. If either side moves,
  # this says so.
  test "the CSS fallbacks are the default's fills" do
    %{panel: panel, menu: menu} = PanelTransparency.fills(PanelTransparency.default())
    workbench = File.read!("assets/css/workbench.css")

    assert workbench =~ "var(--panel-fill, #{panel}%)"
    assert workbench =~ "var(--panel-fill-menu, #{menu}%)"
  end

  test "sets, persists, broadcasts, and accepts a slider's string" do
    PanelTransparency.subscribe()

    assert {:ok, 55} = PanelTransparency.set("55")
    assert_receive {:panel_transparency, 55}
    assert PanelTransparency.get() == 55
    assert Settings.get("panel_transparency") == "55"

    assert {:ok, 100} = PanelTransparency.set(100)
    assert PanelTransparency.fills(100) == %{panel: 0, menu: 12}
    assert {:ok, 0} = PanelTransparency.set(0)
    assert PanelTransparency.fills(0) == %{panel: 100, menu: 100}
  end

  test "the default clears the stored row rather than writing it" do
    {:ok, _} = PanelTransparency.set(70)
    assert {:ok, 32} = PanelTransparency.set(32)
    assert Settings.get("panel_transparency") == nil
  end

  test "refuses what is out of range or not a number, and changes nothing" do
    {:ok, _} = PanelTransparency.set(40)

    assert {:error, :out_of_range} = PanelTransparency.set(101)
    assert {:error, :out_of_range} = PanelTransparency.set(-1)
    assert {:error, :not_a_number} = PanelTransparency.set("lots")
    assert {:error, :not_a_number} = PanelTransparency.set(nil)

    assert PanelTransparency.get() == 40
  end

  test "an unreadable stored value reads as the default" do
    Settings.put("panel_transparency", "999")
    assert PanelTransparency.get() == 32
  end
end
