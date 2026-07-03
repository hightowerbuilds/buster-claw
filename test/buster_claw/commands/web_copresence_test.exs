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

  test "browser_tabs reads the durable per-surface tab state" do
    state = %{"tabs" => [%{"url" => "https://a.com", "label" => "A"}], "active" => 0}
    BusterClaw.Settings.put("browser_tabs.main", Jason.encode!(state))

    assert {:ok, %{surface: "main", tabs: [%{"url" => "https://a.com"}], active: 0}} =
             Commands.browser_tabs()

    # Unknown/hostile surface ids collapse safely and read as empty.
    assert {:ok, %{surface: "etc", tabs: []}} = Commands.browser_tabs(%{"surface" => "../etc"})
  end
end
