defmodule BusterClawWeb.PhoneGreetingTest do
  use BusterClawWeb.ConnCase
  import Phoenix.LiveViewTest

  setup do
    previous = Application.get_env(:buster_claw, :greeting_req_options)
    Application.put_env(:buster_claw, :greeting_req_options, plug: {Req.Test, __MODULE__})
    Req.Test.verify_on_exit!()

    on_exit(fn ->
      if previous,
        do: Application.put_env(:buster_claw, :greeting_req_options, previous),
        else: Application.delete_env(:buster_claw, :greeting_req_options)
    end)

    :ok
  end

  defp open_greeting(conn) do
    {:ok, view, _} = live(conn, "/phone")
    Req.Test.allow(__MODULE__, self(), view.pid)
    view |> element("button[role=tab][phx-value-tab=greeting]") |> render_click()
    view
  end

  defp request(method, status) do
    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.method == method
      assert conn.request_path == "/storage/v1/object/recordings/greeting/greeting.wav"
      Plug.Conn.send_resp(conn, status, "")
    end)
  end

  defp check(view) do
    view |> element("#phone-greeting-check") |> render_click()
    render_async(view)
  end

  test "opening Phone leaves the published greeting untouched until an explicit check and reset",
       %{conn: conn} do
    view = open_greeting(conn)
    assert has_element?(view, "#phone-greeting[data-status=unchecked]")
    refute has_element?(view, "#phone-greeting-reset")

    request("HEAD", 200)
    check(view)
    assert has_element?(view, "#phone-greeting[data-status=published]")
    assert has_element?(view, "#phone-greeting-reset[data-claw-confirm]")

    request("DELETE", 200)
    view |> element("#phone-greeting-reset") |> render_click()
    render_async(view)
    assert has_element?(view, "#phone-greeting[data-status=default]")
    refute has_element?(view, "#phone-greeting-reset")
  end

  test "absent audio shows the default greeting without a reset action", %{conn: conn} do
    view = open_greeting(conn)
    request("HEAD", 404)
    check(view)
    assert has_element?(view, "#phone-greeting[data-status=default]")
    refute has_element?(view, "#phone-greeting-reset")
  end

  test "unavailable status is recoverable and never appears as the default", %{conn: conn} do
    view = open_greeting(conn)
    request("HEAD", 503)
    check(view)
    assert has_element?(view, "#phone-greeting[data-status=unavailable]")
    assert has_element?(view, "#phone-greeting-error")
    refute has_element?(view, "#phone-greeting-reset")

    request("HEAD", 200)
    check(view)
    assert has_element?(view, "#phone-greeting[data-status=published]")
    refute has_element?(view, "#phone-greeting-error")
  end

  test "failed reset requires a fresh status check and does not claim the audio is gone", %{
    conn: conn
  } do
    view = open_greeting(conn)
    request("HEAD", 200)
    check(view)

    request("DELETE", 403)
    view |> element("#phone-greeting-reset") |> render_click()
    render_async(view)
    assert has_element?(view, "#phone-greeting[data-status=unavailable]")
    assert has_element?(view, "#phone-greeting-error")
    refute has_element?(view, "#phone-greeting-reset")
  end
end
