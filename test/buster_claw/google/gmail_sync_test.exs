defmodule BusterClaw.Google.GmailSyncTest do
  use BusterClaw.DataCase

  alias BusterClaw.Google
  alias BusterClaw.Google.GmailSync
  alias BusterClaw.Library

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "buster-claw-gmail-sync-test-#{System.unique_integer([:positive])}"
      )

    previous = Application.get_env(:buster_claw, :library_root)
    Application.put_env(:buster_claw, :library_root, root)

    Req.Test.verify_on_exit!()

    on_exit(fn ->
      Application.put_env(:buster_claw, :library_root, previous)
      File.rm_rf(root)
    end)

    :ok
  end

  test "syncs Gmail messages into stable Library raw documents" do
    Req.Test.stub(BusterClaw.GoogleHTTP, fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)

      case {conn.request_path, conn.query_params["format"]} do
        {"/gmail/v1/users/me/messages", _format} ->
          assert conn.query_params["q"] == "in:inbox"
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

    account = connected_account!()

    assert {:ok, result} =
             GmailSync.sync(account,
               query: "in:inbox",
               limit: 1,
               req_options: [plug: {Req.Test, BusterClaw.GoogleHTTP}]
             )

    assert result.synced == 1
    assert result.errors == []
    assert result.account.last_synced_at
    assert result.account.last_seen_history_id == "history-1"

    assert [document] = result.documents
    assert document.artifact_path == "raw/2026-05-27/gmail-msg-1.md"
    assert document.source_url == "gmail://me%40example.com/messages/msg-1"
    assert document.tags == %{"items" => ["gmail", "google-workspace", "INBOX"]}

    assert {:ok, markdown} = Library.read_raw_document(document)
    assert markdown =~ "# Launch notes"
    assert markdown =~ "- From: Ada <ada@example.com>"
    assert markdown =~ "Hello from Gmail."

    assert {:ok, second_result} =
             GmailSync.sync(account,
               query: "in:inbox",
               limit: 1,
               req_options: [plug: {Req.Test, BusterClaw.GoogleHTTP}]
             )

    assert [%{id: same_id}] = second_result.documents
    assert same_id == document.id
    assert [_one_document] = Library.list_documents()
  end

  test "incremental sync imports changed messages from Gmail history" do
    Req.Test.stub(BusterClaw.GoogleHTTP, fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)

      case {conn.request_path, conn.query_params["pageToken"], conn.query_params["format"]} do
        {"/gmail/v1/users/me/history", nil, _format} ->
          assert conn.query_params["startHistoryId"] == "history-start"
          assert conn.query_params["maxResults"] == "100"

          Req.Test.json(conn, %{
            "historyId" => "history-mid",
            "nextPageToken" => "next-page",
            "history" => []
          })

        {"/gmail/v1/users/me/history", "next-page", _format} ->
          assert conn.query_params["startHistoryId"] == "history-start"
          assert conn.query_params["maxResults"] == "100"

          Req.Test.json(conn, %{
            "historyId" => "history-new",
            "history" => [
              %{
                "id" => "history-event-1",
                "messagesAdded" => [
                  %{"message" => %{"id" => "msg-2", "threadId" => "thread-2"}}
                ]
              },
              %{
                "id" => "history-event-2",
                "labelsAdded" => [
                  %{"message" => %{"id" => "msg-2", "threadId" => "thread-2"}}
                ]
              },
              %{
                "id" => "history-event-3",
                "messagesDeleted" => [
                  %{"message" => %{"id" => "msg-deleted", "threadId" => "thread-deleted"}}
                ]
              }
            ]
          })

        {"/gmail/v1/users/me/messages/msg-2", nil, "full"} ->
          Req.Test.json(
            conn,
            full_message(%{
              "id" => "msg-2",
              "threadId" => "thread-2",
              "historyId" => "history-message-2",
              "subject" => "Incremental notes",
              "body" => "Pulled from Gmail history."
            })
          )
      end
    end)

    account = connected_account!(%{"last_seen_history_id" => "history-start"})

    assert {:ok, result} =
             GmailSync.sync_incremental(account,
               req_options: [plug: {Req.Test, BusterClaw.GoogleHTTP}]
             )

    assert result.mode == :incremental
    assert result.full_sync_required == false
    assert result.full_sync_reason == nil
    assert result.start_history_id == "history-start"
    assert result.history_id == "history-new"
    assert result.requested == 1
    assert result.synced == 1
    assert result.errors == []
    assert result.deleted_message_ids == ["msg-deleted"]
    assert result.history_records == 3
    assert result.account.last_seen_history_id == "history-new"

    assert [document] = result.documents
    assert document.artifact_path == "raw/2026-05-27/gmail-msg-2.md"

    assert {:ok, markdown} = Library.read_raw_document(document)
    assert markdown =~ "# Incremental notes"
    assert markdown =~ "Pulled from Gmail history."
  end

  test "incremental sync reports when Gmail history is too old for a delta pull" do
    Req.Test.stub(BusterClaw.GoogleHTTP, fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)

      assert conn.request_path == "/gmail/v1/users/me/history"
      assert conn.query_params["startHistoryId"] == "expired-history"

      conn
      |> Plug.Conn.put_status(:not_found)
      |> Req.Test.json(%{
        "error" => %{
          "code" => 404,
          "message" => "Requested entity was not found.",
          "status" => "NOT_FOUND"
        }
      })
    end)

    account = connected_account!(%{"last_seen_history_id" => "expired-history"})

    assert {:ok, result} =
             GmailSync.sync_incremental(account,
               req_options: [plug: {Req.Test, BusterClaw.GoogleHTTP}]
             )

    assert result.mode == :incremental
    assert result.full_sync_required == true
    assert result.full_sync_reason == :history_id_too_old
    assert result.start_history_id == "expired-history"
    assert result.synced == 0
    assert result.documents == []
    assert result.errors == []
    assert result.account.last_seen_history_id == "expired-history"
  end

  defp connected_account!(attrs \\ %{}) do
    {:ok, account} =
      %{
        "email" => "me@example.com",
        "client_id" => "client-id",
        "client_secret" => "client-secret",
        "refresh_token" => "refresh-token",
        "access_token" => "access-token",
        "access_token_expires_at" => DateTime.utc_now() |> DateTime.add(3600, :second),
        "default_query" => "newer_than:7d"
      }
      |> Map.merge(attrs)
      |> Google.create_account()

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

  defp full_message(attrs) do
    %{
      "id" => Map.fetch!(attrs, "id"),
      "threadId" => Map.fetch!(attrs, "threadId"),
      "historyId" => Map.fetch!(attrs, "historyId"),
      "internalDate" => internal_date_ms(),
      "snippet" => "Please review.",
      "labelIds" => Map.get(attrs, "labelIds", ["INBOX"]),
      "payload" => %{
        "headers" => [
          %{"name" => "Subject", "value" => Map.fetch!(attrs, "subject")},
          %{"name" => "From", "value" => "Ada <ada@example.com>"},
          %{"name" => "To", "value" => "Luke <luke@example.com>"},
          %{"name" => "Date", "value" => "Wed, 27 May 2026 09:00:00 -0700"}
        ],
        "mimeType" => "multipart/alternative",
        "parts" => [
          %{
            "mimeType" => "text/plain",
            "body" => %{
              "data" => Base.url_encode64(Map.fetch!(attrs, "body"), padding: false)
            }
          }
        ]
      }
    }
  end

  defp internal_date_ms do
    ~U[2026-05-27 16:00:00Z]
    |> DateTime.to_unix(:millisecond)
    |> Integer.to_string()
  end
end
