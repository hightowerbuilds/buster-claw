defmodule BusterClaw.Browser.ActivityTest do
  use BusterClaw.DataCase, async: true

  alias BusterClaw.Browser.Activity

  test "persists receipts without URL credentials, query strings, fragments, or extra payload" do
    {:ok, event} =
      Activity.record(%{
        source: "shared",
        action: "fill",
        outcome: "ok",
        url: "https://alice:password@example.com/form?token=private#secret",
        value: "a private password",
        text: "private page body"
      })

    assert event.url == "https://example.com/form"
    [stored] = Activity.snapshot().events
    refute Map.has_key?(Map.from_struct(stored), :value)
    refute Jason.encode!(stored) =~ "private"
  end

  test "filters before bounding and returns chronological receipts with a truncation indicator" do
    for n <- 1..202 do
      {:ok, _} =
        Activity.record(%{source: "shared", action: "read", outcome: "ok", duration_ms: n})
    end

    {:ok, first} =
      Activity.record(%{source: "agent", run_id: "run-a", action: "navigate", outcome: "ok"})

    {:ok, second} =
      Activity.record(%{source: "agent", run_id: "run-a", action: "halt", outcome: "halted"})

    {:ok, _} = Activity.record(%{source: "agent", run_id: "run-b", action: "read", outcome: "ok"})

    assert %{events: [^first, ^second], truncated: false} =
             Activity.snapshot(%{"run_id" => "run-a"})

    assert %{events: events, truncated: true, limit: 200} =
             Activity.snapshot(%{"source" => "shared"})

    assert length(events) == 200
    assert hd(events).duration_ms == 3
    assert List.last(events).duration_ms == 202
  end

  test "refuses non-web URLs and malformed addresses" do
    for url <- [
          "file:///private/file",
          "javascript:alert(1)",
          "data:text/html,secret",
          "/local",
          nil
        ] do
      assert Activity.sanitize_url(url) == nil
    end
  end
end
