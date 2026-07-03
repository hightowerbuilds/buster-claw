defmodule BusterClaw.Commands.WebCloudTest do
  @moduledoc "Phase 2: the web_* cloud-browser primitive commands."
  use BusterClaw.DataCase, async: false

  alias BusterClaw.Browser.Bridge
  alias BusterClaw.Browserbase.Session, as: CloudSession
  alias BusterClaw.Browserbase.SessionManager
  alias BusterClaw.Commands.Web
  alias BusterClaw.Sentinel

  @side BusterClaw.CloudSideStub

  # Fakes for the SessionManager so open/close do NO HTTP (they run in the
  # manager process). The driving verbs run in the TEST process via the real
  # SessionClient, so they hit the same-process Req.Test sidecar stub below.
  defmodule FakeBB do
    def create(_opts),
      do: {:ok, %{id: "bb-1", connect_url: "wss://connect/bb-1", status: "RUNNING"}}

    def debug(_id, _opts), do: {:ok, %{live_view_url: "https://live/bb-1"}}
    def release(_id, _opts), do: :ok
  end

  defmodule FakeSide do
    def open(_connect_url, _opts), do: {:ok, %{"id" => "sc-1"}}
    def close(_id, _opts), do: :ok
  end

  setup do
    prev = %{
      enabled: Application.get_env(:buster_claw, :browserbase_enabled),
      key: Application.get_env(:buster_claw, :browserbase_api_key),
      url: Application.get_env(:buster_claw, :browser_sidecar_url),
      ro: Application.get_env(:buster_claw, :browser_sidecar_req_options)
    }

    Application.put_env(:buster_claw, :browserbase_enabled, true)
    Application.put_env(:buster_claw, :browserbase_api_key, "test-key")
    Application.put_env(:buster_claw, :browser_sidecar_url, "http://sidecar.test")
    Application.put_env(:buster_claw, :browser_sidecar_req_options, plug: {Req.Test, @side})

    on_exit(fn ->
      put_or_delete(:browserbase_enabled, prev.enabled)
      put_or_delete(:browserbase_api_key, prev.key)
      put_or_delete(:browser_sidecar_url, prev.url)
      put_or_delete(:browser_sidecar_req_options, prev.ro)
    end)

    start_supervised!(
      {SessionManager, [client: FakeBB, session_client: FakeSide, sweep_interval_ms: 10_000]}
    )

    :ok
  end

  defp put_or_delete(key, nil), do: Application.delete_env(:buster_claw, key)
  defp put_or_delete(key, val), do: Application.put_env(:buster_claw, key, val)

  defp open_session,
    do:
      (fn ->
         {:ok, %{session_id: sid}} = Web.web_session_open(%{})
         sid
       end).()

  test "open → navigate → read → fill flow drives the session" do
    Req.Test.stub(@side, fn conn ->
      case conn.request_path do
        "/session/navigate" ->
          Req.Test.json(conn, %{"url" => "https://example.com", "title" => "Example"})

        "/session/read" ->
          Req.Test.json(conn, %{
            "url" => "https://example.com",
            "title" => "Example",
            "html" => "<h1>Hi there</h1>"
          })

        "/session/fill" ->
          Req.Test.json(conn, %{"ok" => true, "readback_matches" => true})
      end
    end)

    assert {:ok, open} = Web.web_session_open(%{})
    assert open.live_view_url == "https://live/bb-1"
    sid = open.session_id

    assert {:ok, nav} = Web.web_navigate(%{"session_id" => sid, "url" => "https://example.com"})
    assert nav.title == "Example"

    assert {:ok, page} = Web.web_read(%{"session_id" => sid})
    assert page.markdown =~ "Hi there"

    assert {:ok, fill} =
             Web.web_fill(%{"session_id" => sid, "selector" => "#u", "value" => "hello"})

    assert fill.value_length == 5
  end

  test "web_read records an untrusted_ingest with provenance" do
    Req.Test.stub(@side, fn conn ->
      Req.Test.json(conn, %{
        "url" => "https://example.com",
        "title" => "Example",
        "html" => "<p>x</p>"
      })
    end)

    sid = open_session()
    assert {:ok, _} = Web.web_read(%{"session_id" => sid})

    assert Enum.any?(Sentinel.list_events(limit: 50), fn e ->
             e.category == "untrusted_ingest" and e.metadata["via"] == "web_read"
           end)
  end

  test "web_fill audits the value length, never the raw value" do
    Req.Test.stub(@side, fn conn -> Req.Test.json(conn, %{"ok" => true}) end)
    sid = open_session()

    assert {:ok, _} =
             Web.web_fill(%{"session_id" => sid, "selector" => "#u", "value" => "supersecret"})

    event =
      Sentinel.list_events(limit: 50)
      |> Enum.find(&(&1.metadata["via"] == "web_fill"))

    assert event.metadata["value_length"] == 11
    refute Map.has_key?(event.metadata, "value")
    refute inspect(event.metadata) =~ "supersecret"
  end

  test "web_click refuses a submit/pay affordance and audits a security_block" do
    sid = open_session()

    assert {:error, {:submit_affordance_refused, _}} =
             Web.web_click(%{"session_id" => sid, "selector" => "button#checkout"})

    assert Enum.any?(Sentinel.list_events(limit: 50), fn e ->
             e.category == "security_block" and e.metadata["via"] == "web_click"
           end)

    # a non-submit click drives through
    Req.Test.stub(@side, fn conn ->
      Req.Test.json(conn, %{"url" => "https://x", "title" => "X"})
    end)

    assert {:ok, %{clicked: "a.next"}} =
             Web.web_click(%{"session_id" => sid, "selector" => "a.next"})
  end

  test "submit_affordance? flags pay/submit selectors, not ordinary ones" do
    assert CloudSession.submit_affordance?("button#checkout")
    assert CloudSession.submit_affordance?("input[type=submit]")
    assert CloudSession.submit_affordance?(".pay-now")
    refute CloudSession.submit_affordance?("#username")
    refute CloudSession.submit_affordance?("a.nav-link")
  end

  test "session list and close" do
    sid = open_session()
    assert {:ok, %{count: 1, sessions: [%{session_id: ^sid}]}} = Web.web_session_list(%{})
    assert {:ok, %{closed: ^sid}} = Web.web_session_close(%{"session_id" => sid})
    assert {:ok, %{count: 0}} = Web.web_session_list(%{})
  end

  test "web_session_view opens the live-view url as an ephemeral tab in the browser" do
    sid = open_session()
    Bridge.subscribe()

    task = Task.async(fn -> Web.web_session_view(%{"session_id" => sid}) end)

    assert_receive {:browser_command, ref, :open_tab, payload}, 2_000
    assert payload["url"] == "https://live/bb-1"
    assert payload["session"] == "ephemeral"
    Bridge.fulfill(ref, {:ok, %{}})

    assert {:ok, %{opened: true, live_view_url: "https://live/bb-1"}} = Task.await(task)
  end

  test "commands return :not_configured when Browserbase is disabled" do
    Application.put_env(:buster_claw, :browserbase_enabled, false)
    assert {:error, :not_configured} = Web.web_session_open(%{})
    assert {:error, :not_configured} = Web.web_read(%{"session_id" => "whatever"})
  end
end
