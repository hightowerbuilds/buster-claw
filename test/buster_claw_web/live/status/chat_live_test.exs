defmodule BusterClawWeb.Status.ChatLiveTest do
  @moduledoc """
  The home chat as mounted at `/`: the panel, the two look axes, and attachments.
  """
  use BusterClawWeb.HomeCase

  alias BusterClaw.Agent.Attachments
  alias BusterClaw.ChatSkin
  alias BusterClaw.ChatTextSize
  alias BusterClaw.Settings

  describe "agent chat panel" do
    test "does not render a resize bar", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      refute has_element?(view, "#home-agent-chat [data-resize-handle]")
    end

    test "renders the chat column with an empty-state prompt", %{conn: conn} do
      conn = get(conn, ~p"/")
      response = html_response(conn, 200)

      assert response =~ ~s(id="home-agent-chat")
      assert response =~ ~s(phx-hook="AgentChat")

      assert response =~ ~s(form[phx-submit="chat_send"]) or
               response =~ ~s(phx-submit="chat_send")

      # Spoken replies (TTS): the Voice on/off toggle in the chat header,
      # default OFF since 07-18 (opt in, not out). The STT mic (Mic hook,
      # listening overlay) was demolished 06-28.
      assert response =~ ~s(id="voice-toggle")
      assert response =~ ~s(phx-hook="VoiceToggle")
      assert response =~ "Voice off"
      refute response =~ ~s(id="chat-mic")
      refute response =~ ~s(phx-hook="Mic")
      refute response =~ "Click to talk"
    end

    test "an assistant reply is pushed for speech as prose, not as markdown", %{conn: conn} do
      # Nothing asserted `bc:speak` before this: the whole readback path — server
      # to hook to `say(1)` — was unguarded on the server side. What it must NOT
      # do is hand the synthesizer raw markdown, which reads a fenced block brace
      # by brace and a URL segment by segment.
      {:ok, view, _html} = live(conn, ~p"/")
      active = active_chat(view)

      reply = """
      Here is the fix.

      ```elixir
      def handle_event("save", _params, socket), do: {:noreply, socket}
      ```

      See https://example.com/owner/repo/pull/42 for the **details**.
      """

      send(view.pid, {:agent_chat, active, {:message, %{role: :assistant, text: reply}}})

      assert_push_event(view, "bc:speak", %{text: spoken})

      assert spoken =~ "Here is the fix."
      assert spoken =~ "elixir code block"
      assert spoken =~ "a link to example.com"
      assert spoken =~ "the details."

      # The code and the URL path never reach the synthesizer.
      refute spoken =~ "handle_event"
      refute spoken =~ ":noreply"
      refute spoken =~ "/owner/repo/pull/42"
      refute spoken =~ "**"

      # The bubble still shows the real thing — spoken and displayed differ on
      # purpose, and a change that made them equal again would be the regression.
      html = render(view)
      assert html =~ "handle_event"
    end

    test "projects the active conversation's broadcast events into the transcript", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      active = active_chat(view)

      send(view.pid, {:agent_chat, active, {:message, %{role: :user, text: "work the queue"}}})
      send(view.pid, {:agent_chat, active, {:status, :running}})
      send(view.pid, {:agent_chat, active, {:message, %{role: :assistant, text: "On it."}}})

      send(
        view.pid,
        {:agent_chat, active,
         {:message, %{role: :tool, text: "Bash: ./buster-claw dispatch list"}}}
      )

      html =
        send(view.pid, {:agent_chat, active, {:message, %{role: :meta, text: "2 turns · $0.01"}}})
        |> then(fn _ -> render(view) end)

      assert html =~ "work the queue"
      assert html =~ "On it."
      assert html =~ "Bash: ./buster-claw dispatch list"
      assert html =~ "2 turns"
    end

    test "an error broadcast renders an inline error", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      active = active_chat(view)

      send(
        view.pid,
        {:agent_chat, active,
         {:message, %{role: :error, text: "The run timed out and was stopped."}}}
      )

      assert render(view) =~ "The run timed out and was stopped."
    end

    test "a background conversation's message does not touch the active transcript", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      send(
        view.pid,
        {:agent_chat, "some-other-conv",
         {:message, %{role: :assistant, text: "background reply"}}}
      )

      refute render(view) =~ "background reply"
    end

    test "an SVG in a reply becomes a View drawing link that opens the modal", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      active = active_chat(view)

      svg = ~s(<svg viewBox="0 0 10 10"><circle r="5" /></svg>)

      send(
        view.pid,
        {:agent_chat, active,
         {:message, %{role: :assistant, text: "Here is a circle:\n```svg\n#{svg}\n```"}}}
      )

      html = render(view)
      # The raw block is stripped from the bubble and replaced by a link; there is
      # no persistent side viewer anymore.
      assert html =~ "Here is a circle:"
      refute html =~ "```svg"
      assert html =~ "View drawing"
      refute has_element?(view, "#home-svg-viewer")

      # The link opens the full-screen modal with the (sanitized) drawing.
      html = view |> element(~s(button[phx-click="zoom_svg"])) |> render_click()
      assert html =~ "circle"
    end

    test "an SVG-only reply still shows a View drawing link", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      active = active_chat(view)

      send(
        view.pid,
        {:agent_chat, active,
         {:message,
          %{role: :assistant, text: ~s(```svg\n<svg viewBox="0 0 10 10"><rect /></svg>\n```)}}}
      )

      assert render(view) =~ "View drawing"
    end

    # Scene3D was deleted on 08-16, and with it the ```scene3d block. A reply
    # carrying one is now ordinary prose: nothing strips it, nothing renders it,
    # and the message costs nothing. This pins the *absence* — a re-introduced
    # renderer would fail here rather than arriving unnoticed.
    test "a scene3d block is no longer a visual channel", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      active = active_chat(view)

      send(
        view.pid,
        {:agent_chat, active,
         {:message, %{role: :assistant, text: "See the scene:\n```scene3d\n{\"nodes\": []}\n```"}}}
      )

      html = render(view)
      assert html =~ "See the scene:"
      refute html =~ "3D scene"
      refute has_element?(view, ".ic-scene-card")
    end

    test "New chat adds a tab and clears the panel", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      html = view |> element(~s([phx-click="new_chat"])) |> render_click()
      assert html =~ "New chat"
    end

    test "an active conversation's message lands in the transcript", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      send(
        view.pid,
        {:agent_chat, active_chat(view), {:message, %{role: :assistant, text: "streamed reply"}}}
      )

      assert render(view) =~ "streamed reply"
    end
  end

  describe "chat skin" do
    test "the panel mounts wearing the stored skin", %{conn: conn} do
      ChatSkin.set("slack")

      {:ok, _view, html} = live(conn, ~p"/")

      assert html =~ ~s(data-chat-skin="slack")
    end

    test "a stored skin that no longer exists mounts as the default", %{conn: conn} do
      Settings.put(ChatSkin.setting_key(), "vaporwave")

      {:ok, _view, html} = live(conn, ~p"/")

      assert html =~ ~s(data-chat-skin="#{ChatSkin.default()}")
    end

    test "changing the skin restyles messages already on screen", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/")
      assert html =~ ~s(data-chat-skin="#{ChatSkin.default()}")

      # Put a message in the transcript first. This is the case the whole design
      # exists for: the transcript is a stream, so this node will not be
      # re-rendered by the skin change and has to restyle from CSS alone.
      send(
        view.pid,
        {:agent_chat, active_chat(view), {:message, %{role: :assistant, text: "already here"}}}
      )

      assert render(view) =~ "already here"

      # The real path — Settings write plus broadcast — not a hand-rolled send.
      assert {:ok, "minimal"} = ChatSkin.set("minimal")

      html = render(view)

      assert html =~ ~s(data-chat-skin="minimal")
      # Still there, and untouched: the switch cost no stream ops, which is why
      # it applies to old messages instead of only new ones.
      assert html =~ "already here"
    end

    test "changing the text size restyles messages already on screen too", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/")
      assert html =~ ~s(data-chat-text-size="#{ChatTextSize.default()}")

      send(
        view.pid,
        {:agent_chat, active_chat(view), {:message, %{role: :assistant, text: "older words"}}}
      )

      assert render(view) =~ "older words"

      assert {:ok, "largest"} = ChatTextSize.set("largest")

      html = render(view)

      assert html =~ ~s(data-chat-text-size="largest")
      assert html =~ "older words"
    end

    test "the two axes do not clobber each other on the socket", %{conn: conn} do
      # One handle_info clause serves both, keyed on the axis name. A clause that
      # wrote the wrong assign would show up exactly here.
      {:ok, view, _html} = live(conn, ~p"/")

      assert {:ok, "slack"} = ChatSkin.set("slack")
      assert {:ok, "large"} = ChatTextSize.set("large")

      html = render(view)

      assert html =~ ~s(data-chat-skin="slack")
      assert html =~ ~s(data-chat-text-size="large")
    end
  end

  # The active conversation id is the first seeded conversation ("default").

  defp active_chat(_view), do: "default"

  # A 1×1 PNG. Real magic bytes on purpose: `Attachments.classify/2` sniffs the
  # head and ignores every claim, so a fake payload would stage as `:binary` and
  # every thumbnail assertion below would pass for the wrong reason.
  @png Base.decode64!(
         "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
       )

  describe "chat attachments" do
    setup do
      root = Path.join(System.tmp_dir!(), "bc_attach_#{System.unique_integer([:positive])}")
      prev = Application.get_env(:buster_claw, :attachments_root)
      Application.put_env(:buster_claw, :attachments_root, root)

      on_exit(fn ->
        Application.put_env(:buster_claw, :attachments_root, prev)
        File.rm_rf(root)
      end)

      {:ok, attach_root: root}
    end

    test "a dropped path is staged and chipped with its filename", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      html = render_hook(view, "attach_paths", %{"paths" => [write_file("shot.png", @png)]})

      assert html =~ "shot.png"
      assert has_element?(view, "[data-attach-chips]")
      # The chip carries a thumbnail, not just a name — the whole point of
      # showing it before the send is that the user can see WHICH image.
      assert html =~ "data:image/png;base64,"
    end

    test "a refusal from the hook is surfaced with its reason", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      html =
        render_hook(view, "attach_error", %{
          "reason" => "too_large",
          "filename" => "enormous.psd"
        })

      assert html =~ "enormous.psd"
      assert html =~ "too large"
      assert has_element?(view, "[data-attach-error]")
    end

    test "a refusal from the store is surfaced too", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      # A directory is not a file. The store refuses it (`:not_regular`) and the
      # composer has to say so — a drop that silently does nothing is the false
      # affordance this feature exists to remove.
      html = render_hook(view, "attach_paths", %{"paths" => [System.tmp_dir!()]})

      assert has_element?(view, "[data-attach-error]")
      assert html =~ "cannot be attached" or html =~ "could not be attached"
      refute has_element?(view, "[data-attach-chips]")
    end

    test "an attachment can be removed before it is sent", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      render_hook(view, "attach_paths", %{"paths" => [write_file("notes.md", "# hello\n")]})

      assert has_element?(view, "[data-attach-chip]")

      html =
        view
        |> element(~s([data-attach-chips] button[phx-click="remove_attachment"]))
        |> render_click()

      refute html =~ "notes.md"
      refute has_element?(view, "[data-attach-chips]")
      # Removed from the staging directory too — a file the user cancelled has
      # no reason to sit on disk until the conversation is deleted.
      assert Attachments.list(active_chat(view)) == []
    end

    test "a refused attachment blocks the send until it is dismissed", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      render_hook(view, "attach_error", %{"reason" => "too_large", "filename" => "huge.png"})

      html = view |> form("#home-composer", %{"message" => "look at this"}) |> render_submit()

      # Nothing went. Silently sending a message whose image did not make it is
      # the failure this gate exists for, and the banner has to say so.
      assert html =~ "Nothing was sent"
      refute html =~ ~s(class="ic-drop-in)

      html =
        view
        |> element(~s([data-attach-error] button[phx-click="dismiss_attach_error"]))
        |> render_click()

      refute html =~ "Nothing was sent"
      refute has_element?(view, "[data-attach-error]")
    end

    test "sending clears the composer's chips", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      conv = active_chat(view)
      start_fake_chat(conv)

      render_hook(view, "attach_paths", %{"paths" => [write_file("shot.png", @png)]})
      assert has_element?(view, "[data-attach-chip]")

      view |> form("#home-composer", %{"message" => "what is this?"}) |> render_submit()

      refute has_element?(view, "[data-attach-chips]")
      # The echo arrives over PubSub, a hop after the submit returns.
      html = render(view)
      # The message itself still shows what rode with it...
      assert html =~ "what is this?"
      assert has_element?(view, "[data-attach-image]")
      # ...and the raw citation fence never reaches the reader.
      refute html =~ "```attachments"
    end

    test "an attachment-only message is a real message", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      start_fake_chat(active_chat(view))

      render_hook(view, "attach_paths", %{"paths" => [write_file("shot.png", @png)]})
      view |> form("#home-composer", %{"message" => ""}) |> render_submit()

      assert has_element?(view, "[data-attach-image]")
      refute render(view) =~ "```attachments"
    end

    test "a user message with an image shows a thumbnail that opens the modal", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      conv = active_chat(view)
      {:ok, att} = stage(conv, "shot.png", @png)

      send(view.pid, {:agent_chat, conv, {:message, %{role: :user, text: marker("look", [att])}}})

      html = render(view)
      assert html =~ "look"
      assert html =~ "data:image/png;base64,"
      assert has_element?(view, ~s([data-attach-image="#{att.id}"]))

      # It joined the drawings' visual pool, so the EXISTING modal opens it —
      # there is no second viewer.
      html = view |> element(~s([data-attach-image] )) |> render_click()
      assert html =~ "ic-svg-modal"
    end

    test "a non-image attachment renders as a chip, not a broken thumbnail", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      conv = active_chat(view)
      {:ok, att} = stage(conv, "report.pdf", "%PDF-1.4\n trailing bytes\n")

      send(
        view.pid,
        {:agent_chat, conv, {:message, %{role: :user, text: marker("read it", [att])}}}
      )

      assert has_element?(view, ~s([data-attach-file="#{att.id}"]))
      refute has_element?(view, "[data-attach-image]")
    end

    test "an SVG never renders as a thumbnail, whatever it claims to be", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      conv = active_chat(view)

      svg = ~s|<svg xmlns="http://www.w3.org/2000/svg"><script>alert("x")</script></svg>|
      {:ok, att} = stage(conv, "trojan.svg", svg)

      send(view.pid, {:agent_chat, conv, {:message, %{role: :user, text: marker("hm", [att])}}})

      # A chip, not an <img>. An SVG is a document that can carry script, and the
      # only path that renders one live sanitizes it first — an attachment does
      # not, so it does not get to be one. The 07-04 review paid for this once.
      assert has_element?(view, ~s([data-attach-file="#{att.id}"]))
      refute has_element?(view, "[data-attach-image]")
      refute render(view) =~ "alert("
    end

    test "a forged citation cannot talk a file into being an image", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      conv = active_chat(view)
      {:ok, att} = stage(conv, "notes.md", "# not an image\n")

      # The fence is prose in an append-only log; nothing stops it claiming
      # anything. What renders comes from the STORE's record, sniffed from the
      # bytes, so the claim buys nothing.
      forged = marker("look", [%{att | media_type: "image/png", kind: :image}])
      send(view.pid, {:agent_chat, conv, {:message, %{role: :user, text: forged}}})

      refute has_element?(view, "[data-attach-image]")
      assert has_element?(view, ~s([data-attach-file="#{att.id}"]))
    end

    test "an attachment is still rendered after a reload", %{conn: conn} do
      conv = "default"
      {:ok, att} = stage(conv, "shot.png", @png)
      BusterClaw.Agent.Transcript.record(conv, "user", marker("what is this?", [att]))

      # A fresh mount — nothing carried over from the session that sent it. The
      # transcript names the ids, the store still has the bytes.
      {:ok, view, html} = live(conn, ~p"/")

      assert html =~ "what is this?"
      refute html =~ "```attachments"
      assert has_element?(view, ~s([data-attach-image="#{att.id}"]))
      assert render(view) =~ "data:image/png;base64,"
    end

    test "a reloaded attachment whose bytes are gone still names itself", %{conn: conn} do
      conv = "default"
      {:ok, att} = stage(conv, "shot.png", @png)
      BusterClaw.Agent.Transcript.record(conv, "user", marker("what is this?", [att]))
      :ok = Attachments.purge(conv)

      {:ok, view, html} = live(conn, ~p"/")

      # The citation is enough to render an honest chip. Disappearing would be
      # the alternative, and a message that quietly loses its attachment is
      # exactly what this design is trying to make impossible.
      assert html =~ "shot.png"
      assert html =~ "No longer available"
      assert has_element?(view, ~s([data-attach-file="#{att.id}"]))
    end

    test "an unsent attachment comes back after a reload", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      render_hook(view, "attach_paths", %{"paths" => [write_file("draft.md", "# draft\n")]})

      {:ok, _view, html} = live(conn, ~p"/")

      # It is still staged and nothing cited it, so it is still in the composer
      # rather than an orphan on disk that nothing on screen admits to.
      assert html =~ "draft.md"
      assert html =~ "data-attach-chips"
    end

    test "closing a conversation purges its attachments and nobody else's", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      conv = active_chat(view)
      {:ok, _} = stage(conv, "mine.png", @png)

      other = "bystander"
      {:ok, _} = stage(other, "theirs.png", @png)

      view |> element(~s([role="tab"] span[phx-click="close_chat"])) |> render_click()

      assert Attachments.list(conv) == []
      assert [%{filename: "theirs.png"}] = Attachments.list(other)
    end
  end

  # --- attachment helpers ----------------------------------------------------

  defp write_file(name, contents) do
    dir = Path.join(System.tmp_dir!(), "bc_drop_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    path = Path.join(dir, name)
    File.write!(path, contents)
    on_exit(fn -> File.rm_rf(dir) end)
    path
  end

  defp stage(conv, name, contents) do
    Attachments.stage(
      conv,
      %{filename: name, media_type: MIME.from_path(name), source: :upload},
      {:bytes, contents}
    )
  end

  # The citation fence exactly as the composer writes it, so these tests pin the
  # format the transcript actually carries rather than a test-only shape.
  defp marker(text, attachments),
    do: BusterClawWeb.Status.ChatAttachments.marker(text, attachments)

  # A conversation process with a spawner that starts nothing, so a submit
  # succeeds (and echoes the user message back over PubSub) without a CLI.
  defp start_fake_chat(conv_id) do
    {:ok, pid} =
      BusterClaw.Agent.Chat.start_link(
        conv_id: conv_id,
        spawner: fn _prompt, _opts -> {:ok, make_ref()} end,
        transport_mod: BusterClaw.Agent.FakePersistentTransport,
        persist: false,
        audit: false
      )

    # An exit signal to a pid that is already gone is a no-op, so no guard.
    on_exit(fn -> Process.exit(pid, :kill) end)
    pid
  end
end
