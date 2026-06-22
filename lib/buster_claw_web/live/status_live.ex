defmodule BusterClawWeb.StatusLive do
  use BusterClawWeb, :live_view

  alias BusterClaw.Agent.Chat
  alias BusterClaw.Agent.Conversations
  alias BusterClaw.Agent.Transcript, as: AgentTranscript
  alias BusterClaw.Calendar, as: AppCalendar
  alias BusterClaw.LocalTime
  alias BusterClaw.Runtime.Status
  alias BusterClaw.Setup
  alias BusterClaw.TrustedSenders

  @impl true
  def mount(_params, _session, socket) do
    today = LocalTime.today()

    {:ok,
     socket
     |> assign(:page_title, "Home")
     |> assign(status: Status.snapshot())
     |> assign(:today, today)
     |> assign(:setup_status, Setup.status())
     |> assign(:trusted_contacts, TrustedSenders.list_entries())
     # Header widget: which sub-tab is showing (Get Started / Calendar / Contacts).
     |> assign(:widget_tab, "get-started")
     |> init_chats()
     |> load_daily_events()}
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
      when tab in ["get-started", "calendar", "contacts"],
      do: {:noreply, assign(socket, :widget_tab, tab)}

  def handle_event("quick_chat", %{"prompt" => prompt}, socket),
    do: {:noreply, dispatch_chat(socket, prompt)}

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

    {:noreply, socket}
  end

  def handle_event("close_chat", %{"id" => id}, socket) do
    Chat.stop(id)
    Conversations.close(id)
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
    |> update(:chat_messages, &(&1 ++ [msg]))
  end

  defp load_chat_history(socket, conv_id) do
    messages =
      conv_id
      |> AgentTranscript.recent(limit: 50)
      |> Enum.with_index(1)
      |> Enum.map(fn {row, i} -> %{id: i, role: history_role(row.role), text: row.content} end)

    socket
    |> assign(:chat_messages, messages)
    |> assign(:chat_seq, length(messages))
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
        <div class="ic-home-bg" aria-hidden="true"></div>
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
              events={@daily_events}
              entries={@trusted_contacts}
            />
          </div>

          <div class="flex min-h-0 flex-1 flex-col gap-2">
            <BusterClawWeb.ChatPanel.chat_tabs chats={@chats} active={@active_chat} />
            <BusterClawWeb.ChatPanel.chat_panel
              messages={@chat_messages}
              running={@chat_running}
              thinking={@chat_thinking}
              queue={@chat_queue}
            />
          </div>
        </div>
      </section>
    </Layouts.app>
    """
  end

  defp load_daily_events(socket) do
    today = socket.assigns.today

    events =
      today
      |> AppCalendar.events_in_range(today)
      |> Enum.sort_by(&daily_event_sort_key/1)

    assign(socket, :daily_events, events)
  end

  defp daily_event_sort_key(%{start_time: nil}), do: {0, ~T[00:00:00]}
  defp daily_event_sort_key(%{start_time: time}), do: {1, time}
end
