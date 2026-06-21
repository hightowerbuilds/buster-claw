defmodule BusterClawWeb.StatusLive do
  use BusterClawWeb, :live_view

  alias BusterClaw.ActivityReport
  alias BusterClaw.Agent.Chat
  alias BusterClaw.Agent.Conversations
  alias BusterClaw.Agent.Transcript, as: AgentTranscript
  alias BusterClaw.Bookmarks
  alias BusterClaw.Calendar, as: AppCalendar
  alias BusterClaw.Dispatch
  alias BusterClaw.LocalTime
  alias BusterClaw.Runtime.Status
  alias BusterClaw.Sentinel
  alias BusterClaw.Setup
  alias BusterClaw.TrustedSenders

  @impl true
  def mount(_params, _session, socket) do
    today = LocalTime.today()

    if connected?(socket) do
      Dispatch.subscribe()
      Sentinel.subscribe()
    end

    {:ok,
     socket
     |> assign(:page_title, "Home")
     |> assign(status: Status.snapshot())
     |> assign(:today, today)
     |> assign(:setup_status, Setup.status())
     |> assign(:trusted_contacts, TrustedSenders.list_entries())
     |> assign(:bookmarks, Bookmarks.list())
     |> assign(:home_tab, "get-started")
     |> assign(:activity_grain, "week")
     |> init_chats()
     |> assign_activity()
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

  defp assign_activity(socket),
    do: assign(socket, :activity, ActivityReport.timeline(socket.assigns.activity_grain))

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

  def handle_event("select_home_tab", %{"tab" => tab}, socket) do
    socket = assign(socket, :home_tab, tab)
    # Bookmarks are added from the in-app browser (outside this LiveView), so
    # re-read them when the Pages tab is opened to pick up new ones.
    socket = if tab == "pages", do: assign(socket, :bookmarks, Bookmarks.list()), else: socket
    {:noreply, socket}
  end

  def handle_event("remove_bookmark", %{"url" => url}, socket) do
    Bookmarks.remove(url)
    {:noreply, assign(socket, :bookmarks, Bookmarks.list())}
  end

  def handle_event("select_activity_grain", %{"grain" => grain}, socket)
      when grain in ["day", "week", "month"],
      do: {:noreply, socket |> assign(:activity_grain, grain) |> assign_activity()}

  def handle_event("quick_chat", %{"prompt" => prompt}, socket),
    do: {:noreply, dispatch_chat(socket, prompt)}

  def handle_event("chat_send", %{"message" => text}, socket) do
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
  def handle_info({:dispatch, _event, _item}, socket), do: {:noreply, assign_activity(socket)}
  def handle_info({:security_event, _event}, socket), do: {:noreply, assign_activity(socket)}

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
      push_msg(socket, role, text)
    else
      update_tab(socket, conv_id, &%{&1 | unread: true})
    end
  end

  defp apply_chat(socket, _conv_id, _other), do: socket

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
          <div class="space-y-4 border-b-2 border-base-content/20 pb-5">
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

          <div class="grid min-h-0 flex-1 gap-6 lg:grid-cols-2">
            <.home_tabs
              tab={@home_tab}
              entries={@trusted_contacts}
              bookmarks={@bookmarks}
              today={@today}
              events={@daily_events}
              activity={@activity}
              grain={@activity_grain}
            />

            <div class="flex min-h-0 flex-col gap-2 self-start">
              <.chat_tabs chats={@chats} active={@active_chat} />
              <.chat_panel
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

  attr :chats, :list, required: true
  attr :active, :string, required: true

  defp chat_tabs(assigns) do
    ~H"""
    <div class="flex items-center gap-1 overflow-x-auto" role="tablist" aria-label="Chats">
      <div
        :for={c <- @chats}
        role="tab"
        aria-selected={to_string(c.id == @active)}
        phx-click="select_chat"
        phx-value-id={c.id}
        class={[
          "group flex shrink-0 cursor-pointer items-center gap-1.5 rounded-t-sm border-2 px-2.5 py-1.5 text-xs transition",
          if(c.id == @active,
            do: "border-base-content/30 bg-base-200 text-base-content",
            else: "border-base-content/15 bg-base-200/40 text-base-content/55 hover:text-base-content"
          )
        ]}
      >
        <span
          :if={c.running}
          class="size-2 shrink-0 animate-pulse rounded-full bg-primary"
          title="Working"
        >
        </span>
        <span
          :if={c.unread and c.id != @active}
          class="size-2 shrink-0 rounded-full bg-warning"
          title="New messages"
        >
        </span>
        <span class="max-w-[10rem] truncate font-medium">{c.title}</span>
        <span
          phx-click="close_chat"
          phx-value-id={c.id}
          title="Close chat"
          class="ml-0.5 grid size-4 shrink-0 place-items-center rounded-sm text-base-content/40 hover:bg-base-content/15 hover:text-primary"
        >
          ×
        </span>
      </div>
      <button
        type="button"
        phx-click="new_chat"
        title="New chat"
        aria-label="New chat"
        class="grid size-7 shrink-0 place-items-center rounded-sm border-2 border-base-content/20 text-base-content/70 transition hover:border-primary hover:text-primary"
      >
        +
      </button>
    </div>
    """
  end

  attr :messages, :list, required: true
  attr :running, :boolean, required: true
  attr :thinking, :any, required: true
  attr :queue, :list, required: true

  defp chat_panel(assigns) do
    ~H"""
    <section
      id="home-agent-chat"
      phx-hook="AgentChat"
      class="ic-panel flex h-[32rem] max-h-[90vh] min-h-0 w-full flex-col overflow-hidden"
    >
      <header class="flex items-center justify-between gap-3 border-b-2 border-base-content/20 px-5 py-4">
        <div>
          <p class="ic-eyebrow">Chat</p>
          <h2 class="font-display text-2xl font-black uppercase tracking-tight">
            Talk to Buster Claw
          </h2>
        </div>
        <.thinking_chip thinking={@thinking} />
      </header>

      <div
        id="agent-chat-log"
        data-chat-log
        class="flex min-h-0 flex-1 flex-col gap-3 overflow-auto p-5"
      >
        <div
          :if={@messages == []}
          class="m-auto max-w-xs text-center text-[17px] text-base-content/55"
        >
          Ask Buster Claw to check your mail, work the queue, or look something up.
          It runs headless Claude — no terminal needed.
        </div>

        <.chat_bubble :for={msg <- @messages} msg={msg} />
      </div>

      <.queue_strip queue={@queue} />

      <form
        phx-submit="chat_send"
        data-chat-form
        class="flex items-end gap-2 border-t-2 border-base-content/20 p-3"
      >
        <textarea
          name="message"
          data-chat-input
          rows="2"
          placeholder="Message Buster Claw…  (Enter to send, Shift+Enter for a new line)"
          class="min-h-0 flex-1 resize-none rounded-sm border-2 border-base-content/25 bg-base-100 px-3 py-2 text-[17px] focus:border-primary focus:outline-none"
        ></textarea>
        <button
          type="submit"
          class="inline-flex items-center gap-2 rounded bg-primary px-4 py-2.5 text-sm font-semibold text-primary-content transition hover:opacity-85"
        >
          <.icon name="hero-paper-airplane" class="size-4" /> Send
        </button>
      </form>

      <div
        data-resize-handle
        role="separator"
        aria-orientation="horizontal"
        title="Drag to resize the chat"
        class="group/resize flex h-2.5 shrink-0 cursor-ns-resize items-center justify-center border-t-2 border-base-content/20 bg-base-200/40 transition hover:bg-base-200"
      >
        <span class="h-1 w-10 rounded-full bg-base-content/25 transition group-hover/resize:bg-primary">
        </span>
      </div>
    </section>
    """
  end

  # Live "thinking" timer in the chat header. `ThinkingTimer` (app.js) ticks the
  # label client-side from data-state/data-ms — no server round-trips per second.
  attr :thinking, :any, required: true

  defp thinking_chip(%{thinking: nil} = assigns), do: ~H""

  defp thinking_chip(assigns) do
    ~H"""
    <span
      id="chat-thinking"
      phx-hook="ThinkingTimer"
      data-state={if(match?({:done, _}, @thinking), do: "done", else: "running")}
      data-ms={with({:done, ms} <- @thinking, do: ms, else: (_ -> nil))}
      class="inline-flex items-center gap-2 font-mono text-xs uppercase tracking-wide text-primary"
    >
      <span class="size-2 animate-pulse rounded-full bg-primary"></span>
      <span data-thinking-label>Thinking…</span>
    </span>
    """
  end

  # The Tetris rail: messages typed while a run is in flight, stacked as tetromino
  # "next pieces" and dispatched one-per-turn as the current run finishes. The
  # front piece is "armed" (hazard border + NEXT tag); pieces are drag-reorderable
  # (QueueRail hook), cancellable, and animate in/out (.ic-piece / phx-remove).
  attr :queue, :list, required: true

  defp queue_strip(%{queue: []} = assigns), do: ~H""

  defp queue_strip(assigns) do
    ~H"""
    <div class="flex flex-col gap-1.5 border-t-2 border-base-content/20 bg-base-200/40 px-3 py-2">
      <p class="ic-eyebrow text-base-content/55">On deck · {length(@queue)}</p>
      <ul id="chat-queue-rail" phx-hook="QueueRail" phx-update="replace" class="flex flex-col gap-1">
        <li
          :for={{item, idx} <- Enum.with_index(@queue)}
          id={"queue-#{item.id}"}
          data-id={item.id}
          draggable="true"
          phx-remove={
            JS.hide(
              transition:
                {"transition-all ease-in duration-200", "opacity-100 scale-100",
                 "opacity-0 scale-95 -translate-y-1"},
              time: 200
            )
          }
          class={[
            "ic-piece group flex cursor-grab items-center gap-2 rounded-sm border-2 bg-base-100 px-2.5 py-1.5 active:cursor-grabbing",
            if(idx == 0,
              do: "border-primary/70 shadow-[2px_2px_0_0] shadow-primary/30",
              else: "border-base-content/20"
            )
          ]}
        >
          <.tetromino index={item.id} />
          <span class="flex-1 truncate text-[15px]">{item.text}</span>
          <span
            :if={idx == 0}
            class="shrink-0 font-mono text-[0.55rem] uppercase tracking-wider text-primary"
          >
            Next
          </span>
          <button
            type="button"
            phx-click="cancel_queued"
            phx-value-id={item.id}
            title="Remove from queue"
            class="shrink-0 text-base-content/40 opacity-0 transition hover:text-error group-hover:opacity-100"
          >
            <.icon name="hero-x-mark" class="size-4" />
          </button>
        </li>
      </ul>
    </div>
    """
  end

  # The seven classic tetrominoes (shape cells in a 4-wide x 2-tall box, + color),
  # picked by id so a piece keeps the same shape for its whole life in the rail.
  @tetrominoes [
    {[{0, 0}, {1, 0}, {2, 0}, {3, 0}], "#22d3ee"},
    {[{0, 0}, {1, 0}, {0, 1}, {1, 1}], "#facc15"},
    {[{0, 0}, {1, 0}, {2, 0}, {1, 1}], "#c084fc"},
    {[{1, 0}, {2, 0}, {0, 1}, {1, 1}], "#4ade80"},
    {[{0, 0}, {1, 0}, {1, 1}, {2, 1}], "#f87171"},
    {[{0, 0}, {0, 1}, {1, 1}, {2, 1}], "#60a5fa"},
    {[{2, 0}, {0, 1}, {1, 1}, {2, 1}], "#fb923c"}
  ]

  attr :index, :integer, required: true

  defp tetromino(assigns) do
    {cells, color} = Enum.at(@tetrominoes, Integer.mod(assigns.index, 7))
    set = MapSet.new(cells)
    grid = for row <- 0..1, col <- 0..3, do: MapSet.member?(set, {col, row})
    assigns = assign(assigns, color: color, grid: grid)

    ~H"""
    <div
      class="grid shrink-0"
      style="grid-template-columns: repeat(4, 5px); grid-template-rows: repeat(2, 5px); gap: 1px;"
      aria-hidden="true"
    >
      <span
        :for={filled <- @grid}
        class="block size-[5px] rounded-[1px]"
        style={if filled, do: "background: #{@color};", else: ""}
      >
      </span>
    </div>
    """
  end

  attr :msg, :map, required: true

  defp chat_bubble(%{msg: %{role: :user}} = assigns) do
    ~H"""
    <div id={"chat-msg-#{@msg.id}"} class="flex justify-end">
      <div class="ic-drop-in max-w-[85%] whitespace-pre-wrap rounded-sm bg-primary px-3 py-2 text-[17px] text-primary-content">
        {@msg.text}
      </div>
    </div>
    """
  end

  defp chat_bubble(%{msg: %{role: :assistant}} = assigns) do
    ~H"""
    <div id={"chat-msg-#{@msg.id}"} class="flex justify-start">
      <div class="max-w-[85%] whitespace-pre-wrap rounded-sm border-2 border-base-content/20 bg-base-100 px-3 py-2 text-[17px]">
        {@msg.text}
      </div>
    </div>
    """
  end

  defp chat_bubble(%{msg: %{role: :tool}} = assigns) do
    ~H"""
    <div
      id={"chat-msg-#{@msg.id}"}
      class="flex items-center gap-2 font-mono text-xs text-base-content/55"
    >
      <.icon name="hero-command-line" class="size-3.5 shrink-0" />
      <span class="truncate">{@msg.text}</span>
    </div>
    """
  end

  defp chat_bubble(%{msg: %{role: :meta}} = assigns) do
    ~H"""
    <div
      id={"chat-msg-#{@msg.id}"}
      class="text-center font-mono text-[0.62rem] uppercase tracking-wide text-base-content/45"
    >
      {@msg.text}
    </div>
    """
  end

  defp chat_bubble(%{msg: %{role: :error}} = assigns) do
    ~H"""
    <div id={"chat-msg-#{@msg.id}"} class="flex justify-start">
      <div class="max-w-[85%] rounded-sm border-2 border-error/50 bg-error/10 px-3 py-2 text-[17px] text-error">
        {@msg.text}
      </div>
    </div>
    """
  end

  attr :tab, :string, required: true
  attr :entries, :list, required: true
  attr :bookmarks, :list, required: true
  attr :today, Date, required: true
  attr :events, :list, required: true
  attr :activity, :map, required: true
  attr :grain, :string, required: true

  @home_tabs [
    {"calendar", "Calendar"},
    {"pages", "Pages"},
    {"contacts", "Contacts"},
    {"activity", "Activity"},
    {"get-started", "Get Started"}
  ]

  defp home_tabs(assigns) do
    assigns = assign(assigns, :tabs, @home_tabs)

    ~H"""
    <div class="flex min-h-0 flex-col gap-3">
      <div
        role="tablist"
        aria-label="Home sections"
        class="flex flex-wrap gap-1 border-b-2 border-base-content/20"
      >
        <button
          :for={{key, label} <- @tabs}
          type="button"
          role="tab"
          aria-selected={to_string(@tab == key)}
          phx-click="select_home_tab"
          phx-value-tab={key}
          class={[
            "-mb-0.5 border-b-2 px-4 py-2 font-display text-sm font-bold uppercase tracking-wide transition",
            if(@tab == key,
              do: "border-primary text-primary",
              else: "border-transparent text-base-content/55 hover:text-base-content"
            )
          ]}
        >
          {label}
        </button>
      </div>

      <div class={["flex min-h-0 flex-1 flex-col", @tab != "get-started" && "hidden"]}>
        <.get_started_panel />
      </div>
      <div class={["flex min-h-0 flex-1 flex-col gap-6", @tab != "pages" && "hidden"]}>
        <.featured_pages_panel />
        <.bookmarks_panel bookmarks={@bookmarks} />
      </div>
      <div class={["flex min-h-0 flex-1 flex-col", @tab != "contacts" && "hidden"]}>
        <BusterClawWeb.TrustedContactsPanel.panel entries={@entries} />
      </div>
      <div class={["flex min-h-0 flex-1 flex-col", @tab != "calendar" && "hidden"]}>
        <.daily_calendar_panel today={@today} events={@events} />
      </div>
      <div class={["flex min-h-0 flex-1 flex-col", @tab != "activity" && "hidden"]}>
        <.activity_panel activity={@activity} grain={@grain} />
      </div>
    </div>
    """
  end

  @quick_prompts [
    "Please read through the introduction and BusterClawWorkspace and give me an explanation.",
    "Explain Buster Claw's Sentinel security layer — what it audits, the safe vs restricted trust tiers, and the gate on irreversible actions. Then exemplify it: run one safe command and one restricted command through the ./buster-claw CLI, show how each is recorded on the audit feed, and point me to the Security tab to watch it live.",
    "Give me an overview of everything you can do across my Google Workspace. Run `./buster-claw commands` to read your full catalog, then summarize the Google capabilities grouped by service — Gmail, Calendar, Drive, Docs, Sheets, Slides, Contacts, and Tasks — noting for each which actions are read-only (safe) versus those that change or delete data and need confirmation.",
    "Check my mail and tell me what needs a reply.",
    "What can you do? Show me a few things to try."
  ]

  defp get_started_panel(assigns) do
    assigns = assign(assigns, :quick_prompts, @quick_prompts)

    ~H"""
    <section
      id="home-get-started"
      class="ic-panel flex flex-col overflow-hidden max-h-full"
    >
      <header class="border-b-2 border-base-content/20 px-5 py-4">
        <p class="ic-eyebrow">Get Started</p>
        <h2 class="font-display text-2xl font-black uppercase tracking-tight">
          Get Started
        </h2>
        <p class="mt-1 text-sm text-base-content/65">
          Three steps and you're talking to Buster Claw (Google Workspace already connected).
        </p>
      </header>

      <div class="flex min-h-0 flex-1 flex-col overflow-auto">
        <details
          id="get-started-steps"
          phx-update="ignore"
          open
          class="group/steps border-b-2 border-base-content/15"
        >
          <summary class="ic-collapse-summary">
            <span class="ic-eyebrow">Setup steps</span>
            <.icon
              name="hero-chevron-down"
              class="size-4 shrink-0 text-base-content/55 transition group-open/steps:rotate-180"
            />
          </summary>

          <ol class="flex flex-col gap-4 px-5 pb-5">
            <li class="flex gap-3">
              <span class="flex size-6 shrink-0 items-center justify-center rounded bg-primary font-mono text-xs font-bold text-primary-content">
                1
              </span>
              <div class="min-w-0">
                <h3 class="font-semibold">Add your trusted contacts</h3>
                <p class="mt-0.5 text-sm text-base-content/65">
                  In the panel below, list the senders Buster Claw may read and reply to.
                  Mail from anyone else is ignored.
                </p>
              </div>
            </li>

            <li class="flex gap-3">
              <span class="flex size-6 shrink-0 items-center justify-center rounded bg-primary font-mono text-xs font-bold text-primary-content">
                2
              </span>
              <div class="min-w-0">
                <h3 class="font-semibold">Install Claude Code</h3>
                <p class="mt-0.5 text-sm text-base-content/65">
                  Buster Claw has no built-in AI — it drives your own Claude Code CLI headlessly.
                  Install it once with
                  <.copy_command command="brew install --cask claude-code" />, then
                  sign in (<span class="font-mono">claude</span> in a terminal).
                </p>
              </div>
            </li>

            <li class="flex gap-3">
              <span class="flex size-6 shrink-0 items-center justify-center rounded bg-primary font-mono text-xs font-bold text-primary-content">
                3
              </span>
              <div class="min-w-0">
                <h3 class="font-semibold">Chat with Buster Claw</h3>
                <p class="mt-0.5 text-sm text-base-content/65">
                  Use the chat on the right. Ask it to triage your inbox, draft a reply, or
                  look something up — it runs headless Claude for you, no terminal needed.
                </p>
              </div>
            </li>
          </ol>
        </details>

        <details id="get-started-quick-chat" phx-update="ignore" open class="group/quick">
          <summary class="ic-collapse-summary">
            <span class="ic-eyebrow">Quick chat</span>
            <.icon
              name="hero-chevron-down"
              class="size-4 shrink-0 text-base-content/55 transition group-open/quick:rotate-180"
            />
          </summary>

          <div class="flex flex-col gap-2 px-5 pb-5">
            <button
              :for={prompt <- @quick_prompts}
              type="button"
              phx-click="quick_chat"
              phx-value-prompt={prompt}
              class="group flex items-center gap-3 rounded-sm border-2 border-base-content/25 px-3 py-2.5 text-left text-sm transition hover:border-primary hover:text-primary"
            >
              <.icon name="hero-chat-bubble-left-right" class="size-5 shrink-0 text-base-content/55" />
              <span class="min-w-0 flex-1">{prompt}</span>
              <.icon name="hero-arrow-right" class="size-4 shrink-0 text-base-content/40" />
            </button>
          </div>
        </details>
      </div>
    </section>
    """
  end

  attr :activity, :map, required: true
  attr :grain, :string, required: true

  @grain_window %{"day" => "Last 14 days", "week" => "Last 12 weeks", "month" => "Last 12 months"}
  @grain_buttons [{"day", "Daily"}, {"week", "Weekly"}, {"month", "Monthly"}]

  defp activity_panel(assigns) do
    assigns =
      assigns
      |> assign(:window_label, Map.fetch!(@grain_window, assigns.grain))
      |> assign(:grain_buttons, @grain_buttons)

    ~H"""
    <section id="home-activity" class="ic-panel flex min-h-0 flex-1 flex-col overflow-hidden">
      <header class="flex flex-wrap items-start justify-between gap-3 border-b-2 border-base-content/20 px-5 py-4">
        <div>
          <p class="ic-eyebrow">Activity</p>
          <h2 class="font-display text-2xl font-black uppercase tracking-tight">
            Activity
          </h2>
          <p class="mt-1 text-sm text-base-content/65">
            Straight from the audit trail · {@window_label}
          </p>
        </div>
        <div role="group" aria-label="Granularity" class="flex gap-1">
          <button
            :for={{key, label} <- @grain_buttons}
            type="button"
            phx-click="select_activity_grain"
            phx-value-grain={key}
            aria-pressed={to_string(@grain == key)}
            class={[
              "rounded-sm border-2 px-2.5 py-1 text-xs font-semibold uppercase tracking-wide transition",
              if(@grain == key,
                do: "border-primary text-primary",
                else: "border-base-content/25 text-base-content/55 hover:text-base-content"
              )
            ]}
          >
            {label}
          </button>
        </div>
      </header>

      <div class="flex min-h-0 flex-1 flex-col gap-5 overflow-auto p-5">
        <dl class="grid grid-cols-4 gap-2">
          <.shift_stat label="Runs" value={@activity.totals.runs} />
          <.shift_stat label="Commands" value={@activity.totals.commands} />
          <.shift_stat label="Handled" value={@activity.totals.handled} />
          <.shift_stat label="Open" value={@activity.totals.open} />
        </dl>

        <.activity_chart buckets={@activity.buckets} />
      </div>
    </section>
    """
  end

  attr :buckets, :list, required: true

  defp activity_chart(assigns) do
    max =
      assigns.buckets
      |> Enum.flat_map(&[&1.runs, &1.commands])
      |> Enum.max(fn -> 0 end)
      |> max(1)

    slot = 100 / max(length(assigns.buckets), 1)
    assigns = assign(assigns, max: max, slot: slot)

    ~H"""
    <div>
      <div class="mb-2 flex items-center gap-4 text-xs text-base-content/60">
        <span class="inline-flex items-center gap-1">
          <span class="size-2 rounded-sm bg-primary"></span> Runs
        </span>
        <span class="inline-flex items-center gap-1">
          <span class="size-2 rounded-sm bg-base-content/40"></span> Commands
        </span>
      </div>

      <svg
        viewBox="0 0 100 90"
        preserveAspectRatio="none"
        class="h-36 w-full"
        role="img"
        aria-label="Runs and commands over time"
      >
        <line
          x1="0"
          y1="88"
          x2="100"
          y2="88"
          class="stroke-current text-base-content/20"
          stroke-width="0.3"
        />
        <%= for {b, i} <- Enum.with_index(@buckets) do %>
          <rect
            x={i * @slot + @slot * 0.15}
            y={88 - bar_h(b.runs, @max)}
            width={@slot * 0.3}
            height={bar_h(b.runs, @max)}
            class="fill-current text-primary"
          />
          <rect
            x={i * @slot + @slot * 0.52}
            y={88 - bar_h(b.commands, @max)}
            width={@slot * 0.3}
            height={bar_h(b.commands, @max)}
            class="fill-current text-base-content/40"
          />
        <% end %>
      </svg>

      <div class="mt-1 flex">
        <span
          :for={b <- @buckets}
          class="flex-1 truncate text-center font-mono text-[0.55rem] text-base-content/45"
        >
          {b.label}
        </span>
      </div>
    </div>
    """
  end

  defp bar_h(value, max), do: value / max * 80

  attr :label, :string, required: true
  attr :value, :integer, required: true

  defp shift_stat(assigns) do
    ~H"""
    <div class="rounded-sm border-2 border-base-content/20 px-2 py-2 text-center">
      <p class="font-display text-2xl font-black tabular-nums leading-none">{@value}</p>
      <p class="mt-1 text-[0.62rem] font-semibold uppercase tracking-wide text-base-content/55">
        {@label}
      </p>
    </div>
    """
  end

  defp featured_pages_panel(assigns) do
    ~H"""
    <section id="home-featured-pages" class="ic-panel">
      <header class="border-b-2 border-base-content/20 px-5 py-4">
        <p class="ic-eyebrow">Featured Pages</p>
        <h2 class="font-display text-2xl font-black uppercase tracking-tight">
          Featured Pages
        </h2>
      </header>

      <div class="flex flex-col gap-3 p-5">
        <.featured_page_link
          href={~p"/browse?#{[url: "/pages/MANUAL.html"]}"}
          icon="hero-book-open"
          title="Manual"
          blurb="Open the Buster Claw manual in the browser"
        />
        <.featured_page_link
          href={~p"/browse?#{[url: "/pages/financial-informant.html"]}"}
          icon="hero-chart-bar"
          title="Financial Informant"
          blurb="Look up a ticker — quote, fundamentals, filings, news"
        />
      </div>
    </section>
    """
  end

  attr :bookmarks, :list, required: true

  defp bookmarks_panel(assigns) do
    ~H"""
    <section id="home-bookmarks" class="ic-panel flex min-h-0 flex-col overflow-hidden">
      <header class="flex items-start justify-between gap-3 border-b-2 border-base-content/20 px-5 py-4">
        <div>
          <p class="ic-eyebrow">Bookmarks</p>
          <h2 class="font-display text-2xl font-black uppercase tracking-tight">
            Bookmarks
          </h2>
          <p class="mt-1 text-sm text-base-content/65">
            Saved from the in-app browser. Opens the page in the Browser.
          </p>
        </div>
        <span class="shrink-0 rounded bg-base-200 px-2 py-0.5 font-mono text-xs font-bold text-base-content/60">
          {length(@bookmarks)}
        </span>
      </header>

      <div class="flex min-h-0 flex-1 flex-col gap-2 overflow-auto p-5">
        <div
          :for={bm <- @bookmarks}
          id={"home-bookmark-#{bm["url"]}"}
          class="group flex items-center gap-2 rounded-sm border-2 border-base-content/25 transition hover:border-primary"
        >
          <.link
            navigate={~p"/browse?#{[url: bm["url"]]}"}
            class="flex min-w-0 flex-1 items-center gap-3 px-3 py-2.5 hover:text-primary"
          >
            <.icon name="hero-bookmark" class="size-5 shrink-0 text-base-content/55" />
            <span class="min-w-0">
              <span class="block truncate font-semibold">{bm["label"]}</span>
              <span class="block truncate font-mono text-xs text-base-content/55">{bm["url"]}</span>
            </span>
          </.link>
          <button
            type="button"
            phx-click="remove_bookmark"
            phx-value-url={bm["url"]}
            data-confirm={"Remove bookmark for #{bm["label"]}?"}
            aria-label={"Remove bookmark #{bm["label"]}"}
            class="mr-2 shrink-0 rounded border border-base-content/20 px-2 py-1 font-mono text-[0.65rem] uppercase tracking-wide text-base-content/60 transition hover:border-error hover:text-error"
          >
            Remove
          </button>
        </div>

        <div
          :if={@bookmarks == []}
          class="rounded border border-dashed border-base-300 px-4 py-8 text-center text-sm text-base-content/60"
        >
          <p class="font-semibold text-base-content/80">No bookmarks yet.</p>
          <p class="mt-1">Save a page from the in-app browser's “+ Bookmark” button.</p>
        </div>
      </div>
    </section>
    """
  end

  attr :href, :string, required: true
  attr :icon, :string, required: true
  attr :title, :string, required: true
  attr :blurb, :string, required: true

  defp featured_page_link(assigns) do
    ~H"""
    <.link
      navigate={@href}
      class="group flex items-center gap-3 rounded-sm border-2 border-base-content/25 px-3 py-2.5 transition hover:border-primary hover:text-primary"
    >
      <.icon name={@icon} class="size-5 shrink-0 text-base-content/60" />
      <span class="min-w-0">
        <span class="block font-semibold">{@title}</span>
        <span class="block text-xs text-base-content/60">{@blurb}</span>
      </span>
      <.icon name="hero-chevron-right" class="ml-auto size-4 shrink-0 text-base-content/40" />
    </.link>
    """
  end

  attr :command, :string, required: true

  defp copy_command(assigns) do
    ~H"""
    <span class="inline-flex items-center gap-1 align-middle">
      <code class="rounded bg-base-200 px-1.5 py-0.5 font-mono text-[0.8rem]">{@command}</code>
      <button
        type="button"
        data-terminal-command-copy={@command}
        aria-label={"Copy command: #{@command}"}
        title="Copy"
        class="inline-flex shrink-0 items-center gap-1 rounded-sm border border-base-content/20 px-1.5 py-0.5 font-mono text-[0.62rem] font-semibold uppercase tracking-wide text-base-content/60 transition hover:border-primary hover:text-primary"
      >
        <.icon name="hero-clipboard-document" class="size-3" />
        <span data-terminal-command-copy-label>Copy</span>
      </button>
    </span>
    """
  end

  attr :today, Date, required: true
  attr :events, :list, required: true

  defp daily_calendar_panel(assigns) do
    ~H"""
    <section id="home-daily-calendar" class="ic-panel self-start">
      <header class="flex flex-wrap items-center justify-between gap-3 border-b-2 border-base-content/20 px-5 py-4">
        <div>
          <p class="ic-eyebrow">Today's Calendar</p>
          <h2 class="font-display text-2xl font-black uppercase tracking-tight">
            {Elixir.Calendar.strftime(@today, "%A, %B %-d")}
          </h2>
        </div>

        <.link
          navigate={~p"/calendar"}
          class="rounded-sm border-2 border-base-content/25 px-3 py-2 font-mono text-xs uppercase tracking-wide text-base-content/70 transition hover:border-primary hover:text-primary"
        >
          Open Calendar
        </.link>
      </header>

      <div class="p-5">
        <ol :if={@events != []} class="divide-y divide-base-300 rounded border border-base-300">
          <li
            :for={event <- @events}
            id={"home-event-#{event.id}-#{Date.to_iso8601(event.date)}"}
            class="grid gap-3 px-4 py-3 text-sm sm:grid-cols-[7rem_minmax(0,1fr)] sm:items-start"
          >
            <div class="font-mono text-xs font-semibold uppercase tracking-wide text-primary">
              {event_time_label(event)}
            </div>
            <div class="min-w-0">
              <div class="flex min-w-0 items-center gap-2">
                <span class={["size-2.5 shrink-0 rounded-full", event_dot_class(event.color)]} />
                <h3 class="truncate font-semibold">{event.title}</h3>
                <span
                  :if={event.frequency}
                  class="rounded-full bg-base-200 px-2 py-0.5 text-xs font-semibold text-base-content/60"
                >
                  {event.frequency}
                </span>
              </div>
              <p
                :if={event.notes not in [nil, ""]}
                class="mt-1 line-clamp-2 text-sm text-base-content/60"
              >
                {event.notes}
              </p>
            </div>
          </li>
        </ol>

        <div
          :if={@events == []}
          class="rounded border border-dashed border-base-300 px-4 py-10 text-center text-sm text-base-content/60"
        >
          Nothing scheduled today.
        </div>
      </div>
    </section>
    """
  end

  defp event_time_label(%{start_time: nil}), do: "All day"

  defp event_time_label(%{start_time: start_time, end_time: nil}),
    do: format_event_time(start_time)

  defp event_time_label(%{start_time: start_time, end_time: end_time}),
    do: "#{format_event_time(start_time)}-#{format_event_time(end_time)}"

  defp format_event_time(%Time{} = time), do: Elixir.Calendar.strftime(time, "%H:%M")

  defp event_dot_class(color) do
    case color do
      "work" -> "bg-info"
      "personal" -> "bg-secondary"
      "social" -> "bg-accent"
      "travel" -> "bg-warning"
      "health" -> "bg-success"
      "holiday" -> "bg-error"
      _ -> "bg-base-content/40"
    end
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
