defmodule BusterClaw.BrowserControl.BackgroundFlowLiveTest do
  @moduledoc """
  A REAL background flow — launches the user's installed Chromium headlessly
  through the app's pool and runs the tab vocabulary end to end: the Page JS
  is exercised in an actual browser, not a stub.
  """
  use BusterClaw.DataCase, async: false

  alias BusterClaw.BrowserControl.BackgroundFlow

  @moduletag :browser_engine
  @moduletag timeout: 90_000

  test "a saved-check-shaped flow runs headlessly end to end" do
    steps = [
      %{"action" => "navigate", "url" => "https://example.com/"},
      %{"action" => "wait", "until" => "navigation", "timeout_ms" => 10_000},
      %{"action" => "assert", "kind" => "url_contains", "value" => "example.com"},
      %{"action" => "assert", "kind" => "text", "value" => "Example"},
      %{"action" => "find_elements"},
      %{"action" => "extract"}
    ]

    assert {:ok, report} = BackgroundFlow.run(steps)
    assert report.status == "passed"
    assert length(report.steps) == 6

    extract = List.last(report.steps)
    assert extract.detail["text"] =~ "Example"
  end
end
