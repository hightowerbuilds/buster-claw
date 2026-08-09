defmodule BusterClawWeb.Status.Chat do
  @moduledoc """
  The homepage chat, as socket-in / socket-out functions.

  `StatusLive` was 1,526 lines owning eleven surfaces; a third of it was this
  one. Everything here takes a socket and returns a socket, so it is imported
  by `StatusLive` and every call site reads exactly as it did before the split.

  ## What this owns

  Conversation tabs and activation, the composer's delivery path (`:auto` /
  `:next` / `:steer` and the announcement that follows), the projection of a
  conversation's PubSub events into the transcript stream, the SVG / Scene3D
  visual pool and its modal paging, and history replay.

  ## What it deliberately does not own

  `handle_event/3` and `handle_info/2` stay in `StatusLive`: Phoenix routes to
  the LiveView, and moving the clauses themselves needs macro plumbing that
  costs more than it buys. The clause bodies delegate one line deep into here.

  ## A name that shadows on purpose

  `Chat` inside this module is `BusterClaw.Agent.Chat` — the GenServer — not
  this module. That is the alias the moved code was written against, and
  renaming it would have meant editing every line as it moved, which is the one
  thing a refactor of this size must not do.
  """
  import Phoenix.Component
  import Phoenix.LiveView

  require Logger

  alias BusterClaw.Agent.Chat
  alias BusterClaw.Agent.Conversations
  alias BusterClaw.Agent.Transcript, as: AgentTranscript
  alias BusterClaw.Scene3d
  alias BusterClaw.SvgViewer
  alias BusterClawWeb.Status.ChatAttachments

  # Cap the retained in-memory transcript / SVG bank on the always-open home tab
  # so a long-lived session can't grow its assigns unbounded (oldest drop off the
  # front). The rendered history stays generous; the persisted transcript is the
  # source of truth and is re-read on tab-switch / reload.
  @max_chat_messages 200
  @max_chat_svgs 200

  @doc """
  Adopt a chat skin chosen in Settings → Appearance.

  One assign, deliberately. The skin is a CSS-only concern by contract (see
  `BusterClaw.ChatSkin`), so re-rendering `data-chat-skin` on the panel *is* the
  whole update: every message already on screen restyles from the new descendant
  rules, with no stream ops and no DOM churn. Nothing here may reach into the
  transcript, because a stream cannot re-render what it has already inserted —
  which is exactly why the skin is CSS in the first place.
  """
  def apply_chat_skin(socket, skin), do: assign(socket, :chat_skin, skin)

  # Load the open conversations (tabs), subscribe to each so background runs update
  # the tab badges, and show the most recent one's transcript.
  def init_chats(socket) do
    chats = Conversations.list() |> Enum.map(&to_chat_tab/1)
    active = (List.first(chats) || %{id: Chat.default_conv_id()}).id

    if connected?(socket) do
      Enum.each(chats, &Chat.subscribe(&1.id))
    end

    socket
    |> assign(:chats, chats)
    |> assign(:active_chat, active)
    |> assign(:chat_running, Chat.running?(active))
    |> assign(:chat_steerable, steerable?(active))
    |> assign(:chat_announcement, nil)
    |> assign(:chat_thinking, nil)
    |> assign(:chat_queue, Chat.queue(active))
    |> assign(:zoomed_id, nil)
    # The transcript is a stream: appends send one bubble, not the whole list,
    # and the server doesn't hold 200 messages per socket. dom_id matches the
    # ids chat_bubble always rendered.
    |> stream_configure(:chat_messages, dom_id: &"chat-msg-#{&1.id}")
    |> ChatAttachments.init()
    |> load_chat_history(active)
  end

  def to_chat_tab(conv), do: %{id: conv.id, title: conv.title, running: false, unread: false}

  # Which backend the conversation would use, and whether it can take a message
  # into a turn that is already running. Read per render rather than cached:
  # the harness is a setting, and a stale answer here means the composer offers
  # a Steer button that quietly queues.
  def steerable?(conv_id), do: :steer in Chat.capabilities(conv_id).modes

  # The composer posts one of `auto` / `next` / `steer`. Anything else — an old
  # tab, a hand-crafted request — is read as `auto`, which is today's behaviour
  # and the only safe default: it can start a turn or queue, never claim to have
  # steered.
  def delivery_param(%{"delivery" => "steer"}), do: :steer
  def delivery_param(%{"delivery" => "next"}), do: :next
  def delivery_param(_params), do: :auto

  def dispatch_chat(socket, text, delivery) do
    # The user echo and all agent events arrive via the active conversation's
    # PubSub broadcast, so on success we don't append here. send_message/2 starts
    # the conversation's process on demand (a dev refresh is enough). Errors are
    # appended inline as a persistent message.
    conv_id = socket.assigns.active_chat

    # Start the conversation taught both visual vocabularies (idempotent — the
    # guides are fixed at first start; a no-op once the process exists). They
    # ship together on purpose: each guide's first job is to say when the OTHER
    # channel is the right one, so teaching one alone biases every choice.
    Chat.ensure_started(conv_id,
      append_system_prompt: SvgViewer.guide() <> "\n\n" <> Scene3d.guide(),
      agent: BusterClaw.ModelPolicy.backend_for(:chat)
    )

    do_send(socket, conv_id, text, delivery)
  catch
    :exit, _reason ->
      push_msg(socket, :error, "Chat backend isn't running — restart the server.")
  end

  # While a run is in flight send_message/2 queues the text (returns :ok) rather
  # than rejecting it; the queued item arrives back over PubSub as {:queue, …}.
  # `submit/3` reports the mode that ACTUALLY happened, which is not always the
  # one the composer asked for: a steer lands as `:queued` when the turn ended
  # first. The announcement below is driven by the returned mode for exactly
  # that reason — telling the operator "steered" for a message that was queued
  # is the single most damaging bug this surface can have.
  def do_send(socket, conv_id, text, delivery) do
    # Attachments ride two ways, and both are load-bearing. The citation fence on
    # the persisted text is how a RELOAD finds them again (see `ChatAttachments`);
    # the `:attachments` option is how the MODEL gets them — `Chat.submit/3`
    # carries it to `ChatTransport`, which turns it into `--add-dir`, `-i`, `-f`
    # or a base64 block depending on the backend. Neither substitutes for the
    # other: drop the fence and a reload shows nothing, drop the option and the
    # send looks perfect while the model never sees the file.
    attachments = ChatAttachments.pending(socket)
    wire = ChatAttachments.marker(text, attachments)

    case Chat.submit(conv_id, wire, delivery: delivery, attachments: attachments) do
      {:ok, mode} ->
        socket
        # The composer empties only once the message is actually away. A send
        # that failed must leave the chips where they were, or the user has lost
        # a file they cannot see to re-drop.
        |> ChatAttachments.clear()
        |> announce_delivery(mode, delivery)
        |> maybe_autotitle(conv_id, text)

      {:error, :no_agent_cli} ->
        socket

      {:error, reason} ->
        push_msg(socket, :error, "Could not start the run: #{inspect(reason)}")
    end
  end

  # A polite live-region line, so the delivery state is not encoded by the chip
  # colour alone. It says the wait out loud on a steer, because Phase 0 measured
  # that the agent picks the message up at its next tool boundary — which can be
  # minutes on a long build, not the instant the chip appears.
  def announce_delivery(socket, :steered, _requested),
    do:
      assign(
        socket,
        :chat_announcement,
        "Steered. The agent will pick this up at its next step."
      )

  def announce_delivery(socket, :queued, :steer),
    do:
      assign(
        socket,
        :chat_announcement,
        "The turn finished first, so this was queued to run next."
      )

  def announce_delivery(socket, :queued, _requested),
    do: assign(socket, :chat_announcement, "Queued to run next.")

  # Deliberately does NOT say "steered": this backend cannot confirm receipt,
  # and the announcement is the one place a screen-reader user learns that.
  def announce_delivery(socket, :sent, _requested),
    do:
      assign(
        socket,
        :chat_announcement,
        "Sent to the running turn. This backend does not confirm receipt."
      )

  def announce_delivery(socket, :started, _requested),
    do: assign(socket, :chat_announcement, "Sent.")

  # --- chat transcript projection (from each conversation's PubSub broadcasts) ---
  #
  # A status/message for the ACTIVE conversation updates the rendered transcript;
  # for a background conversation it only flips that tab's running/unread badge —
  # which is what makes concurrent chats visible.

  def apply_chat(socket, conv_id, {:status, status}) do
    socket = update_tab(socket, conv_id, &%{&1 | running: status == :running})

    socket =
      if conv_id == socket.assigns.active_chat do
        socket
        |> assign(:chat_running, status == :running)
        |> assign(:chat_steerable, steerable?(conv_id))
        # Start the live timer on :running; clear it on :idle (the finished duration
        # lives on in the transcript's :meta line, so the header chip can disappear).
        |> assign(:chat_thinking, if(status == :running, do: :running, else: nil))
      else
        socket
      end

    socket
  end

  def apply_chat(socket, conv_id, {:thinking, ms}) do
    if conv_id == socket.assigns.active_chat,
      do: assign(socket, :chat_thinking, {:done, ms}),
      else: socket
  end

  def apply_chat(socket, conv_id, {:queue, items}) do
    if conv_id == socket.assigns.active_chat,
      do: assign(socket, :chat_queue, items),
      else: socket
  end

  # Assistant replies may carry ```svg and ```scene3d blocks: strip both from the
  # spoken/shown bubble text and stash what they produced. Drawings become a
  # "View drawing" link into the modal; scenes render INLINE in the bubble (the
  # card is the message's point, not an attachment to it) while still joining the
  # same modal pool, so paging walks every visual in the conversation.
  #
  # A scene's rendered SVG rides on the message rather than being looked up from
  # the pool because bubbles render as stream items — a stream entry cannot join
  # against a sibling assign at render time.
  def apply_chat(socket, conv_id, {:message, %{role: :assistant, text: text}}) do
    if conv_id == socket.assigns.active_chat do
      {clean, svgs} = SvgViewer.extract(text)
      {clean, scene_svgs} = extract_scenes(clean)
      base = socket.assigns.svg_seq
      socket = collect_svgs(socket, svgs ++ scene_svgs)
      svg_ids = svg_ids_for(base, svgs)
      scenes = scenes_for(base + length(svgs), scene_svgs)

      cond do
        clean != "" ->
          socket
          |> maybe_speak(:assistant, clean)
          |> push_msg(:assistant, clean, svg_ids, nil, scenes)

        svgs != [] or scenes != [] ->
          push_msg(socket, :assistant, "", svg_ids, nil, scenes)

        true ->
          socket
      end
    else
      mark_unread(socket, conv_id)
    end
  end

  # The user's own echo carries the attachment citation fence appended at send.
  # Strip it (the reader must never see the marker, exactly as with ```svg) and
  # turn it back into chips and thumbnails on the bubble.
  def apply_chat(socket, conv_id, {:message, %{role: :user, text: text} = msg}) do
    if conv_id == socket.assigns.active_chat do
      {clean, metas} = ChatAttachments.decode(text)
      {socket, attachments} = attach_to_pool(socket, conv_id, metas)
      push_msg(socket, :user, clean, [], Map.get(msg, :delivery), [], attachments)
    else
      mark_unread(socket, conv_id)
    end
  end

  def apply_chat(socket, conv_id, {:message, %{role: role, text: text} = msg}) do
    if conv_id == socket.assigns.active_chat do
      socket
      |> maybe_speak(role, text)
      # `:delivery` rides through to the bubble so a steered message can say so.
      # Dropping it here is how the chip silently stopped appearing once.
      |> push_msg(role, text, [], Map.get(msg, :delivery))
    else
      mark_unread(socket, conv_id)
    end
  end

  def apply_chat(socket, _conv_id, _other), do: socket

  def mark_unread(socket, conv_id),
    do: update_tab(socket, conv_id, &%{&1 | unread: true})

  # Hydrate cited attachments from the store and give the previewable ones a
  # slot in the same visual pool drawings and scenes use, so clicking a
  # thumbnail opens `svg_modal/1` with no second modal and no new event.
  defp attach_to_pool(socket, _conv_id, []), do: {socket, []}

  defp attach_to_pool(socket, conv_id, metas),
    do: ChatAttachments.place_in_pool(socket, ChatAttachments.hydrate(conv_id, metas))

  # The pool ids `collect_svgs/2` just assigned to this batch (it numbers a batch
  # `svg_seq+1 .. svg_seq+n`), so a bubble can link straight to its own drawings.
  def svg_ids_for(_base, []), do: []
  def svg_ids_for(base, svgs), do: Enum.to_list((base + 1)..(base + length(svgs)))

  # Pull ```scene3d blocks out of a reply and render each to SVG, dropping any
  # that fail to validate. Failure is silent by design: a malformed scene costs
  # the message nothing, exactly as a malformed ```svg block does. The cost of
  # that choice is that a scene the model got wrong is indistinguishable from one
  # it never sent — which is why `Scene3d.guide/0` carries the strict edges.
  def extract_scenes(text) do
    {clean, bodies} = Scene3d.extract(text)
    {clean, Enum.flat_map(bodies, &render_scene/1)}
  end

  def render_scene(body) do
    case Scene3d.render(body) do
      {:ok, svg} ->
        [svg]

      {:error, reason} ->
        Logger.info("scene3d block dropped: #{inspect(reason)}")
        []
    end
  end

  # The `%{id, svg}` entries a bubble renders inline, numbered in step with the
  # modal pool so clicking a card opens the right slide.
  def scenes_for(_base, []), do: []

  def scenes_for(base, svgs) do
    svgs
    |> Enum.with_index(base + 1)
    |> Enum.map(fn {svg, id} -> %{id: id, svg: svg} end)
  end

  # Speak the model's replies aloud (client gates on the Voice toggle + desktop
  # app). Only `:assistant` text — never tool/meta/error lines. A turn emits one
  # `:assistant` message per text block; each is enqueued and spoken in order.
  def maybe_speak(socket, :assistant, text), do: push_event(socket, "bc:speak", %{text: text})
  def maybe_speak(socket, _role, _text), do: socket

  def activate_chat(socket, id) do
    Conversations.touch(id)

    socket
    |> assign(:active_chat, id)
    |> assign(:chat_running, Chat.running?(id))
    |> assign(:chat_steerable, steerable?(id))
    |> assign(:chat_thinking, if(Chat.running?(id), do: :running, else: nil))
    |> assign(:chat_queue, Chat.queue(id))
    |> assign(:zoomed_id, nil)
    |> update_tab(id, &%{&1 | unread: false})
    |> load_chat_history(id)
  end

  def update_tab(socket, conv_id, fun) do
    chats = Enum.map(socket.assigns.chats, fn c -> if c.id == conv_id, do: fun.(c), else: c end)
    assign(socket, :chats, chats)
  end

  # Title a still-"New chat" conversation from its first user message.
  # An attachment-only message has no text to title with, so the conversation
  # keeps "New chat" until something is said. Naming it after a filename was the
  # alternative and it reads worse — the tab strip is a list of topics, not a
  # list of uploads.
  def maybe_autotitle(socket, conv_id, text) do
    tab = Enum.find(socket.assigns.chats, &(&1.id == conv_id))

    if (tab && tab.title == Conversations.default_title()) and String.trim(text) != "" do
      title = title_from(text)
      Conversations.rename(conv_id, title)
      update_tab(socket, conv_id, &%{&1 | title: title})
    else
      socket
    end
  end

  def title_from(text) do
    text |> String.trim() |> String.replace(~r/\s+/, " ") |> String.slice(0, 40)
  end

  def push_msg(
        socket,
        role,
        text,
        svg_ids \\ [],
        delivery \\ nil,
        scenes \\ [],
        attachments \\ []
      ) do
    seq = socket.assigns.chat_seq + 1

    msg = %{
      id: seq,
      role: role,
      text: text,
      svg_ids: svg_ids,
      delivery: delivery,
      scenes: scenes,
      attachments: attachments
    }

    socket
    |> assign(:chat_seq, seq)
    |> stream_insert(:chat_messages, msg, limit: -@max_chat_messages)
  end

  # Keep an appended list to a bound by dropping the oldest entries off the front.
  def cap_list(list, max) do
    over = length(list) - max
    if over > 0, do: Enum.drop(list, over), else: list
  end

  # Append newly-drawn SVGs to the SVG viewer (sanitized before they're stored,
  # since they render live in the DOM).
  def collect_svgs(socket, []), do: socket

  def collect_svgs(socket, svgs) do
    base = socket.assigns.svg_seq

    new =
      svgs
      |> Enum.with_index(base + 1)
      |> Enum.map(fn {svg, i} ->
        %{id: i, svg: svg |> SvgViewer.sanitize() |> SvgViewer.normalize()}
      end)

    socket
    |> assign(:svg_seq, base + length(svgs))
    |> update(:chat_svgs, &cap_list(&1 ++ new, @max_chat_svgs))
  end

  # Move the zoomed image one step through the SVG viewer (clamped at the ends).
  def zoom_step(socket, dir) do
    svgs = socket.assigns.chat_svgs

    case Enum.find_index(svgs, &(&1.id == socket.assigns.zoomed_id)) do
      nil ->
        socket

      idx ->
        next =
          case dir do
            "prev" -> max(0, idx - 1)
            "next" -> min(length(svgs) - 1, idx + 1)
            _ -> idx
          end

        assign(socket, :zoomed_id, Enum.at(svgs, next).id)
    end
  end

  # Restore the transcript AND the visual pool from the conversation's history:
  # assistant rows are stored with their ```svg and ```scene3d blocks intact, so
  # re-extract them to (a) strip the raw markup from the bubble, (b) refill the
  # modal pool, and (c) re-render every scene. The pool thus reflects every
  # visual in the conversation and survives reload / tab-switch. It is NOT a
  # saved gallery — they live only as long as the chat's transcript does, so
  # deleting the chat takes them with it.
  #
  # Scenes are re-rendered from their stored JSON rather than cached, which is
  # what makes a renderer improvement apply retroactively to old conversations.
  # It also means a scene that rendered once will render again — the pipeline is
  # pure, so history replay cannot diverge from what the user first saw.
  def load_chat_history(socket, conv_id) do
    # Reading-order entries built by prepending (++ in the reduce would be
    # quadratic over the 200-row transcript) then reversing. Each assistant entry
    # keeps the drawings and scenes pulled from its blocks, so its bubble can
    # link to and render them; a visual-only reply keeps a text-less bubble
    # rather than vanishing.
    entries =
      conv_id
      |> AgentTranscript.recent(limit: 200)
      |> Enum.reduce([], fn row, acc ->
        case history_role(row.role) do
          :assistant ->
            {clean, block_svgs} = SvgViewer.extract(row.content)
            {clean, scenes} = extract_scenes(clean)

            drawings =
              Enum.map(block_svgs, &(&1 |> SvgViewer.sanitize() |> SvgViewer.normalize()))

            if clean == "" and drawings == [] and scenes == [],
              do: acc,
              else: [
                %{
                  role: :assistant,
                  text: clean,
                  drawings: drawings,
                  scenes: scenes,
                  attachments: []
                }
                | acc
              ]

          # A user row carries its attachment citation fence. Decoding it here is
          # the whole of Phase 3's "they survive reload": the fence names the
          # ids, the store still holds the bytes (attachments die with the
          # conversation, not with the turn), and a file the store has lost still
          # renders as a named chip rather than vanishing.
          :user ->
            {clean, metas} = ChatAttachments.decode(row.content)

            [
              %{
                role: :user,
                text: clean,
                drawings: [],
                scenes: [],
                attachments: ChatAttachments.hydrate(conv_id, metas)
              }
              | acc
            ]

          role ->
            [%{role: role, text: row.content, drawings: [], scenes: [], attachments: []} | acc]
        end
      end)
      |> Enum.reverse()

    # Number every visual across the transcript (reading order — drawings then
    # scenes within a message, matching the live path), hand each message the ids
    # of its own, and build the flat modal pool in step.
    {messages_rev, pool_rev, _next} =
      Enum.reduce(entries, {[], [], 1}, fn entry, {msgs, pool, next} ->
        n = length(entry.drawings)
        ids = if n == 0, do: [], else: Enum.to_list(next..(next + n - 1))
        scenes = scenes_for(next + n - 1, entry.scenes)

        # Image attachments take the slots after this message's drawings and
        # scenes, from the same counter, so the modal pages across drawings,
        # scenes and attachments in one reading order.
        {attachments, attachment_pool, next} =
          ChatAttachments.number(entry.attachments, next + n + length(scenes))

        pool =
          Enum.reduce(
            Enum.zip(ids, entry.drawings) ++
              Enum.map(scenes ++ attachment_pool, &{&1.id, &1.svg}),
            pool,
            fn {id, svg}, p -> [%{id: id, svg: svg} | p] end
          )

        msg = %{
          role: entry.role,
          text: entry.text,
          svg_ids: ids,
          scenes: scenes,
          attachments: attachments
        }

        {[msg | msgs], pool, next}
      end)

    messages =
      messages_rev
      |> Enum.reverse()
      |> Enum.with_index(1)
      |> Enum.map(fn {m, i} -> Map.put(m, :id, i) end)

    svgs = Enum.reverse(pool_rev)
    sent_ids = Enum.flat_map(entries, fn e -> Enum.map(e.attachments, & &1.id) end)

    socket
    |> stream(:chat_messages, messages, reset: true)
    |> assign(:chat_seq, length(messages))
    |> assign(:chat_svgs, svgs)
    |> assign(:svg_seq, length(svgs))
    |> assign(:zoomed_id, nil)
    # Anything the store still holds that the transcript never cited was dropped
    # into the composer and not sent — it comes back as a chip rather than
    # sitting on disk with nothing on screen admitting to it.
    |> ChatAttachments.recover_pending(conv_id, sent_ids)
  end

  @history_roles %{
    "user" => :user,
    "assistant" => :assistant,
    "tool" => :tool,
    "meta" => :meta,
    "error" => :error
  }
  def history_role(role), do: Map.get(@history_roles, role, :assistant)

  # Open a fresh conversation and make it active. Every chat assign is reset
  # explicitly rather than by re-running `init_chats/1`, because the new
  # conversation has no history to replay and a reset stream is cheaper than a
  # round trip that finds nothing.
  def open_new_chat(socket) do
    {:ok, conv} = Conversations.create()
    if connected?(socket), do: Chat.subscribe(conv.id)

    socket
    |> assign(:chats, socket.assigns.chats ++ [to_chat_tab(conv)])
    |> assign(:active_chat, conv.id)
    |> assign(:chat_running, false)
    |> assign(:chat_steerable, steerable?(conv.id))
    |> assign(:chat_thinking, nil)
    |> assign(:chat_queue, [])
    |> stream(:chat_messages, [], reset: true)
    |> assign(:chat_seq, 0)
    |> assign(:chat_svgs, [])
    |> assign(:svg_seq, 0)
    |> assign(:zoomed_id, nil)
    |> ChatAttachments.clear()
  end

  # Close a conversation, stop its process, and decide what the user looks at
  # next. There is always at least one chat open — closing the last one opens a
  # fresh one rather than leaving an empty surface.
  def close_chat(socket, id) do
    Chat.stop(id)
    Conversations.close(id)
    # Attachments die with their conversation — the `chat_svgs` rule, and the
    # operator's constraint that staging is not saving. Closing the tab is the
    # only end a conversation has in this app (the row is archived so the
    # transcript stays queryable), so it is where the staged bytes go.
    ChatAttachments.purge(id)
    # Drop the subscription to the now-closed conversation's topic so its future
    # broadcasts (if any) no longer reach this LiveView.
    if connected?(socket),
      do: Phoenix.PubSub.unsubscribe(BusterClaw.PubSub, Chat.topic(id))

    remaining = Enum.reject(socket.assigns.chats, &(&1.id == id))

    cond do
      # Always keep at least one chat open.
      remaining == [] ->
        {:ok, conv} = Conversations.create()
        if connected?(socket), do: Chat.subscribe(conv.id)
        socket |> assign(:chats, [to_chat_tab(conv)]) |> activate_chat(conv.id)

      # Closing the active tab → switch to the first remaining.
      socket.assigns.active_chat == id ->
        socket |> assign(:chats, remaining) |> activate_chat(hd(remaining).id)

      true ->
        assign(socket, :chats, remaining)
    end
  end
end
