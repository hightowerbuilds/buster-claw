defmodule BusterClawWeb.BrowserDownloadControllerTest do
  use BusterClawWeb.ConnCase, async: true

  test "records a finished download on the Sentinel feed", %{conn: conn} do
    conn =
      post(
        conn,
        ~p"/browser/download?url=https://example.com/report.pdf&file=/Users/x/Downloads/report.pdf&success=true"
      )

    assert response(conn, 204)

    assert [event | _] = BusterClaw.Sentinel.list_events(limit: 1)
    assert event.category == "untrusted_ingest"
    assert event.message =~ "Downloaded: https://example.com/report.pdf"
    assert event.metadata["file"] == "/Users/x/Downloads/report.pdf"
    assert event.metadata["success"] == true
  end

  test "marks failures distinctly", %{conn: conn} do
    conn = post(conn, ~p"/browser/download?url=https://example.com/x.zip&success=false")
    assert response(conn, 204)

    assert [event | _] = BusterClaw.Sentinel.list_events(limit: 1)
    assert event.message =~ "Download failed: https://example.com/x.zip"
  end

  test "400s without a url", %{conn: conn} do
    assert conn |> post(~p"/browser/download") |> response(400)
  end
end
