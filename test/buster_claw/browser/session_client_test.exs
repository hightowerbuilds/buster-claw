defmodule BusterClaw.Browser.SessionClientTest do
  use ExUnit.Case, async: false

  alias BusterClaw.Browser.SessionClient

  @stub BusterClaw.SessionSidecarHTTP
  @opts [sidecar_url: "http://sidecar.test", sidecar_req_options: [plug: {Req.Test, @stub}]]

  setup do
    Req.Test.verify_on_exit!()
    :ok
  end

  test "open posts connectUrl and returns the sidecar id" do
    Req.Test.stub(@stub, fn conn ->
      assert conn.method == "POST"
      assert conn.request_path == "/session/open"
      assert conn.body_params["connectUrl"] == "wss://connect/abc"
      Req.Test.json(conn, %{"id" => "sc_1", "url" => "about:blank", "title" => ""})
    end)

    assert {:ok, %{"id" => "sc_1"}} = SessionClient.open("wss://connect/abc", @opts)
  end

  test "drive verbs post to their paths and pass the session id" do
    Req.Test.stub(@stub, fn conn ->
      assert conn.body_params["id"] == "sc_1"

      case conn.request_path do
        "/session/navigate" ->
          Req.Test.json(conn, %{"url" => "https://x", "title" => "X", "status" => 200})

        "/session/read" ->
          Req.Test.json(conn, %{"url" => "https://x", "title" => "X", "html" => "<html></html>"})

        "/session/fill" ->
          Req.Test.json(conn, %{"ok" => true, "readback_matches" => true})
      end
    end)

    assert {:ok, %{"title" => "X"}} = SessionClient.navigate("sc_1", "https://x", @opts)
    assert {:ok, %{"html" => _}} = SessionClient.read("sc_1", @opts)
    assert {:ok, %{"readback_matches" => true}} = SessionClient.fill("sc_1", "#u", "v", @opts)
  end

  test "maps 404 to :unknown_session and 409 to :session_closed" do
    Req.Test.stub(@stub, fn conn ->
      case conn.request_path do
        "/session/read" ->
          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.send_resp(404, ~s({"error":"unknown_session","id":"sc_x"}))

        "/session/click" ->
          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.send_resp(409, ~s({"error":"session_closed","id":"sc_x"}))
      end
    end)

    assert {:error, {:unknown_session, "sc_x"}} = SessionClient.read("sc_x", @opts)
    assert {:error, {:session_closed, "sc_x"}} = SessionClient.click("sc_x", "#go", @opts)
  end

  test "close is idempotent — an unknown session still returns :ok" do
    Req.Test.stub(@stub, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(404, ~s({"error":"unknown_session","id":"sc_gone"}))
    end)

    assert :ok = SessionClient.close("sc_gone", @opts)
  end

  test "unresolvable sidecar yields :sidecar_unavailable" do
    assert {:error, :sidecar_unavailable} = SessionClient.read("sc_1", [])
  end
end
