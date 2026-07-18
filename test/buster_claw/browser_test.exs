defmodule BusterClaw.BrowserTest do
  use BusterClaw.DataCase

  alias BusterClaw.Browser
  alias BusterClaw.Browser.Bridge

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
  end

  describe "live-render fallback" do
    @thin_html ~s(<html><body><div id="root"></div><script src="/app.js"></script></body></html>)

    setup do
      prev_enabled = Application.get_env(:buster_claw, :browser_live_render_enabled)
      prev_timeout = Application.get_env(:buster_claw, :browser_live_render_timeout_ms)
      Application.put_env(:buster_claw, :browser_live_render_enabled, true)
      Application.put_env(:buster_claw, :browser_live_render_timeout_ms, 300)

      on_exit(fn ->
        restore_env(:browser_live_render_enabled, prev_enabled)
        restore_env(:browser_live_render_timeout_ms, prev_timeout)
      end)

      :ok
    end

    defp restore_env(key, nil), do: Application.delete_env(:buster_claw, key)
    defp restore_env(key, value), do: Application.put_env(:buster_claw, key, value)

    defp stub_thin_http do
      Req.Test.stub(BusterClaw.BrowserHTTP, fn conn -> Req.Test.html(conn, @thin_html) end)
    end

    # A fake desktop shell: subscribes to the bridge and fulfils one :render
    # request with the given page. Synchronizes on :subscribed so available?
    # is true before the fetch starts.
    defp fake_desktop(page) do
      parent = self()

      spawn_link(fn ->
        Bridge.subscribe()
        send(parent, :subscribed)

        receive do
          {:browser_command, ref, :render, _payload} ->
            Bridge.fulfill(ref, {:ok, %{data: Jason.encode!(page)}})
        after
          2_000 -> :ok
        end
      end)

      assert_receive :subscribed
    end

    test "a JS-thin page upgrades to the desktop's hidden-webview render" do
      stub_thin_http()

      fake_desktop(%{
        url: "https://spa.example/",
        title: "SPA",
        text: "Hydrated content",
        links: [%{label: "Docs", url: "https://spa.example/docs"}]
      })

      assert {:ok, page} =
               Browser.fetch("https://spa.example",
                 req_options: [plug: {Req.Test, BusterClaw.BrowserHTTP}]
               )

      assert page.rendered == "live"
      assert page.title == "SPA"
      assert page.markdown =~ "Hydrated content"
      assert page.markdown =~ "[Docs](https://spa.example/docs)"
    end

    test "a failed plain fetch still tries the live render" do
      Req.Test.stub(BusterClaw.BrowserHTTP, fn conn -> Plug.Conn.send_resp(conn, 403, "") end)

      fake_desktop(%{
        url: "https://walled.example/",
        title: "Walled",
        text: "Real page",
        links: []
      })

      assert {:ok, page} =
               Browser.fetch("https://walled.example",
                 req_options: [plug: {Req.Test, BusterClaw.BrowserHTTP}]
               )

      assert page.rendered == "live"
      assert page.markdown =~ "Real page"
    end

    test "a text-rich page never touches the bridge" do
      Req.Test.stub(BusterClaw.BrowserHTTP, fn conn ->
        Req.Test.html(
          conn,
          "<html><body><article>#{String.duplicate("plenty of readable words ", 30)}</article></body></html>"
        )
      end)

      Bridge.subscribe()

      assert {:ok, page} =
               Browser.fetch("https://rich.example",
                 req_options: [plug: {Req.Test, BusterClaw.BrowserHTTP}]
               )

      refute Map.has_key?(page, :rendered)
      refute_received {:browser_command, _ref, :render, _payload}
    end

    test "render: :off forbids the upgrade even for thin pages" do
      stub_thin_http()
      Bridge.subscribe()

      assert {:ok, page} =
               Browser.fetch("https://spa.example",
                 render: :off,
                 req_options: [plug: {Req.Test, BusterClaw.BrowserHTTP}]
               )

      refute Map.has_key?(page, :rendered)
      refute_received {:browser_command, _ref, :render, _payload}
    end

    test "no desktop attached degrades to the plain result without waiting" do
      stub_thin_http()

      assert {:ok, page} =
               Browser.fetch("https://spa.example",
                 req_options: [plug: {Req.Test, BusterClaw.BrowserHTTP}]
               )

      refute Map.has_key?(page, :rendered)
    end

    test "render: :live with no desktop degrades to the classic pipeline" do
      stub_thin_http()

      assert {:ok, page} =
               Browser.fetch("https://spa.example",
                 render: :live,
                 req_options: [plug: {Req.Test, BusterClaw.BrowserHTTP}]
               )

      refute Map.has_key?(page, :rendered)
    end
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

    test "aborts and reports too_large when the body exceeds max_bytes" do
      Req.Test.stub(BusterClaw.BrowserHTTP, fn conn ->
        Plug.Conn.send_resp(conn, 200, String.duplicate("x", 5_000))
      end)

      assert {:error, {:too_large, bytes}} =
               Browser.download("https://example.com/big.bin",
                 max_bytes: 1_000,
                 req_options: [plug: {Req.Test, BusterClaw.BrowserHTTP}]
               )

      assert bytes > 1_000
    end
  end
end
