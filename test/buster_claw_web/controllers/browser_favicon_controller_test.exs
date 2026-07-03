defmodule BusterClawWeb.BrowserFaviconControllerTest do
  # async: false — the Favicons disk cache dir is shared app config.
  use BusterClawWeb.ConnCase, async: false

  setup do
    Req.Test.verify_on_exit!()
    # Isolate this test's cache from other suites (config points at one tmp dir).
    dir = Application.get_env(:buster_claw, :favicons)[:cache_dir]
    File.rm_rf(dir)
    :ok
  end

  test "serves a fetched favicon with cache headers", %{conn: conn} do
    Req.Test.stub(BusterClaw.FaviconHTTP, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("image/png", nil)
      |> Plug.Conn.send_resp(200, "png-bytes")
    end)

    conn = get(conn, ~p"/browser/favicon?host=ctrl-example.com")

    assert response(conn, 200) == "png-bytes"
    assert response_content_type(conn, :png) =~ "image/png"
    assert ["public, max-age=604800"] = get_resp_header(conn, "cache-control")
  end

  test "404s (cacheably) when the site has no favicon", %{conn: conn} do
    Req.Test.stub(BusterClaw.FaviconHTTP, fn conn -> Plug.Conn.send_resp(conn, 404, "") end)

    conn = get(conn, ~p"/browser/favicon?host=ctrl-nofav.com")

    assert response(conn, 404)
    assert ["public, max-age=86400"] = get_resp_header(conn, "cache-control")
  end

  test "400s without a host", %{conn: conn} do
    assert conn |> get(~p"/browser/favicon") |> response(400)
  end
end
