defmodule BusterClawWeb.GWSLiveTest do
  use BusterClawWeb.ConnCase

  import Phoenix.LiveViewTest

  alias BusterClaw.Google
  alias BusterClaw.Library

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "buster-claw-gws-live-test-#{System.unique_integer([:positive])}"
      )

    previous_google_req = Application.get_env(:buster_claw, :google_req_options)
    previous_library_root = Application.get_env(:buster_claw, :library_root)

    Application.put_env(:buster_claw, :google_req_options,
      plug: {Req.Test, BusterClaw.GoogleHTTP}
    )

    Application.put_env(:buster_claw, :library_root, root)

    Req.Test.verify_on_exit!()

    on_exit(fn ->
      if previous_google_req do
        Application.put_env(:buster_claw, :google_req_options, previous_google_req)
      else
        Application.delete_env(:buster_claw, :google_req_options)
      end

      if previous_library_root do
        Application.put_env(:buster_claw, :library_root, previous_library_root)
      else
        Application.delete_env(:buster_claw, :library_root)
      end

      File.rm_rf(root)
    end)

    :ok
  end

  test "renders empty GWS state", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/gws")

    assert html =~ "GWS"
    assert html =~ ~s(id="gws-accounts")
    assert html =~ "No Google Workspace accounts connected yet"
  end

  test "lists, reconnects, toggles, and deletes Google accounts", %{conn: conn} do
    {:ok, account} =
      Google.create_account(%{
        "email" => "me@example.com",
        "client_id" => "client-id",
        "client_secret" => "client-secret",
        "refresh_token" => "refresh-token",
        "scopes" => "https://www.googleapis.com/auth/gmail.readonly"
      })

    {:ok, view, html} = live(conn, ~p"/gws")
    assert html =~ "me@example.com"
    assert html =~ "authorized"

    html =
      view
      |> element("button[phx-click='reconnect'][phx-value-id='#{account.id}']")
      |> render_click()

    assert html =~ ~s(id="gws-oauth-link")
    assert html =~ "accounts.google.com"

    html =
      view
      |> element("button[phx-click='toggle'][phx-value-id='#{account.id}']")
      |> render_click()

    assert html =~ "disabled"
    refute Google.get_account!(account.id).enabled

    html =
      view
      |> element("button[phx-click='delete_account'][phx-value-id='#{account.id}']")
      |> render_click()

    assert html =~ "No Google Workspace accounts connected yet"
    assert [] = Google.list_accounts()
  end

  test "loads Gmail labels, searches messages, and reads a selected message", %{conn: conn} do
    account = connected_account!()

    Req.Test.stub(BusterClaw.GoogleHTTP, fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)

      case {conn.request_path, conn.query_params["format"]} do
        {"/gmail/v1/users/me/labels", _format} ->
          Req.Test.json(conn, %{
            "labels" => [
              %{"id" => "INBOX", "name" => "INBOX", "type" => "system"},
              %{"id" => "Label_1", "name" => "Clients", "type" => "user"}
            ]
          })

        {"/gmail/v1/users/me/messages", _format} ->
          assert conn.query_params["q"] == "newer_than:7d"
          assert conn.query_params["maxResults"] == "1"

          Req.Test.json(conn, %{
            "resultSizeEstimate" => 1,
            "messages" => [%{"id" => "msg-1", "threadId" => "thread-1"}]
          })

        {"/gmail/v1/users/me/messages/msg-1", "metadata"} ->
          Req.Test.json(conn, metadata_message())

        {"/gmail/v1/users/me/messages/msg-1", "full"} ->
          Req.Test.json(conn, full_message())
      end
    end)

    {:ok, view, html} = live(conn, ~p"/gws")
    Req.Test.allow(BusterClaw.GoogleHTTP, self(), view.pid)

    assert html =~ ~s(id="gmail-tools")

    html =
      view
      |> form("#gmail-label-form", gmail: %{account_id: account.id})
      |> render_submit()

    assert html =~ ~s(id="gmail-labels")
    assert html =~ "INBOX"
    assert html =~ "Clients"

    html =
      view
      |> form("#gmail-search-form",
        gmail: %{account_id: account.id, query: "newer_than:7d", limit: "1"}
      )
      |> render_submit()

    assert html =~ ~s(id="gmail-message-msg-1")
    assert html =~ "Launch notes"
    assert html =~ "Please review."

    html =
      view
      |> element("button[phx-click='read_gmail_message'][phx-value-id='msg-1']")
      |> render_click()

    assert html =~ ~s(id="gmail-selected-message")
    assert html =~ "Hello from Gmail."

    html =
      view
      |> form("#gmail-sync-form",
        gmail: %{account_id: account.id, query: "newer_than:7d", limit: "1"}
      )
      |> render_submit()

    assert html =~ ~s(id="gmail-sync-results")
    assert html =~ "Synced 1 Gmail messages into Library."
    assert html =~ "raw/2026-05-27/gmail-msg-1.md"

    assert [document] = Library.list_documents()
    assert {:ok, markdown} = Library.read_raw_document(document)
    assert markdown =~ "Hello from Gmail."
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
        "scopes" => "https://www.googleapis.com/auth/gmail.readonly"
      })

    account
  end

  defp metadata_message do
    %{
      "id" => "msg-1",
      "threadId" => "thread-1",
      "historyId" => "history-1",
      "internalDate" => internal_date_ms(),
      "snippet" => "Please review.",
      "labelIds" => ["INBOX"],
      "payload" => %{
        "headers" => [
          %{"name" => "Subject", "value" => "Launch notes"},
          %{"name" => "From", "value" => "Ada <ada@example.com>"},
          %{"name" => "Date", "value" => "Wed, 27 May 2026 09:00:00 -0700"}
        ]
      }
    }
  end

  defp full_message do
    metadata_message()
    |> put_in(["payload", "headers"], [
      %{"name" => "Subject", "value" => "Launch notes"},
      %{"name" => "From", "value" => "Ada <ada@example.com>"},
      %{"name" => "To", "value" => "Luke <luke@example.com>"},
      %{"name" => "Date", "value" => "Wed, 27 May 2026 09:00:00 -0700"}
    ])
    |> put_in(["payload", "mimeType"], "multipart/alternative")
    |> put_in(["payload", "parts"], [
      %{
        "mimeType" => "text/plain",
        "body" => %{"data" => Base.url_encode64("Hello from Gmail.", padding: false)}
      }
    ])
  end

  defp internal_date_ms do
    ~U[2026-05-27 16:00:00Z]
    |> DateTime.to_unix(:millisecond)
    |> Integer.to_string()
  end
end
