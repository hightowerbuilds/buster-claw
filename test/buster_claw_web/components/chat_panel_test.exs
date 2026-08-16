defmodule BusterClawWeb.ChatPanelTest do
  # Rendering only — no LiveView, no store. Everything here is a pure function of
  # its assigns, which is the whole reason `ChatPanel` is a component and not a
  # slice of `StatusLive`.
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias BusterClaw.ChatSkin
  alias BusterClaw.ChatTextSize
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
      # drawings use, so paging walks all of them.
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

  defp msg(id, role, overrides) do
    %{
      id: id,
      role: role,
      text: "#{role} says something",
      svg_ids: [],
      delivery: nil,
      attachments: []
    }
    |> Map.merge(overrides)
  end

  # A maximally furnished panel: a bubble of every role, a running turn (so Stop
  # renders), the thinking chip, a queued message, an attachment and a delivery
  # chip. The skin-identity test is only as strong as the markup it renders, so
  # this deliberately turns everything on rather than testing an empty panel —
  # an empty chat is precisely the case where a half-applied skin looks fine.
  defp panel(overrides \\ []) do
    messages = [
      {"chat-msg-1", msg(1, :user, %{delivery: :steered, attachments: [image(), file()]})},
      {"chat-msg-2", msg(2, :assistant, %{svg_ids: ["svg-1"]})},
      {"chat-msg-3", msg(3, :tool, %{})},
      {"chat-msg-4", msg(4, :meta, %{})},
      {"chat-msg-5", msg(5, :error, %{})}
    ]

    defaults = [
      messages: messages,
      seq: 5,
      running: true,
      steerable: true,
      thinking: {:done, 4_200},
      queue: [%{id: "q1", text: "next thing"}],
      agent_cli_missing: true,
      attachments: [image()],
      announcement: "Steered into the running turn."
    ]

    render_component(&ChatPanel.chat_panel/1, Keyword.merge(defaults, overrides))
  end

  describe "skins" do
    # The load-bearing test of the whole skin feature. The transcript is a
    # LiveView stream: children are rendered once, on insert, so a message
    # already on screen keeps the classes it was born with. If any skin were
    # allowed to change the markup, switching skins would restyle the header and
    # composer and leave every existing message in the old look until a reload —
    # half-applied, and invisible on an empty chat.
    #
    # So the panel emits exactly one skin-dependent thing: `data-chat-skin`.
    # Normalize that away and all three renders must be byte-identical. A future
    # `if @skin == "slack"` in the template fails right here.
    test "every skin and size renders byte-identical markup apart from the attributes" do
      # The cross-product, not each axis alone: a branch on the PAIR would slip
      # past two independent sweeps.
      [first | rest] =
        for skin <- ChatSkin.keys(), size <- ChatTextSize.keys() do
          panel(skin: skin, text_size: size)
          |> String.replace(~s(data-chat-skin="#{skin}"), ~s(data-chat-skin="NORMALIZED"))
          |> String.replace(
            ~s(data-chat-text-size="#{size}"),
            ~s(data-chat-text-size="NORMALIZED")
          )
        end

      for other <- rest do
        assert other == first,
               "a skin or size changed the markup. Both are CSS-only by contract — " <>
                 "see BusterClaw.ChatSkin. Render the element in every skin and hide " <>
                 "it in CSS instead of branching the template."
      end
    end

    test "the size reaches the DOM as data-chat-text-size" do
      for size <- ChatTextSize.keys() do
        assert panel(text_size: size) =~ ~s(data-chat-text-size="#{size}")
      end

      assert panel() =~ ~s(data-chat-text-size="#{ChatTextSize.default()}")
    end

    # The sizes are applied by multiplying one CSS custom property, so nothing in
    # the chat may carry its own font-size literal — a bubble that did would keep
    # its size while everything around it grew.
    test "no chat type size is pinned in the markup" do
      html = panel()

      refute html =~ "text-[17px]",
             "a type size came back into the markup. It cannot be multiplied there — " <>
               "see the `--chat-scale` block in app.css."

      for anchor <- ~w(data-chat-body data-chat-empty) do
        assert html =~ anchor
      end
    end

    test "the skin reaches the DOM as data-chat-skin" do
      for skin <- ChatSkin.keys() do
        assert panel(skin: skin) =~ ~s(data-chat-skin="#{skin}")
      end
    end

    test "a panel rendered without a skin wears the default" do
      assert panel() =~ ~s(data-chat-skin="#{ChatSkin.default()}")
    end

    # A skin is CSS, so its selectors are the only way it can reach anything.
    # These anchors are that reach. Deleting one silently un-skins a piece of the
    # panel in all three looks at once, with a green suite — the failure mode this
    # test exists for.
    test "every part a skin has to address is anchored" do
      html = panel()

      for anchor <- ~w(data-chat-header data-chat-log data-chat-form data-chat-input) do
        assert html =~ anchor, "the #{anchor} anchor is gone — a skin cannot reach it"
      end

      for role <- ~w(user assistant tool meta error) do
        assert html =~ ~s(data-chat-role="#{role}"),
               "the #{role} bubble lost its role anchor, so no skin can style it"
      end

      # The thing that carries a bubble's background and border — what Minimal
      # strips and Workplace re-shapes.
      assert html =~ "data-chat-body"
    end

    test "the author line is present and inaudible-only until a skin asks for it" do
      html = panel()

      # Real DOM, not a CSS `content:` string: announced in every skin, and it
      # survives copy-paste. `sr-only` is why adding it changed nothing visually.
      assert html =~ ~s(<span data-chat-author class="sr-only">You</span>)
      assert html =~ ~s(<span data-chat-author class="sr-only">Buster Claw</span>)
    end
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
      # Silent, like a malformed ```svg block: the prose is the message, and
      # losing a citation must not lose the sentence it was attached to.
      assert {"still here", []} =
               ChatAttachments.decode("still here\n\n```attachments\nnot json\n```")
    end
  end
end
