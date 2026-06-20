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

  test "fetches summaries concurrently and preserves result order" do
    Req.Test.stub(BusterClaw.GoogleHTTP, fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)

      case conn.request_path do
        "/gmail/v1/users/me/messages" ->
          assert conn.query_params["maxResults"] == "3"

          Req.Test.json(conn, %{
            "resultSizeEstimate" => 3,
            "messages" => [
              %{"id" => "msg-1"},
              %{"id" => "msg-2"},
              %{"id" => "msg-3"}
            ]
          })

        "/gmail/v1/users/me/messages/" <> id ->
          Req.Test.json(
            conn,
            metadata_message()
            |> Map.put("id", id)
            |> put_in(["payload", "headers"], [
              %{"name" => "Subject", "value" => "Subject #{id}"},
              %{"name" => "From", "value" => "#{id}@example.com"},
              %{"name" => "Date", "value" => "Wed, 27 May 2026 09:00:00 -0700"}
            ])
          )
      end
    end)

    account = connected_account!()

    assert {:ok, %{messages: messages, result_size_estimate: 3}} =
             Gmail.search(account, "from:ada",
               limit: 3,
               req_options: [plug: {Req.Test, BusterClaw.GoogleHTTP}]
             )

    assert Enum.map(messages, & &1.id) == ["msg-1", "msg-2", "msg-3"]
    assert Enum.map(messages, & &1.subject) == ["Subject msg-1", "Subject msg-2", "Subject msg-3"]
  end

  test "list_ids returns message ids without per-message metadata fetches" do
    Req.Test.stub(BusterClaw.GoogleHTTP, fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)

      assert conn.request_path == "/gmail/v1/users/me/messages"
      assert conn.query_params["q"] == "in:inbox"
      assert conn.query_params["maxResults"] == "2"

      Req.Test.json(conn, %{
        "resultSizeEstimate" => 2,
        "nextPageToken" => "next-1",
        "messages" => [%{"id" => "msg-1"}, %{"id" => "msg-2"}]
      })
    end)

    account = connected_account!()

    assert {:ok,
            %{message_ids: ["msg-1", "msg-2"], result_size_estimate: 2, next_page_token: "next-1"}} =
             Gmail.list_ids(account, "in:inbox",
               limit: 2,
               req_options: [plug: {Req.Test, BusterClaw.GoogleHTTP}]
             )
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
    assert message.message_id_header == "<original-abc@mail.example.com>"
  end

  test "creates a Gmail draft with a plain text MIME payload" do
    Req.Test.stub(BusterClaw.GoogleHTTP, fn conn ->
      assert conn.method == "POST"
      assert conn.request_path == "/gmail/v1/users/me/drafts"

      {:ok, body, conn} = Plug.Conn.read_body(conn)
      payload = Jason.decode!(body)
      raw = payload |> get_in(["message", "raw"]) |> decode_base64url!()

      assert raw =~ "To: Ada <ada@example.com>\r\n"
      assert raw =~ "Cc: Team <team@example.com>\r\n"
      assert raw =~ "Subject: Hello Bcc: hidden@example.com\r\n"
      refute raw =~ "\r\nBcc: hidden@example.com"
      assert raw =~ "\r\n\r\nLine one\nLine two"

      Req.Test.json(conn, %{
        "id" => "draft-1",
        "message" => %{"id" => "msg-1", "threadId" => "thread-1"}
      })
    end)

    account = connected_account!()

    assert {:ok, draft} =
             Gmail.create_draft(
               account,
               %{
                 to: "Ada <ada@example.com>",
                 cc: "Team <team@example.com>",
                 subject: "Hello\r\nBcc: hidden@example.com",
                 body: "Line one\nLine two"
               },
               req_options: [plug: {Req.Test, BusterClaw.GoogleHTTP}]
             )

    assert draft.id == "draft-1"
    assert draft.message_id == "msg-1"
    assert draft.thread_id == "thread-1"
  end

  test "validates required Gmail draft fields before calling Google" do
    account = connected_account!()

    assert {:error, :missing_recipient} =
             Gmail.create_draft(account, %{subject: "Hello", body: "Hi"})

    assert {:error, :missing_subject} =
             Gmail.create_draft(account, %{to: "ada@example.com", body: "Hi"})

    assert {:error, :missing_body} =
             Gmail.create_draft(account, %{to: "ada@example.com", subject: "Hello"})
  end

  test "sends a Gmail message with a plain text MIME payload" do
    Req.Test.stub(BusterClaw.GoogleHTTP, fn conn ->
      assert conn.method == "POST"
      assert conn.request_path == "/gmail/v1/users/me/messages/send"

      {:ok, body, conn} = Plug.Conn.read_body(conn)
      payload = Jason.decode!(body)
      raw = payload |> Map.fetch!("raw") |> decode_base64url!()

      assert raw =~ "To: Ada <ada@example.com>\r\n"
      assert raw =~ "Subject: Sent from Buster Claw\r\n"
      assert raw =~ "\r\n\r\nSend body."

      Req.Test.json(conn, %{
        "id" => "msg-sent-1",
        "threadId" => "thread-sent-1",
        "labelIds" => ["SENT"]
      })
    end)

    account = connected_account!()

    assert {:ok, message} =
             Gmail.send_message(
               account,
               %{
                 to: "Ada <ada@example.com>",
                 subject: "Sent from Buster Claw",
                 body: "Send body."
               },
               req_options: [plug: {Req.Test, BusterClaw.GoogleHTTP}]
             )

    assert message.id == "msg-sent-1"
    assert message.thread_id == "thread-sent-1"
    assert message.label_ids == ["SENT"]
  end

  test "sends a threaded reply with In-Reply-To / References headers and threadId" do
    Req.Test.stub(BusterClaw.GoogleHTTP, fn conn ->
      assert conn.request_path == "/gmail/v1/users/me/messages/send"

      {:ok, body, conn} = Plug.Conn.read_body(conn)
      payload = Jason.decode!(body)
      raw = payload |> Map.fetch!("raw") |> decode_base64url!()

      assert payload["threadId"] == "thread-1"
      assert raw =~ "In-Reply-To: <original-abc@mail.example.com>\r\n"
      assert raw =~ "References: <original-abc@mail.example.com>\r\n"
      assert raw =~ "Subject: Re: Launch notes\r\n"
      assert raw =~ "\r\n\r\nThanks, will do."

      Req.Test.json(conn, %{"id" => "msg-sent-2", "threadId" => "thread-1"})
    end)

    account = connected_account!()

    assert {:ok, message} =
             Gmail.send_message(
               account,
               %{
                 "to" => "Ada <ada@example.com>",
                 "subject" => "Re: Launch notes",
                 "body" => "Thanks, will do.",
                 "in_reply_to" => "<original-abc@mail.example.com>",
                 "references" => "<original-abc@mail.example.com>",
                 "thread_id" => "thread-1"
               },
               req_options: [plug: {Req.Test, BusterClaw.GoogleHTTP}]
             )

    assert message.thread_id == "thread-1"
  end

  test "sends a Gmail message with a file attachment as a multipart/mixed payload" do
    path = Path.join(System.tmp_dir!(), "buster-claw-attach-#{System.unique_integer([:positive])}.txt")
    File.write!(path, "attachment contents")
    on_exit(fn -> File.rm(path) end)

    Req.Test.stub(BusterClaw.GoogleHTTP, fn conn ->
      assert conn.request_path == "/gmail/v1/users/me/messages/send"

      {:ok, body, conn} = Plug.Conn.read_body(conn)
      payload = Jason.decode!(body)
      raw = payload |> Map.fetch!("raw") |> decode_base64url!()

      # Top-level is multipart/mixed with a boundary; the text body is the first part.
      assert raw =~ ~r/Content-Type: multipart\/mixed; boundary="(=_bc_[^"]+)"/
      [_, boundary] = Regex.run(~r/boundary="(=_bc_[^"]+)"/, raw)

      assert raw =~ "--#{boundary}\r\n"
      assert raw =~ "--#{boundary}--\r\n"
      assert raw =~ "Content-Type: text/plain; charset=\"UTF-8\"\r\n"
      assert raw =~ "\r\n\r\nSee attached."

      # The attachment part carries the right headers and base64-encoded bytes.
      assert raw =~ ~r/Content-Type: text\/plain; name="[^"]+\.txt"/
      assert raw =~ "Content-Transfer-Encoding: base64\r\n"
      assert raw =~ ~r/Content-Disposition: attachment; filename="[^"]+\.txt"/
      assert raw =~ Base.encode64("attachment contents")

      Req.Test.json(conn, %{"id" => "msg-attach-1", "threadId" => "thread-attach-1"})
    end)

    account = connected_account!()

    assert {:ok, message} =
             Gmail.send_message(
               account,
               %{
                 "to" => "Ada <ada@example.com>",
                 "subject" => "With attachment",
                 "body" => "See attached.",
                 "attachments" => [path]
               },
               req_options: [plug: {Req.Test, BusterClaw.GoogleHTTP}]
             )

    assert message.id == "msg-attach-1"
  end

  test "honors explicit filename and content_type on an attachment spec" do
    path = Path.join(System.tmp_dir!(), "buster-claw-attach-#{System.unique_integer([:positive])}.bin")
    File.write!(path, "%PDF-1.4 fake")
    on_exit(fn -> File.rm(path) end)

    Req.Test.stub(BusterClaw.GoogleHTTP, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      raw = body |> Jason.decode!() |> Map.fetch!("raw") |> decode_base64url!()

      assert raw =~ "Content-Type: application/pdf; name=\"report.pdf\"\r\n"
      assert raw =~ "Content-Disposition: attachment; filename=\"report.pdf\"\r\n"

      Req.Test.json(conn, %{"id" => "msg-attach-2", "threadId" => "thread-attach-2"})
    end)

    account = connected_account!()

    assert {:ok, _message} =
             Gmail.send_message(
               account,
               %{
                 "to" => "Ada <ada@example.com>",
                 "subject" => "Spec attachment",
                 "body" => "See attached.",
                 "attachments" => [
                   %{"path" => path, "filename" => "report.pdf", "content_type" => "application/pdf"}
                 ]
               },
               req_options: [plug: {Req.Test, BusterClaw.GoogleHTTP}]
             )
  end

  test "fails before calling Google when an attachment is unreadable" do
    missing = Path.join(System.tmp_dir!(), "buster-claw-missing-#{System.unique_integer([:positive])}.txt")

    Req.Test.stub(BusterClaw.GoogleHTTP, fn _conn ->
      flunk("Google should not be called when an attachment cannot be read")
    end)

    account = connected_account!()

    assert {:error, {:attachment_unreadable, _abs, :enoent}} =
             Gmail.send_message(
               account,
               %{
                 "to" => "Ada <ada@example.com>",
                 "subject" => "Broken attachment",
                 "body" => "See attached.",
                 "attachments" => [missing]
               },
               req_options: [plug: {Req.Test, BusterClaw.GoogleHTTP}]
             )
  end

  test "modify adds and removes labels on a message" do
    Req.Test.stub(BusterClaw.GoogleHTTP, fn conn ->
      assert conn.method == "POST"
      assert conn.request_path == "/gmail/v1/users/me/messages/msg-1/modify"

      {:ok, body, conn} = Plug.Conn.read_body(conn)
      payload = Jason.decode!(body)
      assert payload["addLabelIds"] == ["STARRED"]
      assert payload["removeLabelIds"] == ["UNREAD", "INBOX"]

      Req.Test.json(conn, %{"id" => "msg-1", "labelIds" => ["STARRED"]})
    end)

    assert {:ok, summary} =
             Gmail.modify(
               connected_account!(),
               "msg-1",
               %{"add" => ["STARRED"], "remove" => ["UNREAD", "INBOX"]},
               req_options: [plug: {Req.Test, BusterClaw.GoogleHTTP}]
             )

    assert summary.id == "msg-1"
    assert summary.label_ids == ["STARRED"]
  end

  test "trash moves a message to the trash" do
    Req.Test.stub(BusterClaw.GoogleHTTP, fn conn ->
      assert conn.method == "POST"
      assert conn.request_path == "/gmail/v1/users/me/messages/msg-1/trash"
      Req.Test.json(conn, %{"id" => "msg-1", "labelIds" => ["TRASH"]})
    end)

    assert {:ok, %{id: "msg-1", label_ids: ["TRASH"]}} =
             Gmail.trash(
               connected_account!(),
               "msg-1",
               req_options: [plug: {Req.Test, BusterClaw.GoogleHTTP}]
             )
  end

  test "delete permanently removes a message" do
    Req.Test.stub(BusterClaw.GoogleHTTP, fn conn ->
      assert conn.method == "DELETE"
      assert conn.request_path == "/gmail/v1/users/me/messages/msg-1"
      Plug.Conn.send_resp(conn, 204, "")
    end)

    assert {:ok, %{id: "msg-1", deleted: true}} =
             Gmail.delete(
               connected_account!(),
               "msg-1",
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
      %{"name" => "Message-ID", "value" => "<original-abc@mail.example.com>"},
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

  defp decode_base64url!(data) do
    data
    |> pad_base64()
    |> Base.url_decode64!()
  end

  defp pad_base64(data) do
    case rem(String.length(data), 4) do
      0 -> data
      missing -> data <> String.duplicate("=", 4 - missing)
    end
  end
end
