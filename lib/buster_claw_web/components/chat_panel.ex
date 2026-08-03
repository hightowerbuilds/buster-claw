defmodule BusterClawWeb.ChatPanel do
  @moduledoc """
  Chat rendering: the conversation tabs, Home's docked chat panel, and Trading's
  floating chat windows — plus the pieces all three share (transcript bubbles,
  thinking timer, on-deck queue rail, composer).

  Presentation only — every event (`select_chat`, `close_chat`, `new_chat`,
  `chat_send`, `cut_run`, `cancel_queued`, …) is handled by the parent LiveView,
  which owns the conversation state. `StatusLive` owns Home's; `TradingLive`
  owns the Trading page's.

  The two surfaces differ in one way that shapes everything here: Home has
  exactly one chat on screen and Trading can have several. So the shared pieces
  take an explicit DOM id and, where they push an event, an explicit
  conversation — both defaulted for Home, where there is nothing to disambiguate.
  """
  use BusterClawWeb, :html

  attr :chats, :list, required: true
  attr :active, :string, required: true

  def chat_tabs(assigns) do
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

  attr :id, :string, required: true, doc: "unique DOM id — several windows are on screen at once"

  attr :conv, :string,
    required: true,
    doc: "conversation id; every event this window pushes names it"

  attr :title, :string, required: true
  attr :kind, :string, required: true, doc: "typed Trading conversation kind"
  attr :index, :integer, default: 0, doc: "render order, used to cascade default positions"
  attr :messages, :list, required: true, doc: "[{dom_id, msg}] — a plain list, not a stream"
  attr :seq, :integer, required: true
  attr :running, :boolean, required: true
  attr :thinking, :any, required: true
  attr :queue, :list, required: true
  attr :minimized, :boolean, default: false
  attr :focused, :boolean, default: false

  attr :docked, :boolean,
    default: false,
    doc: "docked windows sit in the tab's flow instead of floating over it"

  attr :embedded, :boolean,
    default: false,
    doc: "panel-owned chats sit in flow without changing the persisted dock state"

  attr :agent_cli_missing, :boolean, default: false
  attr :empty_message, :string, required: true
  attr :placeholder, :string, required: true
  slot :pinned

  @doc """
  A floating, translucent chat window.

  Unlike `chat_panel/1` there can be several of these on screen at once, so
  everything that was implicit there is explicit here: the DOM id, the queue
  rail's id, the thinking chip's id, and — most importantly — the conversation
  on every event. A `cut_run` with no conversation is unambiguous when one chat
  exists and actively dangerous when three do.

  Translucency is the point of the window rather than decoration: these sit on
  top of a full-tab dashboard, and the operator needs to keep reading the
  numbers underneath while a run is going. The focused window is more opaque
  than the ones behind it, which is what makes a stack of them legible.

  It renders a plain list rather than a LiveView stream. Streams are keyed per
  name and there is no clean way to have one per conversation; transcripts are
  capped at 200 messages and only a few windows are ever open, so the parent
  holds them in assigns and hands them over already paired with their dom ids.
  """
  def chat_window(assigns) do
    assigns = assign(assigns, :flow, assigns.docked or assigns.embedded)

    ~H"""
    <section
      id={@id}
      phx-hook="ChatWindow"
      data-conv={@conv}
      data-index={@index}
      data-running={to_string(@running)}
      data-minimized={to_string(@minimized)}
      data-docked={to_string(@flow)}
      data-seq={@seq}
      phx-click={not @flow && "trading_focus_chat"}
      phx-value-id={@conv}
      class={
        [
          "ic-panel flex flex-col overflow-hidden border-2",
          # Docked: it IS the tab, so it takes the flow and drops the translucency
          # that only earned its place over a dashboard.
          if(@flow,
            do: "min-h-0 border-base-content/25 bg-base-100",
            else: "fixed z-30 backdrop-blur-md transition-colors"
          ),
          # Collapsed in flow, the header is the whole window. It has to stop
          # growing as well as hide its body, or the panel above it gains
          # nothing — which is the entire point of collapsing it.
          @flow and if(@minimized, do: "shrink-0", else: "flex-1"),
          not @flow and
            if(@focused,
              do: "border-primary/60 bg-base-100/95 shadow-[4px_4px_0_0_oklch(var(--bc)/0.25)]",
              else: "border-base-content/25 bg-base-100/75 shadow-[3px_3px_0_0_oklch(var(--bc)/0.12)]"
            )
        ]
      }
    >
      <header
        data-window-drag={not @flow}
        class={[
          "flex shrink-0 items-center gap-2 border-b-2 border-base-content/20 bg-base-200/60 px-2 py-1.5",
          not @flow and "cursor-grab active:cursor-grabbing"
        ]}
      >
        <span class="min-w-0 flex-1 truncate font-mono text-xs font-bold">{@title}</span>

        <%!-- What this conversation is pointed at, and the control to change it.
              Retyping restarts the session, so it is a decision, not a filter —
              which is why the current one is written, not just highlighted. --%>
        <div class="flex shrink-0 items-center gap-px" role="group" aria-label="Chat kind">
          <button
            :for={
              {k, badge} <- [
                {"chat", "CHAT"},
                {"robinhood", "RH"},
                {"research", "RES"},
                {"chartbuild", "CHART"}
              ]
            }
            type="button"
            phx-click="trading_set_kind"
            phx-value-id={@conv}
            phx-value-kind={k}
            title={"Point this chat at #{k}"}
            aria-pressed={to_string(@kind == k)}
            class={[
              "border px-1 font-mono text-[0.55rem] font-black uppercase tracking-wider transition",
              kind_button_class(@kind, k)
            ]}
          >
            {badge}
          </button>
        </div>

        <.thinking_chip thinking={@thinking} id={"#{@id}-thinking"} />

        <button
          :if={@running}
          type="button"
          phx-click="cut_run"
          phx-value-conv={@conv}
          title="Stop the model"
          class="shrink-0 rounded border-2 border-error/50 px-1.5 py-0.5 font-mono text-[0.55rem] uppercase tracking-wide text-error transition hover:bg-error/10"
        >
          Stop
        </button>
        <%!-- A panel-owned chat cannot be floated, minimised to the desktop, or
              closed — it is half of its own tab. Collapsing is the one size
              gesture it can offer, and it reuses the floating window's
              `minimized` state rather than inventing a second flag. --%>
        <button
          :if={@embedded}
          type="button"
          phx-click="trading_minimize_chat"
          phx-value-id={@conv}
          title={
            if @minimized, do: "Show the chat", else: "Collapse the chat to give the panel more room"
          }
          aria-expanded={to_string(not @minimized)}
          aria-controls={"#{@id}-body"}
          class="grid size-5 shrink-0 place-items-center rounded-sm font-mono text-base-content/50 hover:bg-base-content/15 hover:text-base-content"
        >
          {if @minimized, do: "▴", else: "▾"}
        </button>
        <button
          :if={@docked and not @embedded}
          type="button"
          phx-click="trading_float_chat"
          phx-value-id={@conv}
          title="Float this chat back over the panel"
          class="grid size-5 shrink-0 place-items-center rounded-sm font-mono text-base-content/50 hover:bg-base-content/15 hover:text-base-content"
        >
          ⇱
        </button>
        <button
          :if={not @flow}
          type="button"
          phx-click="trading_minimize_chat"
          phx-value-id={@conv}
          title={if @minimized, do: "Expand", else: "Minimise"}
          class="grid size-5 shrink-0 place-items-center rounded-sm font-mono text-base-content/50 hover:bg-base-content/15 hover:text-base-content"
        >
          {if @minimized, do: "▢", else: "—"}
        </button>
        <button
          :if={not @flow}
          type="button"
          phx-click="trading_toggle_chat"
          phx-value-id={@conv}
          title="Close this chat window"
          class="grid size-5 shrink-0 place-items-center rounded-sm font-mono text-base-content/50 hover:bg-base-content/15 hover:text-primary"
        >
          ×
        </button>
      </header>

      <div :if={not @minimized} id={"#{@id}-body"} class="flex min-h-0 flex-1 flex-col">
        <div
          id={"#{@id}-log"}
          data-chat-log
          class="flex min-h-0 flex-1 flex-col gap-3 overflow-auto p-4"
        >
          <div
            :if={@messages == []}
            class="m-auto max-w-xs text-center text-[15px] text-base-content/55"
          >
            {@empty_message}
          </div>
          <.chat_bubble :for={{dom_id, msg} <- @messages} id={dom_id} msg={msg} />
        </div>

        <.queue_strip queue={@queue} id={"#{@id}-queue"} conv={@conv} />

        <div :if={@pinned != []} class="border-t-2 border-base-content/20">
          {render_slot(@pinned)}
        </div>

        <div
          :if={@agent_cli_missing}
          class="border-t-2 border-warning/60 bg-warning/10 px-3 py-2 text-[13px]"
        >
          <span class="font-semibold">No agent CLI found.</span>
          Install Claude Code and run <code class="font-mono">claude login</code>.
        </div>

        <form
          phx-submit="chat_send"
          data-chat-form
          class="flex shrink-0 items-end gap-2 border-t-2 border-base-content/20 p-2"
        >
          <input type="hidden" name="conv" value={@conv} />
          <textarea
            name="message"
            data-chat-input
            rows="2"
            disabled={@agent_cli_missing}
            placeholder={if @agent_cli_missing, do: "Install Claude Code to chat", else: @placeholder}
            class="min-h-0 flex-1 resize-none rounded-sm border-2 border-base-content/25 bg-base-100/80 px-2 py-1.5 text-[15px] focus:border-primary focus:outline-none disabled:opacity-50"
          ></textarea>
          <button
            type="submit"
            disabled={@agent_cli_missing}
            class="shrink-0 rounded bg-primary px-3 py-2 text-xs font-semibold text-primary-content transition hover:opacity-85 disabled:opacity-40"
          >
            Send
          </button>
        </form>

        <div
          :if={not @flow}
          data-window-resize
          title="Drag to resize"
          class="absolute bottom-0 right-0 size-4 cursor-nwse-resize"
        >
          <span class="absolute bottom-1 right-1 size-2 border-b-2 border-r-2 border-base-content/40">
          </span>
        </div>
      </div>
    </section>
    """
  end

  defp kind_button_class(kind, option) when kind != option,
    do: "border-base-content/20 text-base-content/35 hover:text-base-content"

  defp kind_button_class(_kind, "research"),
    do: "border-info/60 bg-info/10 text-info"

  defp kind_button_class(_kind, "chartbuild"),
    do: "border-secondary/60 bg-secondary/10 text-secondary"

  defp kind_button_class(_kind, "chat"),
    do: "border-base-content/50 bg-base-content/10 text-base-content"

  defp kind_button_class(_kind, _robinhood),
    do: "border-success/60 bg-success/10 text-success"

  attr :messages, :any, required: true, doc: "the parent LiveView's chat_messages stream"
  attr :seq, :integer, required: true, doc: "message counter — see data-seq below"
  attr :running, :boolean, required: true
  attr :thinking, :any, required: true
  attr :queue, :list, required: true
  attr :agent_cli_missing, :boolean, default: false

  attr :empty_message, :string,
    default:
      "Ask Buster Claw to check your mail, work the queue, or look something up. It runs headless Claude — no terminal needed."

  slot :pinned,
    doc:
      "rendered between the log and the composer — a pending action the caller wants answered " <>
        "before the next message, kept in view while the log scrolls"

  attr :placeholder, :string,
    default: "Message Buster Claw…  (Enter to send, Shift+Enter for a new line)"

  def chat_panel(assigns) do
    ~H"""
    <section
      id="home-agent-chat"
      phx-hook="AgentChat"
      data-running={to_string(@running)}
      data-seq={@seq}
      class="ic-panel flex min-h-0 w-full flex-1 flex-col overflow-hidden"
    >
      <header class="flex items-center justify-between gap-3 border-b-2 border-base-content/20 px-5 py-4">
        <div>
          <p class="ic-eyebrow">Chat</p>
        </div>
        <div class="flex items-center gap-3">
          <button
            id="voice-toggle"
            phx-hook="VoiceToggle"
            phx-update="ignore"
            type="button"
            aria-pressed="false"
            title="Toggle spoken replies"
            class="inline-flex items-center gap-1.5 rounded border-2 border-base-content/20 px-2.5 py-1 font-mono text-[0.62rem] uppercase tracking-wide text-base-content/40 transition"
          >
            <.icon name="hero-speaker-wave" class="size-3.5" />
            <span data-voice-label>Voice off</span>
          </button>
          <.thinking_chip thinking={@thinking} />
          <button
            :if={@running}
            type="button"
            phx-click="cut_run"
            title="Stop the model"
            class="inline-flex items-center gap-1.5 rounded border-2 border-error/50 px-2.5 py-1 font-mono text-[0.62rem] uppercase tracking-wide text-error transition hover:bg-error/10"
          >
            <.icon name="hero-stop" class="size-3.5" /> Stop
            <kbd class="rounded-sm border border-error/40 px-1 text-[0.55rem] leading-none">Esc</kbd>
          </button>
        </div>
      </header>

      <div
        id="agent-chat-log"
        data-chat-log
        phx-update="stream"
        class="flex min-h-0 flex-1 flex-col gap-3 overflow-auto p-5"
      >
        <%!-- Stream-managed container: the empty state is a static child shown
              via CSS only when it's the sole child (the stream idiom — the
              server no longer knows the collection size). data-seq on the
              section bumps per message so the AgentChat hook's updated()
              (scroll-to-bottom) is guaranteed to fire on stream inserts. --%>
        <div
          id="agent-chat-empty"
          class="m-auto hidden max-w-xs text-center text-[17px] text-base-content/55 only:block"
        >
          {@empty_message}
        </div>

        <.chat_bubble :for={{dom_id, msg} <- @messages} id={dom_id} msg={msg} />
      </div>

      <.queue_strip queue={@queue} />

      <div :if={@pinned != []} class="border-t-2 border-base-content/20">
        {render_slot(@pinned)}
      </div>

      <div
        :if={@agent_cli_missing}
        id="agent-cli-missing"
        class="border-t-2 border-warning/60 bg-warning/10 px-3 py-2 text-[15px]"
      >
        <span class="font-semibold">No agent CLI found.</span>
        Chat runs your own Claude Code headlessly — install it
        (<code phx-no-curly-interpolation class="font-mono text-[13px]">npm install -g @anthropic-ai/claude-code</code>),
        run <code class="font-mono text-[13px]">claude login</code>
        in a terminal, then reload this page.
      </div>

      <form
        phx-submit="chat_send"
        data-chat-form
        class="flex items-end gap-2 border-t-2 border-base-content/20 p-3"
      >
        <div class="relative flex-1">
          <textarea
            name="message"
            data-chat-input
            rows="2"
            disabled={@agent_cli_missing}
            placeholder={
              if @agent_cli_missing,
                do: "Install Claude Code to chat",
                else: @placeholder
            }
            class="min-h-0 w-full resize-none rounded-sm border-2 border-base-content/25 bg-base-100 px-3 py-2 text-[17px] focus:border-primary focus:outline-none disabled:opacity-50"
          ></textarea>
        </div>

        <button
          type="submit"
          disabled={@agent_cli_missing}
          class="inline-flex items-center gap-2 rounded bg-primary px-4 py-2.5 text-sm font-semibold text-primary-content transition hover:opacity-85 disabled:opacity-40 disabled:hover:opacity-40"
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

  @doc """
  Full-screen SVG preview modal. There is no persistent viewer — a drawing lives
  in the transcript as a "View drawing" link on its message, which opens this
  modal (the `zoom_svg` event). `svgs` is the session's `%{id, svg}` list and
  `zoomed` is the id being shown (nil = closed). ← / → page through the whole set;
  Esc or the backdrop closes.
  """
  attr :svgs, :list, required: true
  attr :zoomed, :any, required: true

  def svg_modal(assigns) do
    assigns =
      assign(assigns, :zoom_idx, Enum.find_index(assigns.svgs, &(&1.id == assigns.zoomed)))

    ~H"""
    <%!-- Full-screen modal. The backdrop button closes; the image sits above it
            (pointer-events-auto) so clicking it doesn't close. ← / → page through
            the viewer, Esc closes. --%>
    <div :if={@zoom_idx} class="fixed inset-0 z-50" phx-window-keydown="zoom_key">
      <button
        type="button"
        phx-click="close_zoom"
        aria-label="Close full-screen"
        class="absolute inset-0 h-full w-full cursor-zoom-out bg-black/80 backdrop-blur"
      >
      </button>
      <div class="pointer-events-none absolute inset-0 grid place-items-center p-8">
        <div class="ic-svg-modal pointer-events-auto overflow-auto rounded-sm border-2 border-base-content/30 bg-base-100 p-4 shadow-2xl">
          {Phoenix.HTML.raw(Enum.at(@svgs, @zoom_idx).svg)}
        </div>
      </div>

      <button
        type="button"
        phx-click="close_zoom"
        aria-label="Close full-screen"
        class="absolute right-4 top-4 z-10 grid size-10 place-items-center rounded-sm border-2 border-base-content/40 bg-base-100 text-xl leading-none transition hover:border-primary hover:text-primary"
      >
        ×
      </button>

      <button
        :if={length(@svgs) > 1}
        type="button"
        phx-click="zoom_nav"
        phx-value-dir="prev"
        disabled={@zoom_idx == 0}
        aria-label="Previous drawing"
        class="pointer-events-auto absolute left-4 top-1/2 z-10 grid size-11 -translate-y-1/2 place-items-center rounded-full border-2 border-base-content/40 bg-base-100 text-2xl leading-none transition hover:border-primary hover:text-primary disabled:cursor-not-allowed disabled:opacity-30"
      >
        ‹
      </button>
      <button
        :if={length(@svgs) > 1}
        type="button"
        phx-click="zoom_nav"
        phx-value-dir="next"
        disabled={@zoom_idx == length(@svgs) - 1}
        aria-label="Next drawing"
        class="pointer-events-auto absolute right-4 top-1/2 z-10 grid size-11 -translate-y-1/2 place-items-center rounded-full border-2 border-base-content/40 bg-base-100 text-2xl leading-none transition hover:border-primary hover:text-primary disabled:cursor-not-allowed disabled:opacity-30"
      >
        ›
      </button>
      <div
        :if={length(@svgs) > 1}
        class="pointer-events-none absolute bottom-4 left-1/2 z-10 -translate-x-1/2 rounded-sm border-2 border-base-content/20 bg-base-100 px-2 py-1 font-mono text-xs text-base-content/70"
      >
        {@zoom_idx + 1} / {length(@svgs)}
      </div>
    </div>
    """
  end

  # Live "thinking" timer in the chat header. `ThinkingTimer` (app.js) ticks the
  # label client-side from data-state/data-ms — no server round-trips per second.
  attr :thinking, :any, required: true
  attr :id, :string, default: "chat-thinking"

  defp thinking_chip(%{thinking: nil} = assigns), do: ~H""

  defp thinking_chip(assigns) do
    ~H"""
    <span
      id={@id}
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

  # The queue rail: messages typed while a run is in flight, stacked as "next
  # pieces" and dispatched one-per-turn as the current run finishes. The
  # front piece is "armed" (hazard border + NEXT tag); pieces are drag-reorderable
  # (QueueRail hook), cancellable, and animate in/out (.ic-piece / phx-remove).
  attr :queue, :list, required: true
  attr :id, :string, default: "chat-queue-rail"
  # nil on Home, where there is one chat and `cancel_queued` needs no scope. The
  # Trading windows pass theirs, because several queues can be on screen at once.
  attr :conv, :string, default: nil

  defp queue_strip(%{queue: []} = assigns), do: ~H""

  defp queue_strip(assigns) do
    ~H"""
    <div class="flex flex-col gap-1.5 border-t-2 border-base-content/20 bg-base-200/40 px-3 py-2">
      <p class="ic-eyebrow text-base-content/55">On deck · {length(@queue)}</p>
      <ul id={@id} phx-hook="QueueRail" phx-update="replace" class="flex flex-col gap-1">
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
          <.icon name="hero-bars-2" class="size-3.5 shrink-0 text-base-content/30" />
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
            phx-value-conv={@conv}
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

  attr :id, :string, required: true
  attr :msg, :map, required: true

  defp chat_bubble(%{msg: %{role: :user}} = assigns) do
    ~H"""
    <div id={@id} class="flex justify-end">
      <div class="ic-drop-in max-w-[85%] whitespace-pre-wrap rounded-sm bg-primary px-3 py-2 text-[17px] text-primary-content">
        {@msg.text}
      </div>
    </div>
    """
  end

  defp chat_bubble(%{msg: %{role: :assistant}} = assigns) do
    assigns = assign(assigns, :svg_ids, Map.get(assigns.msg, :svg_ids, []))

    ~H"""
    <div id={@id} class="flex flex-col items-start gap-1">
      <div
        :if={@msg.text != ""}
        class="max-w-[85%] whitespace-pre-wrap rounded-sm border-2 border-base-content/20 bg-base-100 px-3 py-2 text-[17px]"
      >
        {@msg.text}
      </div>
      <%!-- Drawings are stripped from the text and open in the modal on demand. --%>
      <button
        :if={@svg_ids != []}
        type="button"
        phx-click="zoom_svg"
        phx-value-id={hd(@svg_ids)}
        class="inline-flex items-center gap-1.5 rounded-sm border-2 border-primary/40 px-2.5 py-1 font-mono text-[0.75rem] text-primary transition hover:bg-primary hover:text-primary-content"
      >
        <.icon name="hero-photo" class="size-3.5" />
        View {if(length(@svg_ids) == 1, do: "drawing", else: "#{length(@svg_ids)} drawings")}
      </button>
    </div>
    """
  end

  defp chat_bubble(%{msg: %{role: :tool}} = assigns) do
    ~H"""
    <div
      id={@id}
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
      id={@id}
      class="text-center font-mono text-[0.62rem] uppercase tracking-wide text-base-content/45"
    >
      {@msg.text}
    </div>
    """
  end

  defp chat_bubble(%{msg: %{role: :error}} = assigns) do
    ~H"""
    <div id={@id} class="flex justify-start">
      <div class="max-w-[85%] rounded-sm border-2 border-error/50 bg-error/10 px-3 py-2 text-[17px] text-error">
        {@msg.text}
      </div>
    </div>
    """
  end
end
