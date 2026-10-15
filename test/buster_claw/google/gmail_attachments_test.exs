defmodule BusterClaw.Google.GmailAttachmentsTest do
  use BusterClaw.DataCase

  alias BusterClaw.Google
  alias BusterClaw.Google.GmailAttachments

  @plug [plug: {Req.Test, BusterClaw.GoogleHTTP}]

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "buster-claw-gmail-attachments-test-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)
    prev_ws = Application.get_env(:buster_claw, :workspace_root)
    Application.put_env(:buster_claw, :workspace_root, root)
    Req.Test.verify_on_exit!()

    on_exit(fn ->
      if prev_ws,
        do: Application.put_env(:buster_claw, :workspace_root, prev_ws),
        else: Application.delete_env(:buster_claw, :workspace_root)

      File.rm_rf(root)
    end)

    {:ok, root: root, account: connected_account!()}
  end

  defp stub_attachments(bytes_by_id) do
    Req.Test.stub(BusterClaw.GoogleHTTP, fn conn ->
      ["", "gmail", "v1", "users", "me", "messages", _mid, "attachments", id] =
        String.split(conn.request_path, "/")

      data = Map.fetch!(bytes_by_id, id)

      Req.Test.json(conn, %{
        "size" => byte_size(data),
        "data" => Base.url_encode64(data, padding: false)
      })
    end)
  end

  defp message(attachments, raw \\ %{}) do
    %{id: "msg 7/x", attachments: attachments, raw: raw}
  end

  defp entry(overrides) do
    Map.merge(
      %{
        part_id: "1",
        attachment_id: "att-1",
        filename: "receipt.jpg",
        mime_type: "image/jpeg",
        size: 3,
        content_id: nil,
        inline?: false,
        inline_data?: false
      },
      overrides
    )
  end

  test "saves every attachment under attachments/gmail/<message-id>/ with workspace-relative paths",
       %{root: root, account: account} do
    stub_attachments(%{"att-1" => "JPG", "att-2" => "%PDF"})

    msg =
      message([
        entry(%{}),
        entry(%{
          part_id: "2",
          attachment_id: "att-2",
          filename: "invoice.pdf",
          mime_type: "application/pdf"
        })
      ])

    assert {:ok, result} = GmailAttachments.save(account, msg, req_options: @plug)

    # The message id is reduced to a safe path segment.
    assert result.directory == "attachments/gmail/msg-7-x"
    assert result.skipped == []
    assert result.errors == []

    assert [
             %{filename: "receipt.jpg", path: "attachments/gmail/msg-7-x/receipt.jpg", bytes: 3} =
               jpg,
             pdf
           ] =
             result.saved

    assert jpg.mime_type == "image/jpeg"
    assert jpg.attachment_id == "att-1"
    assert File.read!(Path.join(root, jpg.path)) == "JPG"
    assert File.read!(Path.join(root, pdf.path)) == "%PDF"
    assert jpg.absolute_path == Path.join(root, jpg.path)
  end

  test "a sender's filename is display data: it is reduced to a safe basename", %{
    root: root,
    account: account
  } do
    stub_attachments(%{"att-1" => "x", "att-2" => "y", "att-3" => "z"})

    msg =
      message([
        entry(%{filename: "../../.ssh/authorized_keys"}),
        entry(%{
          part_id: "2",
          attachment_id: "att-2",
          filename: "weird name (1).PNG",
          mime_type: "image/png"
        }),
        entry(%{part_id: "3", attachment_id: "att-3", filename: nil, mime_type: "image/png"})
      ])

    assert {:ok, %{saved: [keys, png, unnamed]}} =
             GmailAttachments.save(account, msg, req_options: @plug)

    assert keys.filename == "authorized_keys"
    assert png.filename == "weird_name_1_.PNG"
    assert unnamed.filename == "attachment-3.png"

    for saved <- [keys, png, unnamed] do
      assert String.starts_with?(saved.absolute_path, Path.join(root, "attachments/gmail/"))
      assert File.exists?(saved.absolute_path)
    end

    refute File.exists?(Path.expand("../../.ssh/authorized_keys", root))
  end

  test "two attachments with the same name do not overwrite each other", %{account: account} do
    stub_attachments(%{"att-1" => "first", "att-2" => "second"})

    msg =
      message([
        entry(%{filename: "image.jpg"}),
        entry(%{part_id: "2", attachment_id: "att-2", filename: "image.jpg"})
      ])

    assert {:ok, %{saved: [a, b]}} = GmailAttachments.save(account, msg, req_options: @plug)
    assert a.filename == "image.jpg"
    assert b.filename == "image-2.jpg"
    assert File.read!(a.absolute_path) == "first"
    assert File.read!(b.absolute_path) == "second"
  end

  test "an explicit destination is honoured inside the workspace and refused outside it", %{
    root: root,
    account: account
  } do
    stub_attachments(%{"att-1" => "JPG"})
    msg = message([entry(%{})])

    assert {:ok, %{saved: [saved]}} =
             GmailAttachments.save(account, msg,
               destination: "receipts/october",
               req_options: @plug
             )

    assert saved.path == "receipts/october/receipt.jpg"
    assert File.exists?(Path.join(root, "receipts/october/receipt.jpg"))

    Req.Test.stub(BusterClaw.GoogleHTTP, fn _conn ->
      flunk("Google must not be called when the destination is outside the workspace")
    end)

    outside = Path.join(System.tmp_dir!(), "bc-outside-#{System.unique_integer([:positive])}")

    assert {:error, {:destination_outside_workspace, _abs}} =
             GmailAttachments.save(account, msg, destination: outside, req_options: @plug)

    assert {:error, {:destination_outside_workspace, _abs}} =
             GmailAttachments.save(account, msg, destination: "../escape", req_options: @plug)

    refute File.exists?(outside)
  end

  test "an attachment over the cap is skipped without a download, and reported", %{
    account: account
  } do
    stub_attachments(%{"att-2" => "ok"})

    msg =
      message([
        entry(%{
          size: GmailAttachments.max_bytes() + 1,
          filename: "huge.mov",
          mime_type: "video/quicktime"
        }),
        entry(%{part_id: "2", attachment_id: "att-2", filename: "small.jpg"})
      ])

    assert {:ok, result} = GmailAttachments.save(account, msg, req_options: @plug)
    assert [%{filename: "huge.mov", reason: :too_large}] = result.skipped
    assert [%{filename: "small.jpg"}] = result.saved
  end

  test "one failed download does not lose its siblings", %{account: account} do
    Req.Test.stub(BusterClaw.GoogleHTTP, fn conn ->
      if String.ends_with?(conn.request_path, "/att-1") do
        Plug.Conn.send_resp(conn, 404, Jason.encode!(%{"error" => %{"message" => "gone"}}))
      else
        Req.Test.json(conn, %{"data" => Base.url_encode64("ok", padding: false)})
      end
    end)

    msg =
      message([
        entry(%{}),
        entry(%{part_id: "2", attachment_id: "att-2", filename: "second.jpg"})
      ])

    assert {:ok, result} = GmailAttachments.save(account, msg, req_options: @plug)
    assert [%{filename: "receipt.jpg", reason: {:google_api_error, 404, _}}] = result.errors
    assert [%{filename: "second.jpg"}] = result.saved
  end

  test "an attachment Gmail inlined as data is written without any HTTP call", %{account: account} do
    Req.Test.stub(BusterClaw.GoogleHTTP, fn _conn -> flunk("no HTTP expected") end)

    raw = %{
      "payload" => %{
        "parts" => [
          %{
            "partId" => "1",
            "filename" => "invite.ics",
            "body" => %{"data" => Base.url_encode64("BEGIN", padding: false)}
          }
        ]
      }
    }

    msg =
      message(
        [
          entry(%{
            attachment_id: nil,
            inline_data?: true,
            filename: "invite.ics",
            mime_type: "text/calendar"
          })
        ],
        raw
      )

    assert {:ok, %{saved: [saved]}} = GmailAttachments.save(account, msg, req_options: @plug)
    assert File.read!(saved.absolute_path) == "BEGIN"
  end

  test "fetch_bytes/4 decodes an inline-data attachment without a round trip", %{account: account} do
    Req.Test.stub(BusterClaw.GoogleHTTP, fn _conn ->
      flunk("Google must not be called for an inline-data attachment")
    end)

    message = %{
      id: "msg-1",
      raw: %{
        "payload" => %{
          "parts" => [
            %{
              "partId" => "1",
              "filename" => "note.txt",
              "body" => %{"data" => Base.url_encode64("hello", padding: false)}
            }
          ]
        }
      }
    }

    attachment = %{attachment_id: nil, part_id: "1"}

    assert {:ok, "hello"} =
             GmailAttachments.fetch_bytes(account, message, attachment,
               req_options: [plug: {Req.Test, BusterClaw.GoogleHTTP}]
             )
  end

  test "select/2 narrows by attachment_id, filename, or 1-based index" do
    msg = message([entry(%{}), entry(%{part_id: "2", attachment_id: "att-2", filename: "b.pdf"})])

    assert [%{attachment_id: "att-2"}] =
             GmailAttachments.select(msg, %{"attachment_id" => "att-2"})

    assert [%{filename: "receipt.jpg"}] =
             GmailAttachments.select(msg, %{"filename" => "receipt.jpg"})

    assert [%{attachment_id: "att-2"}] = GmailAttachments.select(msg, %{"index" => "2"})
    assert [%{attachment_id: "att-2"}] = GmailAttachments.select(msg, %{"index" => 2})
    assert [] = GmailAttachments.select(msg, %{"index" => 9})
    assert [] = GmailAttachments.select(msg, %{"filename" => "nope"})
    assert length(GmailAttachments.select(msg, %{})) == 2
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
