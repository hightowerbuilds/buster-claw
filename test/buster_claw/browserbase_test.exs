defmodule BusterClaw.BrowserbaseTest do
  use ExUnit.Case, async: false

  alias BusterClaw.Browserbase

  @stub BusterClaw.BrowserbaseHTTP
  @opts [req_options: [plug: {Req.Test, BusterClaw.BrowserbaseHTTP}]]

  setup do
    Req.Test.verify_on_exit!()

    prev = %{
      key: Application.get_env(:buster_claw, :browserbase_api_key),
      project: Application.get_env(:buster_claw, :browserbase_project_id),
      enabled: Application.get_env(:buster_claw, :browserbase_enabled)
    }

    on_exit(fn ->
      Application.put_env(:buster_claw, :browserbase_api_key, prev.key)
      Application.put_env(:buster_claw, :browserbase_project_id, prev.project)
      Application.put_env(:buster_claw, :browserbase_enabled, prev.enabled)
    end)

    :ok
  end

  defp configure(key \\ "bb_test_key", project \\ "proj_test") do
    Application.put_env(:buster_claw, :browserbase_api_key, key)
    Application.put_env(:buster_claw, :browserbase_project_id, project)
    Application.put_env(:buster_claw, :browserbase_enabled, true)
  end

  test "create returns id and the CDP connect_url, sending the API key and project" do
    configure()

    Req.Test.stub(@stub, fn conn ->
      assert conn.method == "POST"
      assert conn.request_path == "/v1/sessions"
      assert conn.body_params["projectId"] == "proj_test"
      assert Plug.Conn.get_req_header(conn, "x-bb-api-key") == ["bb_test_key"]

      Req.Test.json(conn, %{
        "id" => "sess-123",
        "connectUrl" => "wss://connect.browserbase.com/sess-123",
        "status" => "RUNNING"
      })
    end)

    assert {:ok, session} = Browserbase.create(@opts)
    assert session.id == "sess-123"
    assert session.connect_url == "wss://connect.browserbase.com/sess-123"
    assert session.status == "RUNNING"
  end

  test "debug returns the interactive live_view_url" do
    configure()

    Req.Test.stub(@stub, fn conn ->
      assert conn.request_path == "/v1/sessions/sess-123/debug"

      Req.Test.json(conn, %{
        "debuggerFullscreenUrl" => "https://www.browserbase.com/devtools-fullscreen/sess-123",
        "debuggerUrl" => "https://www.browserbase.com/devtools/sess-123",
        "wsUrl" => "wss://connect.browserbase.com/debug/sess-123",
        "pages" => []
      })
    end)

    assert {:ok, dbg} = Browserbase.debug("sess-123", @opts)
    assert dbg.live_view_url == "https://www.browserbase.com/devtools-fullscreen/sess-123"
    assert dbg.debugger_url == "https://www.browserbase.com/devtools/sess-123"
    assert dbg.pages == []
  end

  test "release returns :ok on success" do
    configure()

    Req.Test.stub(@stub, fn conn ->
      assert conn.method == "POST"
      assert conn.request_path == "/v1/sessions/sess-123"
      Req.Test.json(conn, %{"status" => "REQUEST_RELEASE"})
    end)

    assert :ok = Browserbase.release("sess-123", @opts)
  end

  test "release treats an already-gone session (404/409) as released" do
    configure()

    Req.Test.stub(@stub, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(404, ~s({"error":"not found"}))
    end)

    assert :ok = Browserbase.release("sess-gone", @opts)
  end

  test "surfaces non-2xx as {:http_error, status, body} for non-release calls" do
    configure()

    Req.Test.stub(@stub, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(500, ~s({"error":"boom"}))
    end)

    assert {:error, {:http_error, 500, _body}} = Browserbase.create(@opts)
  end

  test "every call returns :not_configured when no key is set" do
    Application.put_env(:buster_claw, :browserbase_api_key, nil)

    assert {:error, :not_configured} = Browserbase.create(@opts)
    assert {:error, :not_configured} = Browserbase.debug("sess-123", @opts)
    assert {:error, :not_configured} = Browserbase.release("sess-123", @opts)
    refute Browserbase.enabled?()
  end

  test "enabled? requires both the flag and a key" do
    configure()
    assert Browserbase.enabled?()

    Application.put_env(:buster_claw, :browserbase_enabled, false)
    refute Browserbase.enabled?()

    Application.put_env(:buster_claw, :browserbase_enabled, true)
    Application.put_env(:buster_claw, :browserbase_api_key, "")
    refute Browserbase.enabled?()
  end

  # Real API round-trip. Excluded by default (spends browser-minutes); run with
  # `mix test --include browserbase_live` and BROWSERBASE_API_KEY in the env.
  @tag :browserbase_live
  test "live: create → debug → release against the real API" do
    key = System.get_env("BROWSERBASE_API_KEY")

    if is_nil(key) or key == "" do
      flunk("BROWSERBASE_API_KEY not set — cannot run the live smoke test")
    end

    Application.put_env(:buster_claw, :browserbase_api_key, key)

    Application.put_env(
      :buster_claw,
      :browserbase_project_id,
      System.get_env("BROWSERBASE_PROJECT_ID") || System.get_env("PROJECT_ID")
    )

    assert {:ok, session} = Browserbase.create()
    assert is_binary(session.id)
    assert session.connect_url =~ "browserbase.com"

    assert {:ok, dbg} = Browserbase.debug(session.id)
    assert dbg.live_view_url =~ "browserbase.com"

    assert :ok = Browserbase.release(session.id)
  end
end
