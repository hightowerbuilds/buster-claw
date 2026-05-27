defmodule BusterClaw.Google.GmailTest do
  use BusterClaw.DataCase

  alias BusterClaw.Google
  alias BusterClaw.Google.Gmail

  setup do
    Req.Test.verify_on_exit!()
    :ok
  end

  test "lists Gmail labels" do
    Req.Test.stub(BusterClaw.GoogleHTTP, fn conn ->
      assert {"authorization", "Bearer access-token"} =
               List.keyfind(conn.req_headers, "authorization", 0)

      assert conn.request_path == "/gmail/v1/users/me/labels"

      Req.Test.json(conn, %{
        "labels" => [
          %{"id" => "INBOX", "name" => "INBOX", "type" => "system"},
          %{"id" => "Label_1", "name" => "Clients", "type" => "user"}
        ]
      })
    end)

    account = connected_account!()

    assert {:ok,
            [
              %{id: "INBOX", name: "INBOX", type: "system"},
              %{id: "Label_1", name: "Clients", type: "user"}
            ]} =
             Gmail.labels(account, req_options: [plug: {Req.Test, BusterClaw.GoogleHTTP}])
  end

  test "searches Gmail and returns message summaries" do
    Req.Test.stub(BusterClaw.GoogleHTTP, fn conn ->
      assert {"authorization", "Bearer access-token"} =
               List.keyfind(conn.req_headers, "authorization", 0)

      conn = Plug.Conn.fetch_query_params(conn)

      case conn.request_path do
        "/gmail/v1/users/me/messages" ->
          assert conn.query_params["q"] == "from:ada"
          assert conn.query_params["maxResults"] == "1"

          Req.Test.json(conn, %{
            "resultSizeEstimate" => 1,
            "messages" => [%{"id" => "msg-1", "threadId" => "thread-1"}]
          })

        "/gmail/v1/users/me/messages/msg-1" ->
          Req.Test.json(conn, metadata_message())
      end
    end)

    account = connected_account!()

    assert {:ok, %{messages: [message], result_size_estimate: 1}} =
             Gmail.search(account, "from:ada",
               limit: 1,
               req_options: [plug: {Req.Test, BusterClaw.GoogleHTTP}]
             )

    assert message.id == "msg-1"
    assert message.subject == "Launch notes"
    assert message.from == "Ada <ada@example.com>"
    assert message.snippet == "Please review."
  end

  test "reads and parses a Gmail message body" do
    Req.Test.stub(BusterClaw.GoogleHTTP, fn conn ->
      assert conn.request_path == "/gmail/v1/users/me/messages/msg-1"
      Req.Test.json(conn, full_message())
    end)

    account = connected_account!()

    assert {:ok, message} =
             Gmail.read(account, "msg-1", req_options: [plug: {Req.Test, BusterClaw.GoogleHTTP}])

    assert message.id == "msg-1"
    assert message.subject == "Launch notes"
    assert message.to == "Luke <luke@example.com>"
    assert message.body_text == "Hello from Gmail."
    assert message.label_ids == ["INBOX"]
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

  defp metadata_message do
    %{
      "id" => "msg-1",
      "threadId" => "thread-1",
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
end
