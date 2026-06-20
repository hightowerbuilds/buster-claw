defmodule BusterClaw.BrowserTest do
  use BusterClaw.DataCase

  alias BusterClaw.Browser

  setup do
    Req.Test.verify_on_exit!()
    :ok
  end

  test "fetches a rendered page through the HTTP fallback boundary" do
    Req.Test.stub(BusterClaw.BrowserHTTP, fn conn ->
      Req.Test.html(
        conn,
        "<html><head><title>Rendered</title></head><body><p>Hello</p></body></html>"
      )
    end)

    assert {:ok, page} =
             Browser.fetch("https://example.com",
               req_options: [plug: {Req.Test, BusterClaw.BrowserHTTP}]
             )

    assert page.title == "Rendered"
    assert page.markdown =~ "Hello"
    assert Browser.status().mode == "http-fallback"
  end

  test "fetches rendered HTML through a sidecar endpoint" do
    Req.Test.stub(BusterClaw.BrowserSidecarHTTP, fn conn ->
      assert conn.method == "POST"
      assert conn.request_path == "/fetch"

      Req.Test.json(conn, %{
        url: "https://example.com/rendered",
        title: "Sidecar Rendered",
        html: "<html><body><main>Client rendered body</main></body></html>"
      })
    end)

    assert {:ok, page} =
             Browser.fetch("https://example.com",
               sidecar_url: "http://sidecar.test",
               sidecar_req_options: [plug: {Req.Test, BusterClaw.BrowserSidecarHTTP}]
             )

    assert page.url == "https://example.com/rendered"
    assert page.title == "Sidecar Rendered"
    assert page.markdown =~ "Client rendered body"
  end

  test "can report a configured sidecar" do
    previous = Application.get_env(:buster_claw, :browser_sidecar_url)
    Application.put_env(:buster_claw, :browser_sidecar_url, "http://127.0.0.1:1234")

    on_exit(fn ->
      if previous do
        Application.put_env(:buster_claw, :browser_sidecar_url, previous)
      else
        Application.delete_env(:buster_claw, :browser_sidecar_url)
      end
    end)

    assert %{mode: "sidecar", sidecar: "configured", url: "http://127.0.0.1:1234"} =
             Browser.status()
  end

  test "sidecar supervisor stays alive when the node executable is unavailable" do
    start_supervised!({BusterClaw.Browser.Sidecar, executable: "missing-browser-sidecar-node"})

    assert %{enabled: true, health: "unavailable"} = BusterClaw.Browser.Sidecar.status()
    assert :unavailable = BusterClaw.Browser.Sidecar.url()
  end

  describe "download/2" do
    test "returns raw bytes (no markdown) with the server-declared filename" do
      Req.Test.stub(BusterClaw.BrowserHTTP, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/pdf")
        |> Plug.Conn.put_resp_header("content-disposition", ~s(attachment; filename="report.pdf"))
        |> Plug.Conn.send_resp(200, <<37, 80, 68, 70, 1, 2, 3>>)
      end)

      assert {:ok, dl} =
               Browser.download("https://example.com/x",
                 req_options: [plug: {Req.Test, BusterClaw.BrowserHTTP}]
               )

      assert dl.body == <<37, 80, 68, 70, 1, 2, 3>>
      assert dl.filename == "report.pdf"
      assert dl.content_type =~ "application/pdf"
    end

    test "derives the filename from the URL path when no content-disposition" do
      Req.Test.stub(BusterClaw.BrowserHTTP, fn conn ->
        Plug.Conn.send_resp(conn, 200, "zip-bytes")
      end)

      assert {:ok, %{filename: "manual.zip", body: "zip-bytes"}} =
               Browser.download("https://example.com/files/manual.zip",
                 req_options: [plug: {Req.Test, BusterClaw.BrowserHTTP}]
               )
    end

    test "refuses a blocked / invalid URL before any request" do
      assert {:error, {:blocked_url, _reason}} = Browser.download("not-a-url")
    end
  end
end
