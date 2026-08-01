defmodule BusterClawWeb.SettingsTabsTest do
  use ExUnit.Case, async: true

  alias BusterClawWeb.SettingsTabs

  # The Settings sub-tabs are declared here in Elixir, but the browser-style tab
  # strip needs the same set in JS (`TAB_GROUPS` in assets/js/lib/tabs.js) to
  # collapse them into one "Settings" tab. Two hand-maintained lists that must
  # agree is exactly how /notify-settings ended up opening its own top-level tab
  # labelled "/notify-settings": it was added to the nav below and never to the
  # JS group. This test is the lockstep, in the same spirit as the Rust
  # acl_lockstep suite.
  @tabs_js Path.expand("../../../assets/js/lib/tabs.js", __DIR__)

  defp js_group_paths do
    js = File.read!(@tabs_js)

    [_, set] = Regex.run(~r/paths: new Set\(\[(.*?)\]\)/s, js)

    ~r/"([^"]+)"/
    |> Regex.scan(set)
    |> Enum.map(&Enum.at(&1, 1))
  end

  test "the JS tab-strip group lists exactly the Settings sub-tab paths" do
    elixir_paths = MapSet.new(SettingsTabs.paths())
    js_paths = MapSet.new(js_group_paths())

    missing_in_js = MapSet.difference(elixir_paths, js_paths)
    extra_in_js = MapSet.difference(js_paths, elixir_paths)

    assert MapSet.size(missing_in_js) == 0, """
    Settings sub-tabs missing from TAB_GROUPS in assets/js/lib/tabs.js:

        #{Enum.join(missing_in_js, ", ")}

    Each of these will open its OWN top-level tab (labelled with its raw path)
    instead of staying inside the Settings tab. Add them to the group's Set.
    """

    assert MapSet.size(extra_in_js) == 0, """
    TAB_GROUPS in assets/js/lib/tabs.js lists paths that are no longer Settings
    sub-tabs:

        #{Enum.join(extra_in_js, ", ")}

    Remove them, or they will silently swallow a route that should get its own tab.
    """
  end

  test "the group's canonical key is itself a settings sub-tab" do
    # `/settings` is both the group key and the Configuration sub-tab. If it ever
    # stopped being a real route, returning to the Settings tab would 404.
    assert "/settings" in SettingsTabs.paths()
  end

  test "notify-settings is grouped — the regression this test was written for" do
    assert "/notify-settings" in SettingsTabs.paths()
    assert "/notify-settings" in js_group_paths()
  end
end
