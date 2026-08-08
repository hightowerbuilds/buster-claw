defmodule BusterClawWeb.ChatPanel do
  @moduledoc """
  Chat rendering: the conversation tabs and Home's docked chat panel, plus the
  pieces they share (transcript bubbles, thinking timer, on-deck queue rail,
  composer).

  Presentation only — every event (`select_chat`, `close_chat`, `new_chat`,
  `chat_send`, `cut_run`, `cancel_queued`, …) is handled by the parent LiveView,
  which owns the conversation state. `StatusLive` owns Home's, and Home is the
  only surface rendering a chat since Trading was deleted on 08-08.

  The shared pieces still take an explicit DOM id and, where they push an event,
  an explicit conversation — both defaulted for Home. That generality was built
  for the floating Trading windows; it is kept because it costs nothing and is
  what the next multi-chat surface would need.
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

  attr :messages, :any, required: true, doc: "the parent LiveView's chat_messages stream"
  attr :seq, :integer, required: true, doc: "message counter — see data-seq below"
  attr :running, :boolean, required: true

  attr :steerable, :boolean,
    default: false,
    doc: "the backend can deliver into a running turn — drives the composer's primary action"

  attr :announcement, :string, default: nil, doc: "last delivery outcome, announced politely"
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

      <.composer
        id="home-composer"
        running={@running}
        steerable={@steerable}
        agent_cli_missing={@agent_cli_missing}
        placeholder={@placeholder}
        announcement={@announcement}
      />
    </section>
    """
  end

  attr :id, :string, required: true
  attr :conv, :string, default: nil, doc: "nil on Home, where there is one chat to disambiguate"
  attr :running, :boolean, required: true

  attr :steerable, :boolean,
    required: true,
    doc: "the backend can deliver into a running turn — drives the primary action"

  attr :agent_cli_missing, :boolean, default: false
  attr :placeholder, :string, required: true
  attr :compact, :boolean, default: false, doc: "the tighter multi-window sizing"

  attr :announcement, :string,
    default: nil,
    doc: "last delivery outcome, announced politely — state must not be colour-only"

  @doc """
  The message composer.

  One implementation on purpose. These were two forked `<form>`s with two copies
  of the Enter handling in two different JS hooks, and the next change was about
  to be a third rule in both. A drifted copy here fails invisibly: one surface
  steers and the other quietly queues, and the operator has no way to tell which
  they got.

  ## The primary action names what will actually happen

  While a turn is running the main button is **Steer now** on a backend that can
  steer and **Queue next** on one that cannot. There is deliberately no Steer
  button that silently queues — a control that lies about its effect is worse
  than one that is missing, and this is the surface where that lie would be most
  expensive.

  `Cmd/Ctrl+Shift+Enter` inverts the two for one message. The mapping from
  (running, steerable) to label and posted delivery lives in
  `assets/js/lib/compose_keys.js`, so the button, the chord, and the value on the
  wire cannot disagree.
  """
  def composer(assigns) do
    ~H"""
    <form
      id={@id}
      phx-hook="Composer"
      phx-submit="chat_send"
      data-chat-form
      data-running={to_string(@running)}
      data-steerable={to_string(@steerable)}
      class={[
        "flex shrink-0 items-end gap-2 border-t-2 border-base-content/20",
        if(@compact, do: "p-2", else: "p-3")
      ]}
    >
      <input :if={@conv} type="hidden" name="conv" value={@conv} />
      <%!-- Delivery state is announced as well as chipped. A steer that quietly
            became a queued message is exactly the thing a colour change alone
            would hide. --%>
      <p
        id={"#{@id}-announcement"}
        role="status"
        aria-live="polite"
        class="sr-only"
      >
        {@announcement}
      </p>
      <%!-- The delivery the NEXT submit should use. The hook rewrites it for an
            inverted chord and puts it straight back, so a stray value can never
            outlive one submission. --%>
      <input type="hidden" name="delivery" value={delivery_for(@running, @steerable)} data-delivery />

      <textarea
        name="message"
        data-chat-input
        rows="2"
        disabled={@agent_cli_missing}
        placeholder={if @agent_cli_missing, do: "Install Claude Code to chat", else: @placeholder}
        class={[
          "min-h-0 flex-1 resize-none rounded-sm border-2 border-base-content/25 bg-base-100 focus:border-primary focus:outline-none disabled:opacity-50",
          if(@compact, do: "px-2 py-1.5 text-[15px]", else: "px-3 py-2 text-[17px]")
        ]}
      ></textarea>

      <div class="flex shrink-0 flex-col items-stretch gap-1">
        <button
          type="submit"
          data-primary-action
          disabled={@agent_cli_missing}
          class={[
            "inline-flex items-center justify-center gap-2 rounded bg-primary font-semibold text-primary-content transition hover:opacity-85 disabled:opacity-40",
            if(@compact, do: "px-3 py-2 text-xs", else: "px-4 py-2.5 text-sm")
          ]}
        >
          <.icon :if={not @running} name="hero-paper-airplane" class="size-4" />
          {primary_label(@running, @steerable)}
        </button>

        <%!-- Only rendered when it does something different from the primary.
              While idle, or on a backend without steering, both actions start
              or queue the same turn. --%>
        <button
          :if={@running and @steerable}
          type="submit"
          data-secondary-action
          name="delivery"
          value="next"
          disabled={@agent_cli_missing}
          title="Run this after the current turn instead of changing it (⌘⇧↵)"
          class="inline-flex items-center justify-center rounded border-2 border-base-content/25 px-3 py-1 font-mono text-[0.6rem] uppercase tracking-wide text-base-content/70 transition hover:border-primary hover:text-primary disabled:opacity-40"
        >
          Queue next
        </button>
      </div>
    </form>
    """
  end

  # Mirrors `deliveryFor/2` in `assets/js/lib/compose_keys.js`. Both exist
  # because the server renders the first value and the hook rewrites it for an
  # inverted chord; the Bun suite pins the JS side and `chat_panel_test.exs`
  # pins this one.
  defp delivery_for(false, _steerable), do: "auto"
  defp delivery_for(true, true), do: "steer"
  defp delivery_for(true, false), do: "next"

  defp primary_label(false, _steerable), do: "Send"
  defp primary_label(true, true), do: "Steer now"
  defp primary_label(true, false), do: "Queue next"

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
  # A multi-chat surface passes its own, since several queues can be on screen.
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
    # A message reloaded from the transcript has no delivery — it is not
    # persisted (see `Chat.emit_message/4`), so an old bubble simply renders
    # without a chip rather than guessing at one.
    assigns = assign(assigns, :delivery, Map.get(assigns.msg, :delivery))

    ~H"""
    <div id={@id} class="flex flex-col items-end gap-1">
      <div class="ic-drop-in max-w-[85%] whitespace-pre-wrap rounded-sm bg-primary px-3 py-2 text-[17px] text-primary-content">
        {@msg.text}
      </div>
      <%!-- Only a message delivered INTO a running turn is chipped. An ordinary
            message that started its own turn needs no explanation, and a queued
            one lives in the on-deck rail until it runs. Marking everything would
            make the labels that carry information disappear into decoration.

            SENT is not a lesser STEERED — it is a different claim. OpenCode's
            `prompt_async` returns an empty body, so when its out-of-band
            acceptance echo does not arrive in time we know the message was
            posted and nothing more. Saying "steered" there would be the exact
            false delivery this whole surface is built to avoid. --%>
      <span
        :if={@delivery == :steered}
        data-delivery-chip="steered"
        title="Delivered into the turn already running, and the agent confirmed it. The agent acts on it at its next step, which can take as long as the tool it is running."
        class="inline-flex items-center gap-1 rounded-sm border border-primary/40 px-1.5 font-mono text-[0.55rem] uppercase tracking-wider text-primary"
      >
        <.icon name="hero-arrow-uturn-left" class="size-2.5" /> Steered
      </span>
      <span
        :if={@delivery == :sent}
        data-delivery-chip="sent"
        title="Sent to the running turn. This backend does not confirm receipt, so it is not being reported as delivered."
        class="inline-flex items-center gap-1 rounded-sm border border-base-content/30 px-1.5 font-mono text-[0.55rem] uppercase tracking-wider text-base-content/60"
      >
        <.icon name="hero-paper-airplane" class="size-2.5" /> Sent
      </span>
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
