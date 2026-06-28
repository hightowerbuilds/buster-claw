defmodule BusterClawWeb.BrowserCommandControllerTest do
  use BusterClawWeb.ConnCase, async: false

  alias BusterClaw.Browser.Bridge

  test "POST /browser/command fulfils a current request with url + title", %{conn: conn} do
    Bridge.subscribe()
    task = Task.async(fn -> Bridge.request(:current) end)
    assert_receive {:browser_command, ref, :current, _payload}, 1_000

    conn =
      post(conn, ~p"/browser/command", %{
        "ref" => ref,
        "ok" => true,
        "url" => "https://example.com/page",
        "title" => "Example Domain"
      })

    assert conn.status == 204
    assert {:ok, %{url: "https://example.com/page", title: "Example Domain"}} = Task.await(task)
  end

  test "POST /browser/command fulfils a trigger request with ok", %{conn: conn} do
    Bridge.subscribe()
    task = Task.async(fn -> Bridge.request(:navigate, %{"url" => "https://example.com"}) end)
    assert_receive {:browser_command, ref, :navigate, _payload}, 1_000

    conn = post(conn, ~p"/browser/command", %{"ref" => ref, "ok" => true})
    assert conn.status == 204
    assert {:ok, result} = Task.await(task)
    assert result == %{}
  end

  test "POST with an error fulfils the request with that error", %{conn: conn} do
    Bridge.subscribe()
    task = Task.async(fn -> Bridge.request(:open_tab, %{"url" => "https://example.com"}) end)
    assert_receive {:browser_command, ref, :open_tab, _payload}, 1_000

    conn = post(conn, ~p"/browser/command", %{"ref" => ref, "error" => "no browser surface open"})
    assert conn.status == 204
    assert {:error, {:browser_failed, "no browser surface open"}} = Task.await(task)
  end

  test "POST with no ref is a 400", %{conn: conn} do
    conn = post(conn, ~p"/browser/command", %{"ok" => true})
    assert conn.status == 400
  end
end
