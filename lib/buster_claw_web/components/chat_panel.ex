defmodule BusterClawWeb.ChatPanel do
  @moduledoc """
  Home chat surface: the conversation tabs and the chat panel (transcript,
  thinking timer, on-deck queue rail, and the composer).

  Presentation only — all events (`select_chat`, `close_chat`, `new_chat`,
  `chat_send`, `cut_run`, `cancel_queued`, …) are handled by the parent
  LiveView (`StatusLive`), which owns the conversation state.
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

  attr :messages, :list, required: true
  attr :running, :boolean, required: true
  attr :thinking, :any, required: true
  attr :queue, :list, required: true

  def chat_panel(assigns) do
    ~H"""
    <section
      id="home-agent-chat"
      phx-hook="AgentChat"
      data-running={to_string(@running)}
      class="ic-panel flex min-h-0 w-full flex-1 flex-col overflow-hidden"
    >
      <header class="flex items-center justify-between gap-3 border-b-2 border-base-content/20 px-5 py-4">
        <div>
          <p class="ic-eyebrow">Chat</p>
          <h2 class="font-display text-2xl font-black uppercase tracking-tight">
            Talk to Buster Claw
          </h2>
        </div>
        <div class="flex items-center gap-3">
          <button
            id="voice-toggle"
            phx-hook="VoiceToggle"
            phx-update="ignore"
            type="button"
            aria-pressed="true"
            title="Toggle spoken replies"
            class="inline-flex items-center gap-1.5 rounded border-2 border-primary px-2.5 py-1 font-mono text-[0.62rem] uppercase tracking-wide text-primary transition"
          >
            <.icon name="hero-speaker-wave" class="size-3.5" />
            <span data-voice-label>Voice on</span>
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
        <%!-- Voice-to-text. Always visible on the left of the composer; the
              reusable `Mic` hook records on-device whisper and fills the input. --%>
        <button
          id="chat-mic"
          type="button"
          phx-hook="Mic"
          data-voice-target="[data-chat-input]"
          data-voice-overlay="[data-chat-listening]"
          aria-label="Voice input — click to talk"
          title="Click to talk · ⌘/"
          class="inline-grid size-11 shrink-0 place-items-center self-stretch rounded border-2 border-base-content/25 text-base-content/70 transition hover:border-primary hover:text-primary data-[state=listening]:border-primary data-[state=listening]:bg-primary/10 data-[state=listening]:text-primary data-[state=listening]:animate-pulse data-[state=transcribing]:border-primary/60 data-[state=transcribing]:text-primary"
        >
          <span data-mic-idle class="inline-grid place-items-center">
            <.icon name="hero-microphone" class="size-5" />
          </span>
          <span
            data-mic-busy
            hidden
            class="size-3.5 animate-spin rounded-full border-2 border-current border-t-transparent"
          >
          </span>
        </button>

        <div class="relative flex-1">
          <textarea
            name="message"
            data-chat-input
            rows="2"
            placeholder="Message Buster Claw…  (Enter to send, Shift+Enter for a new line)"
            class="min-h-0 w-full resize-none rounded-sm border-2 border-base-content/25 bg-base-100 px-3 py-2 text-[17px] focus:border-primary focus:outline-none"
          ></textarea>
          <%!-- Listening animation — flipped visible by the Mic hook while recording. --%>
          <div
            data-chat-listening
            hidden
            class="pointer-events-none absolute inset-0 flex items-center justify-center gap-3 rounded-sm bg-base-100/85 backdrop-blur-sm"
          >
            <span class="ic-voice-bars" aria-hidden="true">
              <i></i><i></i><i></i><i></i><i></i>
            </span>
            <span class="font-display text-xs font-bold uppercase tracking-wide text-primary">
              Listening…
            </span>
          </div>
        </div>

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

  # The queue rail: messages typed while a run is in flight, stacked as "next
  # pieces" and dispatched one-per-turn as the current run finishes. The
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
end
