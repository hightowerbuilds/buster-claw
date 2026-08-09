defmodule BusterClawWeb.ChatPanelTest do
  # Rendering only — no LiveView, no store. Everything here is a pure function of
  # its assigns, which is the whole reason `ChatPanel` is a component and not a
  # slice of `StatusLive`.
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias BusterClawWeb.ChatPanel
  alias BusterClawWeb.Status.ChatAttachments

  defp image(overrides \\ %{}) do
    Map.merge(
      %{
        id: "abc123",
        filename: "shot.png",
        bytes: 2_048,
        kind: :image,
        media_type: "image/png",
        size_label: "2.0 KB",
        preview: "data:image/png;base64,AAAA",
        available?: true,
        pool_id: 1
      },
      overrides
    )
  end

  defp file(overrides \\ %{}) do
    Map.merge(
      %{
        id: "def456",
        filename: "report.pdf",
        bytes: 1_048_576,
        kind: :binary,
        media_type: "application/pdf",
        size_label: "1.0 MB",
        preview: nil,
        available?: true,
        pool_id: nil
      },
      overrides
    )
  end

  describe "composer chips" do
    test "a pending image shows its name, size, thumbnail and a way out" do
      html = render_component(&ChatPanel.attach_chips/1, attachments: [image()])

      assert html =~ "shot.png"
      assert html =~ "2.0 KB"
      assert html =~ "data:image/png;base64,AAAA"
      # Cancellable before it is sent. An attachment the user cannot take back
      # is worse than one that never attached.
      assert html =~ ~s(phx-click="remove_attachment")
      assert html =~ ~s(phx-value-id="abc123")
    end

    test "a pending file gets an icon rather than a broken thumbnail" do
      html = render_component(&ChatPanel.attach_chips/1, attachments: [file()])

      assert html =~ "report.pdf"
      assert html =~ "1.0 MB"
      refute html =~ "data:"
    end

    test "nothing pending renders nothing at all" do
      assert render_component(&ChatPanel.attach_chips/1, attachments: []) == ""
    end
  end

  describe "the refusal banner" do
    test "says which file and why, and offers a way to clear it" do
      html =
        render_component(&ChatPanel.attach_error/1,
          error: %{
            reason: "too_large",
            filename: "huge.png",
            message: "huge.png is too large to attach."
          },
          upload: nil
        )

      assert html =~ "huge.png is too large to attach."
      assert html =~ ~s(phx-click="dismiss_attach_error")
      assert html =~ ~s(role="alert")
    end

    test "a blocked send adds its own line without losing the reason" do
      html =
        render_component(&ChatPanel.attach_error/1,
          error: %{
            reason: "too_large",
            filename: "huge.png",
            message: "huge.png is too large to attach.",
            blocked: "Nothing was sent."
          },
          upload: nil
        )

      # Both sentences. Replacing the specific one with the generic one would
      # throw away the only text that says which file and why.
      assert html =~ "huge.png is too large to attach."
      assert html =~ "Nothing was sent."
    end

    test "no error renders nothing" do
      assert render_component(&ChatPanel.attach_error/1, error: nil, upload: nil)
             |> String.trim() == ""
    end
  end

  describe "the transcript bubble" do
    test "an image attachment is a thumbnail that opens the shared modal" do
      html = user_bubble("look at this", [image()])

      assert html =~ "look at this"
      assert html =~ "data:image/png;base64,AAAA"
      # `zoom_svg`, not a second viewer: attachments join the same visual pool
      # drawings and 3D scenes use, so paging walks all of them.
      assert html =~ ~s(phx-click="zoom_svg")
      assert html =~ ~s(phx-value-id="1")
    end

    test "a file attachment is a chip" do
      html = user_bubble("read this", [file()])

      assert html =~ "report.pdf"
      refute html =~ ~s(phx-click="zoom_svg")
    end

    test "an attachment whose bytes are gone says so rather than vanishing" do
      html = user_bubble("what is this?", [file(%{available?: false})])

      assert html =~ "report.pdf"
      assert html =~ "No longer available"
    end

    test "an attachment-only message renders no empty text bubble" do
      html = user_bubble("", [image()])

      assert html =~ "data:image/png;base64,AAAA"
      refute html =~ "ic-drop-in"
    end

    test "a message with no attachments is what it always was" do
      html = user_bubble("just words", [])

      assert html =~ "just words"
      refute html =~ "data-attach-image"
      refute html =~ "data-attach-file"
    end
  end

  # `chat_bubble/1` is private (it is only ever rendered by the panel), so the
  # bubble is exercised through the panel with a one-message stream.
  defp user_bubble(text, attachments) do
    msg = %{
      id: 1,
      role: :user,
      text: text,
      svg_ids: [],
      delivery: nil,
      scenes: [],
      attachments: attachments
    }

    render_component(&ChatPanel.chat_panel/1,
      messages: [{"chat-msg-1", msg}],
      seq: 1,
      running: false,
      thinking: nil,
      queue: []
    )
  end

  describe "the citation fence" do
    # The format below is what lands in the transcript and is therefore the
    # thing a reload depends on. Pinning it here means a change to the shape has
    # to be a deliberate one.
    test "round-trips through the transcript" do
      attachments = [
        %{
          id: "abc123",
          filename: "shot.png",
          bytes: 2_048,
          kind: :image,
          media_type: "image/png"
        }
      ]

      wire = ChatAttachments.marker("what is this?", attachments)

      assert wire =~ "what is this?"
      assert wire =~ "```attachments"

      assert {"what is this?", [meta]} = ChatAttachments.decode(wire)
      assert meta.id == "abc123"
      assert meta.filename == "shot.png"
      assert meta.bytes == 2_048
      assert meta.kind == :image
    end

    test "a message with no attachments is left byte-identical" do
      assert ChatAttachments.marker("plain words", []) == "plain words"
      assert ChatAttachments.decode("plain words") == {"plain words", []}
    end

    test "a corrupt fence costs the message nothing" do
      # Silent, like a malformed ```scene3d block: the prose is the message, and
      # losing a citation must not lose the sentence it was attached to.
      assert {"still here", []} =
               ChatAttachments.decode("still here\n\n```attachments\nnot json\n```")
    end
  end
end
