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
    assert {:error, :missing_index} = Commands.browser_click(%{})
    assert {:error, :missing_index} = Commands.browser_click(%{"index" => "3"})
    assert {:error, :missing_index} = Commands.browser_click(%{"index" => -1})
    assert {:error, :missing_index_or_value} = Commands.browser_fill(%{"index" => 1})
    assert {:error, :missing_index_or_value} = Commands.browser_fill(%{"value" => "x"})

    assert {:error, :missing_index_or_value} =
             Commands.browser_fill(%{"index" => 1, "value" => 5})
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
end
