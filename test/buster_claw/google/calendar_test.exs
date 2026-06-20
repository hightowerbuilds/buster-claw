defmodule BusterClaw.Google.CalendarTest do
  use BusterClaw.DataCase, async: true

  alias BusterClaw.Google
  alias BusterClaw.Google.Calendar

  setup do
    Req.Test.verify_on_exit!()
    :ok
  end

  test "create_event inserts an event on the given calendar" do
    Req.Test.stub(BusterClaw.GoogleHTTP, fn conn ->
      assert conn.method == "POST"
      assert conn.request_path == "/calendar/v3/calendars/primary/events"

      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert Jason.decode!(body)["summary"] == "Launch sync"

      Req.Test.json(conn, %{"id" => "evt-1", "summary" => "Launch sync", "status" => "confirmed"})
    end)

    assert {:ok, summary} =
             Calendar.create_event(
               connected_account!(),
               "primary",
               %{"summary" => "Launch sync"},
               req_options: [plug: {Req.Test, BusterClaw.GoogleHTTP}]
             )

    assert summary.id == "evt-1"
    assert summary.summary == "Launch sync"
  end

  test "update_event patches an existing event" do
    Req.Test.stub(BusterClaw.GoogleHTTP, fn conn ->
      assert conn.method == "PATCH"
      assert conn.request_path == "/calendar/v3/calendars/primary/events/evt-1"

      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert Jason.decode!(body)["location"] == "Room 4"

      Req.Test.json(conn, %{"id" => "evt-1", "location" => "Room 4"})
    end)

    assert {:ok, summary} =
             Calendar.update_event(
               connected_account!(),
               "primary",
               "evt-1",
               %{"location" => "Room 4"},
               req_options: [plug: {Req.Test, BusterClaw.GoogleHTTP}]
             )

    assert summary.id == "evt-1"
    assert summary.location == "Room 4"
  end

  test "delete_event removes an event" do
    Req.Test.stub(BusterClaw.GoogleHTTP, fn conn ->
      assert conn.method == "DELETE"
      assert conn.request_path == "/calendar/v3/calendars/work%40example.com/events/evt-1"
      Plug.Conn.send_resp(conn, 204, "")
    end)

    assert {:ok, %{id: "evt-1", calendar_id: "work@example.com", deleted: true}} =
             Calendar.delete_event(
               connected_account!(),
               "work@example.com",
               "evt-1",
               req_options: [plug: {Req.Test, BusterClaw.GoogleHTTP}]
             )
  end

  defp connected_account! do
    {:ok, account} =
      Google.create_account(%{
        "email" => "me@example.com",
        "client_id" => "client-id",
        "client_secret" => "client-secret",
        "refresh_token" => "refresh-token",
        "access_token" => "access-token",
        "access_token_expires_at" => DateTime.utc_now() |> DateTime.add(3600, :second)
      })

    account
  end
end
