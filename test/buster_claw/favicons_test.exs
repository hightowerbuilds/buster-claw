defmodule BusterClaw.FaviconsTest do
  use ExUnit.Case, async: false

  alias BusterClaw.Favicons

  @png <<0x89, "PNG\r\n", 0x1A, "\n", "fakebody">>

  setup do
    Req.Test.verify_on_exit!()
    dir = Path.join(System.tmp_dir!(), "favicons_test_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(dir) end)
    {:ok, dir: dir}
  end

  defp stub_icon do
    Req.Test.stub(BusterClaw.FaviconHTTP, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("image/png", nil)
      |> Plug.Conn.send_resp(200, @png)
    end)
  end

  test "fetches, returns, and disk-caches a favicon", %{dir: dir} do
    stub_icon()

    assert {:ok, %{body: @png, content_type: "image/png"}} =
             Favicons.fetch("example.com", cache_dir: dir)

    # Second call is served from disk — stub a failure to prove no re-fetch.
    Req.Test.stub(BusterClaw.FaviconHTTP, fn conn -> Plug.Conn.send_resp(conn, 500, "") end)

    assert {:ok, %{body: @png, content_type: "image/png"}} =
             Favicons.fetch("example.com", cache_dir: dir)
  end

  test "discovers <link rel=icon> when /favicon.ico misses", %{dir: dir} do
    Req.Test.stub(BusterClaw.FaviconHTTP, fn conn ->
      case conn.request_path do
        "/favicon.ico" ->
          Plug.Conn.send_resp(conn, 404, "")

        "/" ->
          conn
          |> Plug.Conn.put_resp_content_type("text/html")
          |> Plug.Conn.send_resp(
            200,
            ~s(<html><head><link rel="apple-touch-icon" href="/big.png">) <>
              ~s(<link rel="icon" type="image/png" href="/static/fav.png"></head></html>)
          )

        "/static/fav.png" ->
          conn
          |> Plug.Conn.put_resp_content_type("image/png", nil)
          |> Plug.Conn.send_resp(200, @png)

        other ->
          flunk("unexpected fetch of #{other} — plain icon rel should win")
      end
    end)

    assert {:ok, %{body: @png, content_type: "image/png"}} =
             Favicons.fetch("spa.example", cache_dir: dir)
  end

  test "follows an absolute declared icon URL", %{dir: dir} do
    Req.Test.stub(BusterClaw.FaviconHTTP, fn conn ->
      case conn.request_path do
        "/favicon.ico" ->
          Plug.Conn.send_resp(conn, 404, "")

        "/" ->
          conn
          |> Plug.Conn.put_resp_content_type("text/html")
          |> Plug.Conn.send_resp(
            200,
            ~s(<html><head><link rel="shortcut icon" href="https://cdn.example/icon.png"></head></html>)
          )

        "/icon.png" ->
          conn
          |> Plug.Conn.put_resp_content_type("image/png", nil)
          |> Plug.Conn.send_resp(200, @png)
      end
    end)

    assert {:ok, %{body: @png}} = Favicons.fetch("cdnsite.example", cache_dir: dir)
  end

  test "a data: icon href is a miss, not a fetch", %{dir: dir} do
    Req.Test.stub(BusterClaw.FaviconHTTP, fn conn ->
      case conn.request_path do
        "/favicon.ico" ->
          Plug.Conn.send_resp(conn, 404, "")

        "/" ->
          conn
          |> Plug.Conn.put_resp_content_type("text/html")
          |> Plug.Conn.send_resp(
            200,
            ~s(<html><head><link rel="icon" href="data:image/png;base64,AAAA"></head></html>)
          )
      end
    end)

    assert :error = Favicons.fetch("datauri.example", cache_dir: dir)
  end

  test "caches misses so a host is not re-fetched within the TTL", %{dir: dir} do
    Req.Test.stub(BusterClaw.FaviconHTTP, fn conn -> Plug.Conn.send_resp(conn, 404, "") end)
    assert :error = Favicons.fetch("nofavicon.com", cache_dir: dir)

    stub_icon()
    assert :error = Favicons.fetch("nofavicon.com", cache_dir: dir)
    # Expired miss marker → re-fetch succeeds.
    assert {:ok, _} = Favicons.fetch("nofavicon.com", cache_dir: dir, ttl_seconds: 0)
  end

  test "rejects an HTML 200 masquerading as a favicon", %{dir: dir} do
    Req.Test.stub(BusterClaw.FaviconHTTP, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("text/html")
      |> Plug.Conn.send_resp(200, "<html>not found</html>")
    end)

    assert :error = Favicons.fetch("softmiss.com", cache_dir: dir)
  end

  test "rejects hosts that could escape the cache path or the URL", %{dir: dir} do
    for bad <- [
          "",
          "a/b",
          "../up",
          "host name",
          "evil.com/",
          "-lead.com",
          String.duplicate("a", 300)
        ] do
      assert :error = Favicons.fetch(bad, cache_dir: dir),
             "expected rejection for #{inspect(bad)}"
    end
  end

  test "refuses hosts the URL guard blocks", %{dir: dir} do
    # Loopback/private hosts must never be fetched, even for icons.
    assert :error = Favicons.fetch("localhost", cache_dir: dir)
    assert :error = Favicons.fetch("127.0.0.1", cache_dir: dir)
  end
end
