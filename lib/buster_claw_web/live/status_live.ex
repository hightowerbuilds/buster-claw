defmodule BusterClawWeb.StatusLive do
  use BusterClawWeb, :live_view

  alias BusterClaw.Agent.Chat
  alias BusterClaw.Agent.Conversations
  alias BusterClaw.Agent.Transcript, as: AgentTranscript
  alias BusterClaw.Appearance
  alias BusterClaw.Calendar, as: AppCalendar
  alias BusterClaw.LocalTime
  alias BusterClaw.Runtime.Status
  alias BusterClaw.Setup
  alias BusterClaw.SvgViewer
  alias BusterClaw.TrustedSenders

  # Cap the retained in-memory transcript / SVG bank on the always-open home tab
  # so a long-lived session can't grow its assigns unbounded (oldest drop off the
  # front). The rendered history stays generous; the persisted transcript is the
  # source of truth and is re-read on tab-switch / reload.
  @max_chat_messages 200
  @max_chat_svgs 200

  @impl true
  def mount(_params, _session, socket) do
    today = LocalTime.today()

    if connected?(socket),
      do: Phoenix.PubSub.subscribe(BusterClaw.PubSub, Appearance.home_topic())

    {:ok,
     socket
     |> assign(:page_title, "Home")
     |> assign(:home_bg, Appearance.home_background_state())
     |> assign(status: Status.snapshot())
     |> assign(:today, today)
     |> assign(:setup_status, Setup.status())
     |> assign(:trusted_contacts, TrustedSenders.list_entries())
     # Header widget: which sub-tab is showing (Calendar / Contacts).
     |> assign(:widget_tab, "calendar")
     |> init_chats()
     |> load_calendar_month()}
  end

  # Load the open conversations (tabs), subscribe to each so background runs update
  # the tab badges, and show the most recent one's transcript.
  defp init_chats(socket) do
    chats = Conversations.list() |> Enum.map(&to_chat_tab/1)
    active = (List.first(chats) || %{id: Chat.default_conv_id()}).id

    if connected?(socket), do: Enum.each(chats, &Chat.subscribe(&1.id))

    socket
    |> assign(:chats, chats)
    |> assign(:active_chat, active)
    |> assign(:chat_running, Chat.running?(active))
    |> assign(:chat_thinking, nil)
    |> assign(:chat_queue, Chat.queue(active))
    |> assign(:zoomed_id, nil)
    |> assign(:svg_viewer_open, false)
    |> load_chat_history(active)
  end

  defp to_chat_tab(conv), do: %{id: conv.id, title: conv.title, running: false, unread: false}

  @impl true
  def handle_event("add_contact", %{"entry" => entry}, socket) do
    case TrustedSenders.add_entry(entry) do
      {:ok, _value} ->
        {:noreply, assign(socket, :trusted_contacts, TrustedSenders.list_entries())}

      {:error, :invalid_entry} ->
        {:noreply,
         put_flash(socket, :error, "Enter a full email address or a *@domain wildcard.")}
    end
  end

  def handle_event("remove_contact", %{"entry" => entry}, socket) do
    TrustedSenders.remove_entry(entry)
    {:noreply, assign(socket, :trusted_contacts, TrustedSenders.list_entries())}
  end

  def handle_event("select_widget_tab", %{"tab" => tab}, socket)
      when tab in ["calendar", "contacts"],
      do: {:noreply, assign(socket, :widget_tab, tab)}

  def handle_event("chat_send", %{"message" => text}, socket) do
    # Sending barges in on any reply still being spoken.
    socket = push_event(socket, "bc:stop_speak", %{})

    case String.trim(text) do
      "" -> {:noreply, socket}
      trimmed -> {:noreply, dispatch_chat(socket, trimmed)}
    end
  end

  def handle_event("cancel_queued", %{"id" => id}, socket) do
    case Integer.parse(id) do
      {qid, ""} -> Chat.remove_queued(socket.assigns.active_chat, qid)
      _ -> :ok
    end

    {:noreply, socket}
  end

  def handle_event("cut_run", _params, socket) do
    Chat.interrupt(socket.assigns.active_chat)
    {:noreply, push_event(socket, "bc:stop_speak", %{})}
  end

  def handle_event("barge_queued", %{"id" => id}, socket) do
    case Integer.parse(id) do
      {qid, ""} -> Chat.barge(socket.assigns.active_chat, qid)
      _ -> :ok
    end

    {:noreply, socket}
  end

  def handle_event("reorder_queue", %{"ids" => ids}, socket) do
    parsed =
      ids
      |> List.wrap()
      |> Enum.map(&Integer.parse/1)
      |> Enum.flat_map(fn
        {n, ""} -> [n]
        _ -> []
      end)

    Chat.reorder_queue(socket.assigns.active_chat, parsed)
    {:noreply, socket}
  end

  def handle_event("select_chat", %{"id" => id}, socket),
    do: {:noreply, activate_chat(socket, id)}

  def handle_event("new_chat", _params, socket) do
    {:ok, conv} = Conversations.create()
    if connected?(socket), do: Chat.subscribe(conv.id)

    socket =
      socket
      |> assign(:chats, socket.assigns.chats ++ [to_chat_tab(conv)])
      |> assign(:active_chat, conv.id)
      |> assign(:chat_running, false)
      |> assign(:chat_thinking, nil)
      |> assign(:chat_queue, [])
      |> assign(:chat_messages, [])
      |> assign(:chat_seq, 0)
      |> assign(:chat_svgs, [])
      |> assign(:svg_seq, 0)
      |> assign(:zoomed_id, nil)

    {:noreply, socket}
  end

  # Open / close / page the full-screen SVG viewer modal. `@zoomed_id` is the id of
  # the SVG currently shown (or nil).
  def handle_event("zoom_svg", %{"id" => id}, socket) do
    zoomed =
      case Integer.parse(id) do
        {n, ""} -> if Enum.any?(socket.assigns.chat_svgs, &(&1.id == n)), do: n, else: nil
        _ -> nil
      end

    {:noreply, assign(socket, :zoomed_id, zoomed)}
  end

  def handle_event("close_zoom", _params, socket),
    do: {:noreply, assign(socket, :zoomed_id, nil)}

  def handle_event("toggle_svg_viewer", _params, socket),
    do: {:noreply, update(socket, :svg_viewer_open, &(!&1))}

  def handle_event("zoom_nav", %{"dir" => dir}, socket),
    do: {:noreply, zoom_step(socket, dir)}

  # Keyboard while the modal is open: Esc closes, arrows page through the SVG viewer.
  def handle_event("zoom_key", %{"key" => "Escape"}, socket),
    do: {:noreply, assign(socket, :zoomed_id, nil)}

  def handle_event("zoom_key", %{"key" => "ArrowLeft"}, socket),
    do: {:noreply, zoom_step(socket, "prev")}

  def handle_event("zoom_key", %{"key" => "ArrowRight"}, socket),
    do: {:noreply, zoom_step(socket, "next")}

  def handle_event("zoom_key", _params, socket), do: {:noreply, socket}

  def handle_event("close_chat", %{"id" => id}, socket) do
    Chat.stop(id)
    Conversations.close(id)
    # Drop the subscription to the now-closed conversation's topic so its future
    # broadcasts (if any) no longer reach this LiveView.
    if connected?(socket),
      do: Phoenix.PubSub.unsubscribe(BusterClaw.PubSub, Chat.topic(id))

    remaining = Enum.reject(socket.assigns.chats, &(&1.id == id))

    socket =
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

    {:noreply, socket}
  end

  defp dispatch_chat(socket, text) do
    # The user echo and all agent events arrive via the active conversation's
    # PubSub broadcast, so on success we don't append here. send_message/2 starts
    # the conversation's process on demand (a dev refresh is enough). Errors are
    # appended inline as a persistent message.
    conv_id = socket.assigns.active_chat

    # Start the conversation taught the SVG viewer vocabulary (idempotent — the
    # guide is fixed at first start; a no-op once the process exists).
    Chat.ensure_started(conv_id, append_system_prompt: SvgViewer.guide())

    # While a run is in flight send_message/2 queues the text (returns :ok) rather
    # than rejecting it; the queued item arrives back over PubSub as {:queue, …}.
    case Chat.send_message(conv_id, text) do
      :ok ->
        maybe_autotitle(socket, conv_id, text)

      {:error, :no_agent_cli} ->
        socket

      {:error, reason} ->
        push_msg(socket, :error, "Could not start the run: #{inspect(reason)}")
    end
  catch
    :exit, _reason ->
      push_msg(socket, :error, "Chat backend isn't running — restart the server.")
  end

  @impl true
  def handle_info({:agent_chat, conv_id, payload}, socket),
    do: {:noreply, apply_chat(socket, conv_id, payload)}

  # The homepage background changed in settings — re-render it live.
  def handle_info({:home_background, state}, socket),
    do: {:noreply, assign(socket, :home_bg, state)}

  def handle_info(_message, socket), do: {:noreply, socket}

  # --- chat transcript projection (from each conversation's PubSub broadcasts) ---
  #
  # A status/message for the ACTIVE conversation updates the rendered transcript;
  # for a background conversation it only flips that tab's running/unread badge —
  # which is what makes concurrent chats visible.

  defp apply_chat(socket, conv_id, {:status, status}) do
    socket = update_tab(socket, conv_id, &%{&1 | running: status == :running})

    if conv_id == socket.assigns.active_chat do
      socket
      |> assign(:chat_running, status == :running)
      # Start the live timer on :running; clear it on :idle (the finished duration
      # lives on in the transcript's :meta line, so the header chip can disappear).
      |> assign(:chat_thinking, if(status == :running, do: :running, else: nil))
    else
      socket
    end
  end

  defp apply_chat(socket, conv_id, {:thinking, ms}) do
    if conv_id == socket.assigns.active_chat,
      do: assign(socket, :chat_thinking, {:done, ms}),
      else: socket
  end

  defp apply_chat(socket, conv_id, {:queue, items}) do
    if conv_id == socket.assigns.active_chat,
      do: assign(socket, :chat_queue, items),
      else: socket
  end

  # Assistant replies may carry ```svg blocks: route those to the SVG viewer
  # sidebar (as real SVGs) and strip them from the spoken/shown bubble text. A
  # reply that was *only* an SVG adds no bubble.
  defp apply_chat(socket, conv_id, {:message, %{role: :assistant, text: text}}) do
    if conv_id == socket.assigns.active_chat do
      {clean, svgs} = SvgViewer.extract(text)
      socket = collect_svgs(socket, svgs)

      if clean == "" do
        socket
      else
        socket |> maybe_speak(:assistant, clean) |> push_msg(:assistant, clean)
      end
    else
      update_tab(socket, conv_id, &%{&1 | unread: true})
    end
  end

  defp apply_chat(socket, conv_id, {:message, %{role: role, text: text}}) do
    if conv_id == socket.assigns.active_chat do
      socket
      |> maybe_speak(role, text)
      |> push_msg(role, text)
    else
      update_tab(socket, conv_id, &%{&1 | unread: true})
    end
  end

  defp apply_chat(socket, _conv_id, _other), do: socket

  # Speak the model's replies aloud (client gates on the Voice toggle + desktop
  # app). Only `:assistant` text — never tool/meta/error lines. A turn emits one
  # `:assistant` message per text block; each is enqueued and spoken in order.
  defp maybe_speak(socket, :assistant, text), do: push_event(socket, "bc:speak", %{text: text})
  defp maybe_speak(socket, _role, _text), do: socket

  defp activate_chat(socket, id) do
    Conversations.touch(id)

    socket
    |> assign(:active_chat, id)
    |> assign(:chat_running, Chat.running?(id))
    |> assign(:chat_thinking, if(Chat.running?(id), do: :running, else: nil))
    |> assign(:chat_queue, Chat.queue(id))
    |> assign(:zoomed_id, nil)
    |> update_tab(id, &%{&1 | unread: false})
    |> load_chat_history(id)
  end

  defp update_tab(socket, conv_id, fun) do
    chats = Enum.map(socket.assigns.chats, fn c -> if c.id == conv_id, do: fun.(c), else: c end)
    assign(socket, :chats, chats)
  end

  # Title a still-"New chat" conversation from its first user message.
  defp maybe_autotitle(socket, conv_id, text) do
    tab = Enum.find(socket.assigns.chats, &(&1.id == conv_id))

    if tab && tab.title == Conversations.default_title() do
      title = title_from(text)
      Conversations.rename(conv_id, title)
      update_tab(socket, conv_id, &%{&1 | title: title})
    else
      socket
    end
  end

  defp title_from(text) do
    text |> String.trim() |> String.replace(~r/\s+/, " ") |> String.slice(0, 40)
  end

  defp push_msg(socket, role, text) do
    seq = socket.assigns.chat_seq + 1
    msg = %{id: seq, role: role, text: text}

    socket
    |> assign(:chat_seq, seq)
    |> update(:chat_messages, &cap_list(&1 ++ [msg], @max_chat_messages))
  end

  # Keep an appended list to a bound by dropping the oldest entries off the front.
  defp cap_list(list, max) do
    over = length(list) - max
    if over > 0, do: Enum.drop(list, over), else: list
  end

  # Append newly-drawn SVGs to the SVG viewer (sanitized before they're stored,
  # since they render live in the DOM).
  defp collect_svgs(socket, []), do: socket

  defp collect_svgs(socket, svgs) do
    base = socket.assigns.svg_seq

    new =
      svgs
      |> Enum.with_index(base + 1)
      |> Enum.map(fn {svg, i} -> %{id: i, svg: SvgViewer.sanitize(svg)} end)

    socket
    |> assign(:svg_seq, base + length(svgs))
    |> update(:chat_svgs, &cap_list(&1 ++ new, @max_chat_svgs))
  end

  # Move the zoomed image one step through the SVG viewer (clamped at the ends).
  defp zoom_step(socket, dir) do
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

  # Restore the transcript AND the SVG viewer from the conversation's history:
  # assistant rows are stored with their ```svg blocks intact, so re-extract them
  # to (a) strip the raw markup from the bubble and (b) refill the SVG viewer. The
  # bank thus reflects every SVG in the conversation and survives reload /
  # tab-switch. It is NOT a saved gallery — the drawings only live as long as the
  # chat's transcript does, so deleting the chat takes them with it.
  defp load_chat_history(socket, conv_id) do
    {messages, svgs} =
      conv_id
      |> AgentTranscript.recent(limit: 200)
      |> Enum.reduce({[], []}, fn row, {msgs, svgs} ->
        case history_role(row.role) do
          :assistant ->
            {clean, block_svgs} = SvgViewer.extract(row.content)
            svgs = svgs ++ Enum.map(block_svgs, &SvgViewer.sanitize/1)
            msgs = if clean == "", do: msgs, else: msgs ++ [%{role: :assistant, text: clean}]
            {msgs, svgs}

          role ->
            {msgs ++ [%{role: role, text: row.content}], svgs}
        end
      end)

    messages = messages |> Enum.with_index(1) |> Enum.map(fn {m, i} -> Map.put(m, :id, i) end)
    svgs = svgs |> Enum.with_index(1) |> Enum.map(fn {svg, i} -> %{id: i, svg: svg} end)

    socket
    |> assign(:chat_messages, messages)
    |> assign(:chat_seq, length(messages))
    |> assign(:chat_svgs, svgs)
    |> assign(:svg_seq, length(svgs))
    |> assign(:zoomed_id, nil)
  end

  @history_roles %{
    "user" => :user,
    "assistant" => :assistant,
    "tool" => :tool,
    "meta" => :meta,
    "error" => :error
  }
  defp history_role(role), do: Map.get(@history_roles, role, :assistant)

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <section class="ic-home relative isolate flex flex-1 flex-col">
        <%!-- Homepage background (Appearance setting): an uploaded image, or a
              hook-owned WebGPU shader canvas that LiveView never patches inside.
              The shader div is keyed by design name, so changing it remounts the
              hook with the new shader. --%>
        <div
          :if={@home_bg.mode == "image"}
          class="ic-home-bg"
          style={"background-image:url('#{@home_bg.image_url}');background-size:cover;background-position:center;"}
          aria-hidden="true"
        >
        </div>
        <div
          :if={@home_bg.mode != "image"}
          id={"home-shader-#{@home_bg.mode}-#{:erlang.phash2({@home_bg.custom, @home_bg.colors})}"}
          phx-hook="SmokeBackground"
          phx-update="ignore"
          data-shader={@home_bg.mode}
          data-custom={to_string(@home_bg.custom)}
          data-colors={Enum.join(@home_bg.colors, ",")}
          class="ic-home-bg"
          aria-hidden="true"
        >
          <canvas data-smoke-canvas></canvas>
        </div>
        <div class="relative z-10 flex min-h-0 flex-1 flex-col space-y-8">
          <div class="flex items-stretch gap-4 border-b-2 border-base-content/20 pb-5">
            <div class="shrink-0 space-y-4">
              <div
                id="bc-heading"
                phx-hook="CrtAberration"
                class="ic-scanlines block w-full max-w-[28rem]"
              >
                <img
                  src={~p"/images/brand/buster-claw-heading.png"}
                  alt="Buster Claw"
                  class="block h-auto w-full"
                />
                <img
                  src={~p"/images/brand/buster-claw-heading.png"}
                  alt=""
                  aria-hidden="true"
                  class="ic-crt-focus h-auto w-full"
                />
              </div>
              <div :if={not @setup_status.complete?} class="pt-1">
                <.link
                  navigate={~p"/setup"}
                  class="inline-flex items-center gap-2 rounded bg-primary px-4 py-2 text-sm font-semibold text-primary-content transition hover:opacity-85"
                >
                  <.icon name="hero-sparkles" class="size-4" />
                  <span :if={@setup_status.completed == 0}>Set up Buster Claw</span>
                  <span :if={@setup_status.completed > 0}>
                    Finish setup · {@setup_status.completed} of {@setup_status.total} complete
                  </span>
                </.link>
              </div>
            </div>
            <BusterClawWeb.HomeWidget.corner_widget
              tab={@widget_tab}
              today={@today}
              days={@calendar_days}
              entries={@trusted_contacts}
            />
          </div>

          <div class="flex min-h-0 flex-1 flex-col gap-2">
            <BusterClawWeb.ChatPanel.chat_tabs chats={@chats} active={@active_chat} />
            <div class="flex min-h-0 flex-1 gap-4">
              <BusterClawWeb.ChatPanel.svg_viewer
                svgs={@chat_svgs}
                zoomed={@zoomed_id}
                open={@svg_viewer_open}
              />
              <BusterClawWeb.ChatPanel.chat_panel
                messages={@chat_messages}
                running={@chat_running}
                thinking={@chat_thinking}
                queue={@chat_queue}
              />
            </div>
          </div>
        </div>
      </section>
    </Layouts.app>
    """
  end

  # Build the current month as a Sunday-aligned 6-week grid (42 cells) for the
  # home corner widget. Each cell carries its date, whether it's in the current
  # month, and its sorted events; the widget highlights today and the
  # CalendarPopover hook reveals a cell's events on hover.
  defp load_calendar_month(socket) do
    today = socket.assigns.today
    first = Date.beginning_of_month(today)
    grid_start = Date.add(first, -(Date.day_of_week(first, :sunday) - 1))

    by_date =
      grid_start
      |> AppCalendar.events_in_range(Date.add(grid_start, 41))
      |> Enum.group_by(& &1.date)
      |> Map.new(fn {date, events} ->
        {date, Enum.sort_by(events, &daily_event_sort_key/1)}
      end)

    days =
      Enum.map(0..41, fn offset ->
        date = Date.add(grid_start, offset)

        %{
          date: date,
          in_month?: date.month == today.month,
          events: Map.get(by_date, date, [])
        }
      end)

    assign(socket, :calendar_days, days)
  end

  defp daily_event_sort_key(%{start_time: nil}), do: {0, ~T[00:00:00]}
  defp daily_event_sort_key(%{start_time: time}), do: {1, time}
end
