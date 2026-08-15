defmodule BusterClaw.Google.Gmail.MimeTest do
  @moduledoc """
  Direct unit tests for the outbound composer. `gmail_test.exs` covers the same
  guards end to end through `send_message/3`; these pin them at the module that
  actually owns them, so a future move can't quietly drop one.
  """
  # async: false, and it owns its workspace root.
  #
  # These tests write fixtures inside the workspace because the attachment fence
  # refuses everything outside it — so they READ a global that several other
  # suites (appearance, Voice) WRITE. As `async: true` reading whatever root
  # happened to be set, this raced: one run in three failed the CRLF-stripping
  # test, because the root moved under it between `workspace_file!/3` writing the
  # fixture and `message_mime/1` fencing it. Measured 08-15, three consecutive
  # full runs: 1 failure, 0, 0.
  #
  # Setting its own root is the fix rather than merely marking it sync: a test
  # that depends on a mutable global should not inherit one it did not choose.
  use ExUnit.Case, async: false

  alias BusterClaw.Google.Gmail.Mime
  alias BusterClaw.Library.Artifact

  setup do
    root = Path.join(System.tmp_dir!(), "bc_mime_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    prev = Application.get_env(:buster_claw, :workspace_root)
    Application.put_env(:buster_claw, :workspace_root, root)

    on_exit(fn ->
      Application.put_env(:buster_claw, :workspace_root, prev)
      File.rm_rf(root)
    end)

    {:ok, root: root}
  end

  describe "message_mime/1 required fields" do
    test "reports the first missing field" do
      assert {:error, :missing_recipient} = Mime.message_mime(%{subject: "s", body: "b"})
      assert {:error, :missing_subject} = Mime.message_mime(%{to: "a@example.com", body: "b"})

      assert {:error, :missing_body} =
               Mime.message_mime(%{to: "a@example.com", subject: "s"})
    end

    test "a whitespace-only recipient is still missing" do
      assert {:error, :missing_recipient} =
               Mime.message_mime(%{to: "   ", subject: "s", body: "b"})
    end
  end

  describe "message_mime/1 without attachments" do
    test "renders a single-part text/plain message" do
      assert {:ok, mime} =
               Mime.message_mime(%{
                 to: "Ada <ada@example.com>",
                 subject: "Hello",
                 body: "Line one\nLine two"
               })

      assert mime =~ "To: Ada <ada@example.com>\r\n"
      assert mime =~ "Subject: Hello\r\n"
      assert mime =~ "MIME-Version: 1.0\r\n"
      assert mime =~ ~s(Content-Type: text/plain; charset="UTF-8")
      assert String.ends_with?(mime, "\r\n\r\nLine one\nLine two")
      refute mime =~ "multipart/mixed"
    end

    test "omits optional headers that were not supplied" do
      assert {:ok, mime} =
               Mime.message_mime(%{to: "a@example.com", subject: "s", body: "b"})

      refute mime =~ "Cc:"
      refute mime =~ "Bcc:"
      refute mime =~ "In-Reply-To:"
      refute mime =~ "References:"
    end

    test "joins a list of recipients with commas" do
      assert {:ok, mime} =
               Mime.message_mime(%{
                 to: ["a@example.com", "b@example.com"],
                 subject: "s",
                 body: "b"
               })

      assert mime =~ "To: a@example.com, b@example.com\r\n"
    end

    test "a CRLF in a header value cannot open a header line of its own" do
      assert {:ok, mime} =
               Mime.message_mime(%{
                 to: "a@example.com",
                 subject: "Hello\r\nBcc: hidden@example.com",
                 body: "b"
               })

      assert mime =~ "Subject: Hello Bcc: hidden@example.com\r\n"
      refute mime =~ "\r\nBcc: hidden@example.com"
    end
  end

  describe "message_mime/1 with attachments" do
    test "renders multipart/mixed with the body first and the file after" do
      path = workspace_file!("mime-attach", ".txt", "attachment contents")

      assert {:ok, mime} =
               Mime.message_mime(%{
                 "to" => "a@example.com",
                 "subject" => "s",
                 "body" => "See attached.",
                 "attachments" => [path]
               })

      assert [_, boundary] = Regex.run(~r/boundary="(=_bc_[^"]+)"/, mime)
      assert mime =~ "Content-Type: multipart/mixed; boundary=\"#{boundary}\""
      assert mime =~ "--#{boundary}\r\n"
      assert String.ends_with?(mime, "--#{boundary}--\r\n")
      assert mime =~ "Content-Transfer-Encoding: base64\r\n"
      assert mime =~ Base.encode64("attachment contents")
    end

    test "guesses the content type from the extension and defaults to octet-stream" do
      pdf = workspace_file!("mime-attach", ".pdf", "%PDF-1.4")
      unknown = workspace_file!("mime-attach", ".wat", "?")

      assert {:ok, mime} =
               Mime.message_mime(%{
                 "to" => "a@example.com",
                 "subject" => "s",
                 "body" => "b",
                 "attachments" => [pdf, unknown]
               })

      assert mime =~ "Content-Type: application/pdf; name=\"#{Path.basename(pdf)}\""

      assert mime =~
               "Content-Type: application/octet-stream; name=\"#{Path.basename(unknown)}\""
    end

    test "an explicit filename and content_type win over the file on disk" do
      path = workspace_file!("mime-attach", ".bin", "bytes")

      assert {:ok, mime} =
               Mime.message_mime(%{
                 "to" => "a@example.com",
                 "subject" => "s",
                 "body" => "b",
                 "attachments" => [
                   %{
                     "path" => path,
                     "filename" => "report.pdf",
                     "content_type" => "application/pdf"
                   }
                 ]
               })

      assert mime =~ ~s(Content-Type: application/pdf; name="report.pdf")
      assert mime =~ ~s(Content-Disposition: attachment; filename="report.pdf")
    end

    test "wraps base64 payloads at 76 characters per RFC 2045" do
      contents = String.duplicate("a", 300)
      path = workspace_file!("mime-attach", ".txt", contents)

      assert {:ok, mime} =
               Mime.message_mime(%{
                 "to" => "a@example.com",
                 "subject" => "s",
                 "body" => "b",
                 "attachments" => [path]
               })

      encoded = Base.encode64(contents)
      assert String.length(encoded) > 76

      [first_line | _] =
        mime
        |> String.split("Content-Transfer-Encoding: base64\r\n")
        |> List.last()
        |> String.split("\r\n\r\n")
        |> List.last()
        |> String.split("\r\n")

      assert String.length(first_line) == 76
      assert String.starts_with?(encoded, first_line)
    end

    test "strips CRLF and quotes from filename and content type" do
      path = workspace_file!("mime-attach", ".txt", "payload")

      assert {:ok, mime} =
               Mime.message_mime(%{
                 "to" => "a@example.com",
                 "subject" => "s",
                 "body" => "b",
                 "attachments" => [
                   %{
                     "path" => path,
                     "filename" => "evil.txt\"\r\nX-Injected: evil",
                     "content_type" => "text/plain\r\nBcc: attacker@example.com"
                   }
                 ]
               })

      refute mime =~ "\r\nX-Injected:"
      refute mime =~ "\r\nBcc:"
      assert mime =~ ~s(filename="evil.txtX-Injected: evil")
      assert mime =~ "Content-Type: text/plainBcc: attacker@example.com;"
    end
  end

  describe "the attachment fence" do
    test "refuses a readable file outside the workspace" do
      outside =
        Path.join(System.tmp_dir!(), "buster-claw-mime-#{System.unique_integer([:positive])}.txt")

      File.write!(outside, "private key material")
      on_exit(fn -> File.rm(outside) end)

      assert {:error, {:attachment_outside_workspace, abs}} =
               Mime.message_mime(%{
                 "to" => "a@example.com",
                 "subject" => "s",
                 "body" => "b",
                 "attachments" => [outside]
               })

      assert abs == Path.expand(outside)
    end

    test "refuses a relative path that dot-dots out of the workspace" do
      assert {:error, {:attachment_outside_workspace, _abs}} =
               Mime.message_mime(%{
                 "to" => "a@example.com",
                 "subject" => "s",
                 "body" => "b",
                 "attachments" => ["../../etc/passwd"]
               })
    end

    test "the fence runs before the read — an out-of-workspace missing file is a fence error" do
      outside =
        Path.join(
          System.tmp_dir!(),
          "buster-claw-absent-#{System.unique_integer([:positive])}.txt"
        )

      refute File.exists?(outside)

      assert {:error, {:attachment_outside_workspace, _abs}} =
               Mime.message_mime(%{
                 "to" => "a@example.com",
                 "subject" => "s",
                 "body" => "b",
                 "attachments" => [outside]
               })
    end

    test "an in-workspace path that does not exist is an unreadable error, not a fence error" do
      missing =
        Path.join(
          Artifact.workspace_root(),
          "buster-claw-missing-#{System.unique_integer([:positive])}.txt"
        )

      assert {:error, {:attachment_unreadable, _abs, :enoent}} =
               Mime.message_mime(%{
                 "to" => "a@example.com",
                 "subject" => "s",
                 "body" => "b",
                 "attachments" => [missing]
               })
    end

    test "a spec with no path at all is rejected" do
      for spec <- [%{}, %{"path" => ""}, %{"filename" => "x.txt"}] do
        assert {:error, :missing_attachment_path} =
                 Mime.message_mime(%{
                   "to" => "a@example.com",
                   "subject" => "s",
                   "body" => "b",
                   "attachments" => [spec]
                 })
      end
    end

    test "a non-map, non-binary attachment is rejected" do
      assert {:error, :invalid_attachment} =
               Mime.message_mime(%{
                 "to" => "a@example.com",
                 "subject" => "s",
                 "body" => "b",
                 "attachments" => [123]
               })
    end
  end

  describe "get_attr/2" do
    test "accepts string keys, atom keys, and aliases" do
      assert Mime.get_attr(%{"to" => "a"}, "to") == "a"
      assert Mime.get_attr(%{to: "a"}, "to") == "a"
      assert Mime.get_attr(%{"recipient" => "a"}, "to") == "a"
      assert Mime.get_attr(%{recipient: "a"}, "to") == "a"
      assert Mime.get_attr(%{thread_id: "t"}, "thread_id") == "t"
    end

    test "falls back to a plain string lookup for unknown keys" do
      assert Mime.get_attr(%{"add" => ["STARRED"]}, "add") == ["STARRED"]
      assert Mime.get_attr(%{}, "add") == nil
    end
  end

  describe "header_value/1" do
    test "collapses newlines, trims, joins lists, and blanks nil" do
      assert Mime.header_value(nil) == ""
      assert Mime.header_value("  padded  ") == "padded"
      assert Mime.header_value("a\r\nb") == "a b"
      assert Mime.header_value(["a", "", "b"]) == "a, b"
      assert Mime.header_value(123) == "123"
    end
  end

  # Attachments may only come from inside the workspace, so fixtures are written
  # there rather than to `System.tmp_dir!()`.
  defp workspace_file!(prefix, extension, contents) do
    root = Artifact.workspace_root()
    File.mkdir_p!(root)
    path = Path.join(root, "#{prefix}-#{System.unique_integer([:positive])}#{extension}")
    File.write!(path, contents)
    on_exit(fn -> File.rm(path) end)
    path
  end
end
