defmodule BusterClaw.Google.CalendarSyncTest do
  use BusterClaw.DataCase

  alias BusterClaw.Calendar, as: AppCalendar
  alias BusterClaw.Google
  alias BusterClaw.Google.CalendarSync

  setup do
    Req.Test.verify_on_exit!()
    :ok
  end

  test "one-way sync imports Google Calendar events without touching local events" do
    account = connected_account!()

    {:ok, local_event} =
      AppCalendar.create_event(%{
        event_id: "local-cron-job",
        date: ~D[2026-05-27],
        title: "Cron: daily digest",
        color: "neutral"
      })

    {:ok, stale_google_event} =
      AppCalendar.create_event(%{
        event_id: "google-calendar:#{account.id}:primary:stale-event",
        date: ~D[2026-05-28],
        title: "Old imported event",
        color: "work"
      })

    Req.Test.stub(BusterClaw.GoogleHTTP, fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)

      assert conn.request_path == "/calendar/v3/calendars/primary/events"
      assert conn.query_params["singleEvents"] == "true"
      assert conn.query_params["showDeleted"] == "true"
      assert conn.query_params["orderBy"] == "startTime"
      assert conn.query_params["timeMin"]
      assert conn.query_params["timeMax"]
      refute Map.has_key?(conn.query_params, "syncToken")

      Req.Test.json(conn, %{
        "nextSyncToken" => "sync-token-1",
        "items" => [
          %{
            "id" => "google-event-1",
            "status" => "confirmed",
            "summary" => "Google planning block",
            "description" => "Imported from Google.",
            "location" => "Office",
            "htmlLink" => "https://calendar.google.com/event?eid=google-event-1",
            "start" => %{"dateTime" => "2026-05-27T09:30:00-07:00"},
            "end" => %{"dateTime" => "2026-05-27T10:00:00-07:00"}
          },
          %{
            "id" => "cancelled-event",
            "status" => "cancelled",
            "summary" => "Cancelled",
            "start" => %{"date" => "2026-05-28"},
            "end" => %{"date" => "2026-05-29"}
          }
        ]
      })
    end)

    assert {:ok, result} =
             CalendarSync.sync(account,
               calendar_id: "primary",
               days_ahead: 14,
               req_options: [plug: {Req.Test, BusterClaw.GoogleHTTP}]
             )

    assert result.mode == :full
    assert result.imported == 1
    assert result.created == 1
    assert result.updated == 0
    assert result.deleted == 1
    assert result.sync_token == nil
    assert result.next_sync_token == "sync-token-1"
    assert [%{title: "Google planning block"}] = result.events

    events = AppCalendar.list_events()
    assert Enum.any?(events, &(&1.id == local_event.id))
    refute Enum.any?(events, &(&1.id == stale_google_event.id))

    imported =
      Enum.find(events, &(&1.event_id == "google-calendar:#{account.id}:primary:google-event-1"))

    assert imported.title == "Google planning block"
    assert imported.date == ~D[2026-05-27]
    assert imported.start_time == ~T[09:30:00]
    assert imported.end_time == ~T[10:00:00]
    assert imported.notes =~ "Google Calendar"
    assert imported.notes =~ "Google Event ID: google-event-1"

    assert Google.get_account!(account.id).calendar_sync_tokens == %{"primary" => "sync-token-1"}
  end

  test "incremental sync reuses the stored token and applies only Google deltas" do
    account = connected_account!()

    {:ok, account} =
      Google.update_account(account, %{"calendar_sync_tokens" => %{"primary" => "sync-token-1"}})

    {:ok, existing_event} =
      AppCalendar.create_event(%{
        event_id: "google-calendar:#{account.id}:primary:existing-event",
        date: ~D[2026-05-27],
        title: "Existing imported event",
        color: "work"
      })

    {:ok, cancelled_event} =
      AppCalendar.create_event(%{
        event_id: "google-calendar:#{account.id}:primary:cancelled-event",
        date: ~D[2026-05-28],
        title: "Cancelled imported event",
        color: "work"
      })

    Req.Test.stub(BusterClaw.GoogleHTTP, fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)

      assert conn.request_path == "/calendar/v3/calendars/primary/events"
      assert conn.query_params["singleEvents"] == "true"
      assert conn.query_params["showDeleted"] == "true"
      assert conn.query_params["syncToken"] == "sync-token-1"
      refute Map.has_key?(conn.query_params, "orderBy")
      refute Map.has_key?(conn.query_params, "timeMin")
      refute Map.has_key?(conn.query_params, "timeMax")

      Req.Test.json(conn, %{
        "nextSyncToken" => "sync-token-2",
        "items" => [
          %{
            "id" => "new-event",
            "status" => "confirmed",
            "summary" => "Incremental planning",
            "start" => %{"date" => "2026-05-29"},
            "end" => %{"date" => "2026-05-30"}
          },
          %{
            "id" => "cancelled-event",
            "status" => "cancelled"
          }
        ]
      })
    end)

    assert {:ok, result} =
             CalendarSync.sync(account,
               calendar_id: "primary",
               days_ahead: 14,
               req_options: [plug: {Req.Test, BusterClaw.GoogleHTTP}]
             )

    assert result.mode == :incremental
    assert result.imported == 1
    assert result.created == 1
    assert result.updated == 0
    assert result.deleted == 1
    assert result.sync_token == "sync-token-1"
    assert result.next_sync_token == "sync-token-2"
    assert [%{title: "Incremental planning"}] = result.events

    events = AppCalendar.list_events()
    assert Enum.any?(events, &(&1.id == existing_event.id))
    refute Enum.any?(events, &(&1.id == cancelled_event.id))

    assert Google.get_account!(account.id).calendar_sync_tokens == %{"primary" => "sync-token-2"}
  end

  test "forced full sync ignores the stored token and refreshes token state" do
    account = connected_account!()

    {:ok, account} =
      Google.update_account(account, %{"calendar_sync_tokens" => %{"primary" => "old-token"}})

    Req.Test.stub(BusterClaw.GoogleHTTP, fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)

      assert conn.request_path == "/calendar/v3/calendars/primary/events"
      assert conn.query_params["singleEvents"] == "true"
      assert conn.query_params["showDeleted"] == "true"
      assert conn.query_params["orderBy"] == "startTime"
      assert conn.query_params["timeMin"]
      assert conn.query_params["timeMax"]
      refute Map.has_key?(conn.query_params, "syncToken")

      Req.Test.json(conn, %{"items" => [], "nextSyncToken" => "new-token"})
    end)

    assert {:ok, result} =
             CalendarSync.sync(account,
               calendar_id: "primary",
               force_full?: true,
               req_options: [plug: {Req.Test, BusterClaw.GoogleHTTP}]
             )

    assert result.mode == :full
    assert result.sync_token == nil
    assert result.next_sync_token == "new-token"
    assert Google.get_account!(account.id).calendar_sync_tokens == %{"primary" => "new-token"}
  end

  test "sync follows Google Calendar pagination before storing the next sync token" do
    account = connected_account!()

    Req.Test.stub(BusterClaw.GoogleHTTP, fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)

      assert conn.request_path == "/calendar/v3/calendars/primary/events"
      assert conn.query_params["singleEvents"] == "true"
      assert conn.query_params["showDeleted"] == "true"

      case conn.query_params["pageToken"] do
        nil ->
          Req.Test.json(conn, %{
            "nextPageToken" => "page-2",
            "items" => [
              %{
                "id" => "page-1-event",
                "status" => "confirmed",
                "summary" => "First page",
                "start" => %{"date" => "2026-05-29"},
                "end" => %{"date" => "2026-05-30"}
              }
            ]
          })

        "page-2" ->
          Req.Test.json(conn, %{
            "nextSyncToken" => "sync-token-after-pages",
            "items" => [
              %{
                "id" => "page-2-event",
                "status" => "confirmed",
                "summary" => "Second page",
                "start" => %{"date" => "2026-05-30"},
                "end" => %{"date" => "2026-05-31"}
              }
            ]
          })
      end
    end)

    assert {:ok, result} =
             CalendarSync.sync(account,
               calendar_id: "primary",
               req_options: [plug: {Req.Test, BusterClaw.GoogleHTTP}]
             )

    assert result.pages == 2
    assert result.imported == 2
    assert result.next_sync_token == "sync-token-after-pages"
    assert Enum.map(result.events, & &1.title) == ["First page", "Second page"]

    assert Google.get_account!(account.id).calendar_sync_tokens == %{
             "primary" => "sync-token-after-pages"
           }
  end

  test "invalid incremental sync token is cleared and reports full sync fallback requirement" do
    account = connected_account!()

    {:ok, account} =
      Google.update_account(account, %{"calendar_sync_tokens" => %{"primary" => "expired-token"}})

    {:ok, existing_event} =
      AppCalendar.create_event(%{
        event_id: "google-calendar:#{account.id}:primary:existing-event",
        date: ~D[2026-05-27],
        title: "Existing imported event",
        color: "work"
      })

    Req.Test.stub(BusterClaw.GoogleHTTP, fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)

      assert conn.request_path == "/calendar/v3/calendars/primary/events"
      assert conn.query_params["syncToken"] == "expired-token"

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(
        410,
        Jason.encode!(%{"error" => %{"message" => "Sync token is no longer valid"}})
      )
    end)

    assert {:error, {:calendar_sync_token_invalid, info}} =
             CalendarSync.sync(account,
               calendar_id: "primary",
               req_options: [plug: {Req.Test, BusterClaw.GoogleHTTP}]
             )

    assert info.account_id == account.id
    assert info.calendar_id == "primary"
    assert info.status == 410
    assert info.reason == "Sync token is no longer valid"
    assert info.full_sync_required == true

    assert Google.get_account!(account.id).calendar_sync_tokens == %{}
    assert AppCalendar.get_event_by_event_id(existing_event.event_id)
  end

  defp connected_account! do
    {:ok, account} =
      Google.create_account(%{
        "email" => "me@example.com",
        "client_id" => "client-id",
        "client_secret" => "client-secret",
        "refresh_token" => "refresh-token",
        "access_token" => "access-token",
        "access_token_expires_at" => DateTime.utc_now() |> DateTime.add(3600, :second),
        "scopes" => "https://www.googleapis.com/auth/calendar.events.readonly"
      })

    account
  end
end
