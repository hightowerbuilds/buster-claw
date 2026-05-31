defmodule BusterClaw.SettingsTest do
  use BusterClaw.DataCase

  alias BusterClaw.Settings

  test "get returns default when unset" do
    assert Settings.get("missing") == nil
    assert Settings.get("missing", "fallback") == "fallback"
  end

  test "put then get round-trips a value and upserts on the same key" do
    assert {:ok, _} = Settings.put("theme", "dark")
    assert Settings.get("theme") == "dark"

    assert {:ok, _} = Settings.put("theme", "light")
    assert Settings.get("theme") == "light"
  end

  test "put stringifies non-binary values" do
    assert {:ok, _} = Settings.put("count", 42)
    assert Settings.get("count") == "42"
  end

  test "get_all returns a key => value map" do
    {:ok, _} = Settings.put("a", "1")
    {:ok, _} = Settings.put("b", "2")

    assert %{"a" => "1", "b" => "2"} = Settings.get_all()
  end

  test "delete removes a key and is safe when absent" do
    {:ok, _} = Settings.put("temp", "x")
    assert Settings.delete("temp") == :ok
    assert Settings.get("temp") == nil
    assert Settings.delete("never-existed") == :ok
  end

  test "onboarding flag lifecycle" do
    refute Settings.onboarding_completed?()

    assert {:ok, _} = Settings.mark_onboarding_complete()
    assert Settings.onboarding_completed?()

    assert Settings.reset_onboarding() == :ok
    refute Settings.onboarding_completed?()
  end
end
