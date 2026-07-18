defmodule BusterClaw.Commands.WebCopresenceTest do
  use BusterClaw.DataCase, async: false

  alias BusterClaw.Browser.Bridge
  alias BusterClaw.Commands

  test "browser_read decodes the page payload and records a Sentinel event" do
    Bridge.subscribe()
    task = Task.async(fn -> Commands.browser_read() end)
    assert_receive {:browser_command, ref, :read, _payload}, 1_000

    page = %{
      "url" => "https://app.example.com/dashboard",
      "title" => "Dashboard",
      "text" => "Welcome back, Luke",
      "links" => [%{"label" => "Settings", "url" => "https://app.example.com/settings"}]
    }

    Bridge.fulfill(ref, {:ok, %{data: Jason.encode!(page)}})

    assert {:ok, result} = Task.await(task)
    assert result.url == "https://app.example.com/dashboard"
    assert result.text =~ "Welcome back"
    assert [%{"label" => "Settings"} | _] = result.links

    assert [event | _] = BusterClaw.Sentinel.list_events(limit: 1)
    assert event.category == "untrusted_ingest"
    assert event.message =~ "Read live tab https://app.example.com/dashboard"
    assert event.metadata["via"] == "browser_read"
  end

  test "browser_read surfaces a malformed payload as an error (no Sentinel event)" do
    Bridge.subscribe()
    task = Task.async(fn -> Commands.browser_read() end)
    assert_receive {:browser_command, ref, :read, _payload}, 1_000

    Bridge.fulfill(ref, {:ok, %{data: "not json"}})
    assert {:error, :bad_page_payload} = Task.await(task)
  end

  test "browser_find_elements decodes the element list and records a Sentinel event" do
    Bridge.subscribe()
    task = Task.async(fn -> Commands.browser_find_elements(%{"query" => "sign"}) end)
    assert_receive {:browser_command, ref, :find_elements, %{"query" => "sign"}}, 1_000

    elements = [
      %{
        "i" => 0,
        "tag" => "a",
        "type" => "",
        "label" => "Sign out",
        "value" => "",
        "href" => "https://app.example.com/logout"
      },
      %{
        "i" => 1,
        "tag" => "button",
        "type" => "submit",
        "label" => "Sign in",
        "value" => "",
        "href" => ""
      }
    ]

    Bridge.fulfill(ref, {:ok, %{data: Jason.encode!(elements)}})

    assert {:ok, %{count: 2, elements: [first | _]}} = Task.await(task)
    assert first["label"] == "Sign out"

    assert [event | _] = BusterClaw.Sentinel.list_events(limit: 1)
    assert event.category == "untrusted_ingest"
    assert event.message =~ "Listed 2 interactive elements"
    assert event.metadata["via"] == "browser_find_elements"
    assert event.metadata["query"] == "sign"
  end

  test "browser_find_elements omits the query from the payload when blank and errors on bad JSON" do
    Bridge.subscribe()
    task = Task.async(fn -> Commands.browser_find_elements() end)
    assert_receive {:browser_command, ref, :find_elements, payload}, 1_000
    refute Map.has_key?(payload, "query")

    Bridge.fulfill(ref, {:ok, %{data: "not json"}})
    assert {:error, :bad_elements_payload} = Task.await(task)
  end

  test "browser_click records a Sentinel event carrying index + label provenance" do
    Bridge.subscribe()
    task = Task.async(fn -> Commands.browser_click(%{"index" => 3}) end)
    assert_receive {:browser_command, ref, :click, %{"index" => 3}}, 1_000

    Bridge.fulfill(ref, {:ok, %{data: Jason.encode!(%{"ok" => true, "label" => "Sign out"})}})

    assert {:ok, %{clicked: 3, label: "Sign out"}} = Task.await(task)

    assert [event | _] = BusterClaw.Sentinel.list_events(limit: 1)
    assert event.category == "outbound_send"
    assert event.message =~ "Clicked element #3 (Sign out)"
    assert event.metadata["via"] == "browser_click"
    assert event.metadata["index"] == 3
    assert event.metadata["label"] == "Sign out"
  end

  test "browser_click surfaces a stale index as an error, not silence (no Sentinel event)" do
    Bridge.subscribe()
    before = length(BusterClaw.Sentinel.list_events())

    task = Task.async(fn -> Commands.browser_click(%{"index" => 42}) end)
    assert_receive {:browser_command, ref, :click, %{"index" => 42}}, 1_000

    stale = %{"ok" => false, "error" => "stale index — call browser_find_elements again"}
    Bridge.fulfill(ref, {:ok, %{data: Jason.encode!(stale)}})

    assert {:error, {:element_action_failed, "stale index" <> _}} = Task.await(task)
    assert length(BusterClaw.Sentinel.list_events()) == before
  end

  test "browser_fill records a Sentinel event with the value LENGTH, never the raw value" do
    Bridge.subscribe()
    secret = "hunter2-super-secret"
    task = Task.async(fn -> Commands.browser_fill(%{"index" => 1, "value" => secret}) end)
    assert_receive {:browser_command, ref, :fill, %{"index" => 1, "value" => ^secret}}, 1_000

    Bridge.fulfill(ref, {:ok, %{data: Jason.encode!(%{"ok" => true, "label" => "Email"})}})

    assert {:ok, %{filled: 1, label: "Email", value_length: 20}} = Task.await(task)

    assert [event | _] = BusterClaw.Sentinel.list_events(limit: 1)
    assert event.category == "outbound_send"
    assert event.message =~ "Filled element #1 (Email)"
    assert event.metadata["via"] == "browser_fill"
    assert event.metadata["index"] == 1
    assert event.metadata["label"] == "Email"
    assert event.metadata["value_length"] == 20
    refute inspect(event.metadata) =~ secret
    refute event.message =~ secret
  end

  test "browser_fill rejects a non-fillable element as an error" do
    Bridge.subscribe()
    task = Task.async(fn -> Commands.browser_fill(%{"index" => 0, "value" => "x"}) end)
    assert_receive {:browser_command, ref, :fill, _payload}, 1_000

    Bridge.fulfill(
      ref,
      {:ok, %{data: Jason.encode!(%{"ok" => false, "error" => "not fillable (a)"})}}
    )

    assert {:error, {:element_action_failed, "not fillable (a)"}} = Task.await(task)
  end

  test "click/fill reject malformed args without a bridge round-trip" do
    Bridge.subscribe()

    assert {:error, :missing_target} = Commands.browser_click(%{})
    assert {:error, :missing_target} = Commands.browser_click(%{"index" => "3"})
    assert {:error, :missing_target} = Commands.browser_click(%{"index" => -1})
    assert {:error, :missing_target} = Commands.browser_click(%{"selector" => ""})
    assert {:error, :missing_target} = Commands.browser_click(%{"text" => ""})
    assert {:error, :missing_target_or_value} = Commands.browser_fill(%{"index" => 1})
    assert {:error, :missing_target_or_value} = Commands.browser_fill(%{"value" => "x"})
    assert {:error, :missing_target_or_value} = Commands.browser_fill(%{"selector" => "#email"})
    assert {:error, :missing_target_or_value} = Commands.browser_fill(%{"text" => "Email"})

    assert {:error, :missing_target_or_value} =
             Commands.browser_fill(%{"index" => 1, "value" => 5})

    refute_received {:browser_command, _ref, _action, _payload}
  end

  test "click/fill surface a malformed desktop payload cleanly" do
    Bridge.subscribe()
    task = Task.async(fn -> Commands.browser_click(%{"index" => 0}) end)
    assert_receive {:browser_command, ref, :click, _payload}, 1_000

    Bridge.fulfill(ref, {:ok, %{data: "not json"}})
    assert {:error, :bad_element_payload} = Task.await(task)
  end

  test "browser_tabs reads the durable per-surface tab state" do
    state = %{"tabs" => [%{"url" => "https://a.com", "label" => "A"}], "active" => 0}
    BusterClaw.Settings.put("browser_tabs.main", Jason.encode!(state))

    assert {:ok, %{surface: "main", tabs: [%{"url" => "https://a.com"}], active: 0}} =
             Commands.browser_tabs()

    # Unknown/hostile surface ids collapse safely and read as empty.
    assert {:ok, %{surface: "etc", tabs: []}} = Commands.browser_tabs(%{"surface" => "../etc"})
  end

  test "browser_open_tab defaults to an ephemeral sandbox session" do
    Bridge.subscribe()
    task = Task.async(fn -> Commands.browser_open_tab(%{"url" => "https://example.com"}) end)
    assert_receive {:browser_command, ref, :open_tab, payload}, 1_000
    assert payload["session"] == "ephemeral"

    Bridge.fulfill(ref, {:ok, %{}})
    assert {:ok, %{opened: "https://example.com", session: "ephemeral"}} = Task.await(task)
  end

  test ~s(browser_open_tab session: "user" explicitly rides the user's session) do
    Bridge.subscribe()

    task =
      Task.async(fn ->
        Commands.browser_open_tab(%{"url" => "https://example.com", "session" => "user"})
      end)

    assert_receive {:browser_command, ref, :open_tab, payload}, 1_000
    assert payload["session"] == "user"

    Bridge.fulfill(ref, {:ok, %{}})
    assert {:ok, %{session: "user"}} = Task.await(task)
  end

  # -----------------------------------------------------------------------
  # browser_wait
  # -----------------------------------------------------------------------

  test "browser_wait relays the condition and reports a match (no Sentinel event)" do
    Bridge.subscribe()
    before = length(BusterClaw.Sentinel.list_events())

    task =
      Task.async(fn ->
        Commands.browser_wait(%{"until" => "selector", "value" => "#app", "timeout_ms" => 5_000})
      end)

    assert_receive {:browser_command, ref, :wait, payload}, 1_000
    assert payload["condition"] == "selector"
    assert payload["value"] == "#app"
    assert payload["timeout_ms"] == 5_000

    verdict = %{"ok" => true, "matched" => true, "waited_ms" => 320, "condition" => "selector"}
    Bridge.fulfill(ref, {:ok, %{data: Jason.encode!(verdict)}})

    assert {:ok, %{matched: true, waited_ms: 320, until: "selector"}} = Task.await(task)
    assert length(BusterClaw.Sentinel.list_events()) == before
  end

  test "browser_wait treats an exhausted budget as matched: false, not an error" do
    Bridge.subscribe()
    task = Task.async(fn -> Commands.browser_wait(%{"until" => "text", "value" => "Done"}) end)
    assert_receive {:browser_command, ref, :wait, %{"condition" => "text"}}, 1_000

    verdict = %{"ok" => true, "matched" => false, "waited_ms" => 10_000, "condition" => "text"}
    Bridge.fulfill(ref, {:ok, %{data: Jason.encode!(verdict)}})

    assert {:ok, %{matched: false, waited_ms: 10_000, until: "text"}} = Task.await(task)
  end

  test "browser_wait defaults to navigation/10s and caps timeout_ms at 30s" do
    Bridge.subscribe()
    task = Task.async(fn -> Commands.browser_wait() end)
    assert_receive {:browser_command, ref, :wait, payload}, 1_000
    assert payload["condition"] == "navigation"
    assert payload["timeout_ms"] == 10_000

    verdict = %{"ok" => true, "matched" => true, "waited_ms" => 40, "condition" => "navigation"}
    Bridge.fulfill(ref, {:ok, %{data: Jason.encode!(verdict)}})
    assert {:ok, %{until: "navigation"}} = Task.await(task)

    task = Task.async(fn -> Commands.browser_wait(%{"timeout_ms" => 90_000}) end)
    assert_receive {:browser_command, ref, :wait, payload}, 1_000
    assert payload["timeout_ms"] == 30_000

    Bridge.fulfill(ref, {:ok, %{data: Jason.encode!(verdict)}})
    assert {:ok, _result} = Task.await(task)
  end

  test "browser_wait rejects malformed args without a bridge round-trip" do
    Bridge.subscribe()

    assert {:error, :bad_wait_condition} = Commands.browser_wait(%{"until" => "teleport"})
    assert {:error, :missing_value} = Commands.browser_wait(%{"until" => "selector"})

    assert {:error, :missing_value} =
             Commands.browser_wait(%{"until" => "visible", "value" => ""})

    assert {:error, :missing_value} = Commands.browser_wait(%{"until" => "text", "value" => 5})

    refute_received {:browser_command, _ref, _action, _payload}
  end

  test "browser_wait surfaces a desktop-reported bad condition and malformed payloads" do
    Bridge.subscribe()
    task = Task.async(fn -> Commands.browser_wait(%{"until" => "selector", "value" => "#x"}) end)
    assert_receive {:browser_command, ref, :wait, _payload}, 1_000

    Bridge.fulfill(
      ref,
      {:ok, %{data: Jason.encode!(%{"ok" => false, "error" => "bad selector"})}}
    )

    assert {:error, {:wait_failed, "bad selector"}} = Task.await(task)

    task = Task.async(fn -> Commands.browser_wait() end)
    assert_receive {:browser_command, ref, :wait, _payload}, 1_000

    Bridge.fulfill(ref, {:ok, %{data: "not json"}})
    assert {:error, :bad_wait_payload} = Task.await(task)
  end

  # -----------------------------------------------------------------------
  # browser_extract
  # -----------------------------------------------------------------------

  test "browser_extract without a selector reads the whole page and records a Sentinel event" do
    Bridge.subscribe()
    task = Task.async(fn -> Commands.browser_extract() end)
    assert_receive {:browser_command, ref, :extract, payload}, 1_000
    refute Map.has_key?(payload, "selector")
    refute Map.has_key?(payload, "attr")

    page = %{
      "ok" => true,
      "url" => "https://app.example.com/orders",
      "title" => "Orders",
      "text" => "Order #1042 shipped"
    }

    Bridge.fulfill(ref, {:ok, %{data: Jason.encode!(page)}})

    assert {:ok, result} = Task.await(task)
    assert result.url == "https://app.example.com/orders"
    assert result.title == "Orders"
    assert result.text =~ "shipped"

    assert [event | _] = BusterClaw.Sentinel.list_events(limit: 1)
    assert event.category == "untrusted_ingest"
    assert event.message =~ "Extracted live tab https://app.example.com/orders"
    assert event.metadata["via"] == "browser_extract"
  end

  test "browser_extract with a selector returns the matches and records a Sentinel event" do
    Bridge.subscribe()

    task =
      Task.async(fn ->
        Commands.browser_extract(%{"selector" => ".price", "attr" => "data-sku"})
      end)

    assert_receive {:browser_command, ref, :extract, payload}, 1_000
    assert payload["selector"] == ".price"
    assert payload["attr"] == "data-sku"

    result = %{
      "ok" => true,
      "count" => 2,
      "matches" => [
        %{"text" => "$19.99", "attr" => "sku-1"},
        %{"text" => "$24.99", "attr" => "sku-2"}
      ]
    }

    Bridge.fulfill(ref, {:ok, %{data: Jason.encode!(result)}})

    assert {:ok, %{count: 2, matches: [%{"text" => "$19.99"} | _]}} = Task.await(task)

    assert [event | _] = BusterClaw.Sentinel.list_events(limit: 1)
    assert event.category == "untrusted_ingest"
    assert event.message =~ ~s|Extracted 2 matches for ".price"|
    assert event.metadata["via"] == "browser_extract"
    assert event.metadata["selector"] == ".price"
    assert event.metadata["count"] == 2
  end

  test "browser_extract surfaces malformed payloads as errors (no Sentinel event)" do
    Bridge.subscribe()
    before = length(BusterClaw.Sentinel.list_events())

    task = Task.async(fn -> Commands.browser_extract() end)
    assert_receive {:browser_command, ref, :extract, _payload}, 1_000

    Bridge.fulfill(ref, {:ok, %{data: "not json"}})
    assert {:error, :bad_extract_payload} = Task.await(task)

    task = Task.async(fn -> Commands.browser_extract(%{"selector" => "#gone"}) end)
    assert_receive {:browser_command, ref, :extract, _payload}, 1_000

    Bridge.fulfill(ref, {:ok, %{data: Jason.encode!(%{"ok" => false, "error" => "no document"})}})
    assert {:error, {:extract_failed, "no document"}} = Task.await(task)

    assert length(BusterClaw.Sentinel.list_events()) == before
  end

  # -----------------------------------------------------------------------
  # browser_assert
  # -----------------------------------------------------------------------

  test "browser_assert url_contains checks the current tab and passes" do
    Bridge.subscribe()

    task =
      Task.async(fn ->
        Commands.browser_assert(%{"kind" => "url_contains", "value" => "/checkout"})
      end)

    assert_receive {:browser_command, ref, :current, _payload}, 1_000
    Bridge.fulfill(ref, {:ok, %{url: "https://shop.example.com/checkout", title: "Checkout"}})

    assert {:ok, %{passed: true, kind: "url_contains", detail: detail}} = Task.await(task)
    assert detail == "https://shop.example.com/checkout"
  end

  test "browser_assert title_contains failing is ok-with-passed-false, not an error" do
    Bridge.subscribe()

    task =
      Task.async(fn ->
        Commands.browser_assert(%{"kind" => "title_contains", "value" => "Receipt"})
      end)

    assert_receive {:browser_command, ref, :current, _payload}, 1_000
    Bridge.fulfill(ref, {:ok, %{url: "https://shop.example.com/cart", title: "Your cart"}})

    assert {:ok, %{passed: false, kind: "title_contains", detail: "Your cart"}} = Task.await(task)
  end

  test "browser_assert selector probes via a 250ms wait" do
    Bridge.subscribe()

    task =
      Task.async(fn ->
        Commands.browser_assert(%{"kind" => "selector", "value" => ".order-confirmed"})
      end)

    assert_receive {:browser_command, ref, :wait, payload}, 1_000
    assert payload["condition"] == "selector"
    assert payload["value"] == ".order-confirmed"
    assert payload["timeout_ms"] == 250

    verdict = %{"ok" => true, "matched" => true, "waited_ms" => 0, "condition" => "selector"}
    Bridge.fulfill(ref, {:ok, %{data: Jason.encode!(verdict)}})

    assert {:ok, %{passed: true, kind: "selector", detail: "matched after 0ms"}} =
             Task.await(task)
  end

  test "browser_assert text probe that never matches comes back passed: false" do
    Bridge.subscribe()

    task =
      Task.async(fn -> Commands.browser_assert(%{"kind" => "text", "value" => "Thank you"}) end)

    assert_receive {:browser_command, ref, :wait, payload}, 1_000
    assert payload["condition"] == "text"
    assert payload["timeout_ms"] == 250

    verdict = %{"ok" => true, "matched" => false, "waited_ms" => 250, "condition" => "text"}
    Bridge.fulfill(ref, {:ok, %{data: Jason.encode!(verdict)}})

    assert {:ok, %{passed: false, kind: "text", detail: "no match within 250ms"}} =
             Task.await(task)
  end

  test "browser_assert rejects malformed args without a bridge round-trip" do
    Bridge.subscribe()

    assert {:error, :missing_kind_or_value} = Commands.browser_assert(%{})
    assert {:error, :missing_kind_or_value} = Commands.browser_assert(%{"kind" => "url_contains"})
    assert {:error, :missing_kind_or_value} = Commands.browser_assert(%{"kind" => "smells_like"})

    assert {:error, :missing_kind_or_value} =
             Commands.browser_assert(%{"kind" => "text", "value" => ""})

    refute_received {:browser_command, _ref, _action, _payload}
  end

  # -----------------------------------------------------------------------
  # browser_click / browser_fill by selector / text
  # -----------------------------------------------------------------------

  test "browser_click by selector relays the target and records matched_by provenance" do
    Bridge.subscribe()
    task = Task.async(fn -> Commands.browser_click(%{"selector" => "#buy-now"}) end)
    assert_receive {:browser_command, ref, :click, %{"selector" => "#buy-now"}}, 1_000

    result = %{"ok" => true, "label" => "Buy now", "matched_by" => "selector"}
    Bridge.fulfill(ref, {:ok, %{data: Jason.encode!(result)}})

    assert {:ok, %{clicked: "#buy-now", label: "Buy now", matched_by: "selector"}} =
             Task.await(task)

    assert [event | _] = BusterClaw.Sentinel.list_events(limit: 1)
    assert event.category == "outbound_send"
    assert event.message =~ ~s|Clicked element matching "#buy-now" (Buy now)|
    assert event.metadata["via"] == "browser_click"
    assert event.metadata["selector"] == "#buy-now"
    assert event.metadata["matched_by"] == "selector"
  end

  test "browser_click by text relays the target and records matched_by provenance" do
    Bridge.subscribe()
    task = Task.async(fn -> Commands.browser_click(%{"text" => "Sign out"}) end)
    assert_receive {:browser_command, ref, :click, %{"text" => "Sign out"}}, 1_000

    result = %{"ok" => true, "label" => "Sign out", "matched_by" => "text"}
    Bridge.fulfill(ref, {:ok, %{data: Jason.encode!(result)}})

    assert {:ok, %{clicked: "Sign out", label: "Sign out", matched_by: "text"}} = Task.await(task)

    assert [event | _] = BusterClaw.Sentinel.list_events(limit: 1)
    assert event.category == "outbound_send"
    assert event.message =~ ~s|Clicked element with text "Sign out"|
    assert event.metadata["text"] == "Sign out"
    assert event.metadata["matched_by"] == "text"
  end

  test "browser_fill by selector logs the value LENGTH, never the raw value" do
    Bridge.subscribe()
    secret = "correct-horse-battery"

    task =
      Task.async(fn ->
        Commands.browser_fill(%{"selector" => "input[name=email]", "value" => secret})
      end)

    assert_receive {:browser_command, ref, :fill, payload}, 1_000
    assert payload["selector"] == "input[name=email]"
    assert payload["value"] == secret

    result = %{"ok" => true, "label" => "Email", "matched_by" => "selector"}
    Bridge.fulfill(ref, {:ok, %{data: Jason.encode!(result)}})

    assert {:ok, %{filled: "input[name=email]", label: "Email", matched_by: "selector"} = ok} =
             Task.await(task)

    assert ok.value_length == String.length(secret)

    assert [event | _] = BusterClaw.Sentinel.list_events(limit: 1)
    assert event.category == "outbound_send"
    assert event.metadata["via"] == "browser_fill"
    assert event.metadata["selector"] == "input[name=email]"
    assert event.metadata["matched_by"] == "selector"
    assert event.metadata["value_length"] == String.length(secret)
    refute inspect(event.metadata) =~ secret
    refute event.message =~ secret
  end

  test "browser_fill by text logs the value LENGTH, never the raw value" do
    Bridge.subscribe()
    secret = "hunter2-forever"
    task = Task.async(fn -> Commands.browser_fill(%{"text" => "Email", "value" => secret}) end)

    assert_receive {:browser_command, ref, :fill, %{"text" => "Email", "value" => ^secret}}, 1_000

    result = %{"ok" => true, "label" => "Email", "matched_by" => "text"}
    Bridge.fulfill(ref, {:ok, %{data: Jason.encode!(result)}})

    assert {:ok, %{filled: "Email", matched_by: "text", value_length: 15}} = Task.await(task)

    assert [event | _] = BusterClaw.Sentinel.list_events(limit: 1)
    assert event.category == "outbound_send"
    assert event.metadata["text"] == "Email"
    assert event.metadata["value_length"] == 15
    refute inspect(event.metadata) =~ secret
    refute event.message =~ secret
  end

  test "selector/text click failures surface the desktop error (no Sentinel event)" do
    Bridge.subscribe()
    before = length(BusterClaw.Sentinel.list_events())

    task = Task.async(fn -> Commands.browser_click(%{"selector" => "#gone"}) end)
    assert_receive {:browser_command, ref, :click, _payload}, 1_000

    Bridge.fulfill(
      ref,
      {:ok, %{data: Jason.encode!(%{"ok" => false, "error" => "no element matched"})}}
    )

    assert {:error, {:element_action_failed, "no element matched"}} = Task.await(task)
    assert length(BusterClaw.Sentinel.list_events()) == before
  end
end
