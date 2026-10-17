defmodule BusterClawWeb.ChatPanel do
  @moduledoc """
  Chat rendering: the conversation tabs and Home's docked chat panel, plus the
  thinking timer, the on-deck queue rail and the skin preview. The bubbles
  live in `ChatPanel.Bubbles` and the composer in `ChatPanel.Composer`; both
  are imported here, so a bubble or the form renders from exactly one place.

  Presentation only — every event (`select_chat`, `close_chat`, `new_chat`,
  `chat_send`, `cut_run`, `cancel_queued`, …) is handled by the parent LiveView,
  which owns the conversation state. `StatusLive` owns Home's, and Home is the
  only surface rendering a chat since Trading was deleted on 08-08.

  The shared pieces still take an explicit DOM id and, where they push an event,
  an explicit conversation — both defaulted for Home. That generality was built
  for the floating Trading windows; it is kept because it costs nothing and is
  what the next multi-chat surface would need.

  ## Appearance is CSS, and that is a contract

  The panel has two switchable axes — the skin (`BusterClaw.ChatSkin`) and the
  text size (`BusterClaw.ChatTextSize`) — and the **only** thing that varies in
  what this module renders is the pair of attributes `data-chat-skin` and
  `data-chat-text-size` on the root `<section>`. Nothing here may branch on
  either: the transcript is a stream, so a message already on screen would keep
  the classes it was born with and the switch would half-apply. An element one
  skin needs is rendered by all of them and hidden by CSS in the others.
  `BusterClawWeb.ChatPanelTest` asserts the rendered HTML is byte-identical
  across every skin *and* every size once the attributes are normalized away.

  One consequence worth knowing before editing a bubble: **the chat's type sizes
  are not in this markup.** They live in `app.css` as
  `calc(<size> * var(--chat-scale, 1))`, because a Tailwind literal cannot be
  multiplied and the size control has to multiply something. Adding a
  `text-[17px]` back to a bubble would take it out of the scale silently.
  """
  use BusterClawWeb, :html

  import BusterClawWeb.ChatPanel.Bubbles
  import BusterClawWeb.ChatPanel.Composer

  # Literals at compile time (an `attr` default and `values` may not be function
  # calls), so the component and `ChatSkin` cannot disagree about which skins
  # exist or which one is the default.
  @default_skin BusterClaw.ChatSkin.default()
  @skin_keys BusterClaw.ChatSkin.keys()
  @default_text_size BusterClaw.ChatTextSize.default()
  @text_size_keys BusterClaw.ChatTextSize.keys()

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

  # The home screen's front door, and one of the four surfaces `VI-a` requires to
  # say one sentence — see `BusterClawWeb.FrontDoorTest`, which fails if this
  # drifts from the README and the wizard.
  #
  # Two things it deliberately no longer does. It does not name **Claude**: the
  # harness is `ModelPolicy.backend_for(:chat)` and returns codex or opencode just
  # as readily, so the old copy was false for any operator who had switched. And
  # it no longer opens with mail and queue jargon, both of which assume a concept
  # a newcomer does not have yet. What replaces them is an outcome and a promise
  # about evidence, which is the thing this app has and a chat box does not.
  #
  # The retired phrasings are quoted in `BusterClawWeb.FrontDoorTest` and nowhere
  # else on purpose — that guard refuses them anywhere in this file, comments
  # included, because a retired pitch sitting beside the live one is how a
  # surface ends up saying two things.
  attr :empty_message, :string,
    default:
      "An assistant on your Mac that uses your tools, keeps working, and shows you what it did. " <>
        "Ask it to summarize a document, draft a reply without sending it, or look something up — " <>
        "then check Activity to see exactly what it touched."

  slot :pinned,
    doc:
      "rendered between the log and the composer — a pending action the caller wants answered " <>
        "before the next message, kept in view while the log scrolls"

  attr :placeholder, :string,
    default: "Message Buster Claw…  (Enter to send, Shift+Enter for a new line)"

  attr :attachments, :list,
    default: [],
    doc: "staged files waiting to ride with the next message — see ChatAttachments"

  attr :attach_error, :any, default: nil, doc: "the refusal the user has to see, or nil"

  attr :upload, :any,
    default: nil,
    doc:
      "the `allow_upload` config for the HTML5 (dev browser) drop path. nil renders the " <>
        "panel with no upload wiring at all, which is what a component test wants"

  attr :skin, :string,
    default: @default_skin,
    values: @skin_keys,
    doc:
      "which look to wear — the sole skin-dependent thing this component emits, as " <>
        "`data-chat-skin` on the root section. See the moduledoc's contract."

  attr :text_size, :string,
    default: @default_text_size,
    values: @text_size_keys,
    doc:
      "how large the chat's text is — emitted as `data-chat-text-size`, which supplies " <>
        "the `--chat-scale` every font-size in the chat multiplies by. Independent of " <>
        "the skin: the two axes multiply."

  def chat_panel(assigns) do
    ~H"""
    <section
      id="home-agent-chat"
      phx-hook="AgentChat"
      data-running={to_string(@running)}
      data-seq={@seq}
      data-chat-skin={@skin}
      data-chat-text-size={@text_size}
      class="ic-panel flex min-h-0 w-full flex-1 flex-col overflow-hidden"
    >
      <header
        data-chat-header
        class="flex items-center justify-between gap-3 border-b-2 border-base-content/20 px-5 py-4"
      >
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

      <%!-- The dropzone wraps everything below the header, so a file dropped
            anywhere over the conversation attaches. Two paths land here and only
            one is ever live: the `ChatDropzone` hook forwards Tauri's native
            drag-drop as `attach_paths` (paths — the packaged app), and in a dev
            browser the same hook feeds LiveView's upload (contents).

            `phx-drop-target` is NOT what carries the browser drop, and deleting
            it as redundant would be the wrong reading. The hook takes the drop
            itself and stops propagation, so LiveView's window handler never sees
            the raw `FileList`; the hook then hands the *survivors* of its own
            filtering back through `track-uploads` on the `live_file_input`
            below. The upload is still LiveView's — only the choice of what gets
            uploaded is the hook's. The attribute stays because it is what makes
            this element a declared target, and it is harmless.

            The overlay is `.bc-drop-overlay`, hidden until the hook marks this
            container active; the class pair is WorkspaceDropzone's, reused so
            there is one drag affordance in the app rather than two. --%>
      <div
        id="chat-dropzone"
        phx-hook="ChatDropzone"
        phx-drop-target={@upload && @upload.ref}
        class="relative flex min-h-0 flex-1 flex-col"
      >
        <div id="agent-chat-log" data-chat-log phx-update="stream" class={log_class()}>
          <%!-- Stream-managed container: the empty state is a static child shown
              via CSS only when it's the sole child (the stream idiom — the
              server no longer knows the collection size). data-seq on the
              section bumps per message so the AgentChat hook's updated()
              (scroll-to-bottom) is guaranteed to fire on stream inserts. --%>
          <div
            id="agent-chat-empty"
            data-chat-empty
            class="m-auto hidden max-w-xs text-center text-base-content/55 only:block"
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
          attachments={@attachments}
          attach_error={@attach_error}
          upload={@upload}
        />

        <div
          class="bc-drop-overlay pointer-events-none absolute inset-0 z-20 place-items-center bg-base-100/85"
          aria-hidden="true"
        >
          <div class="flex flex-col items-center gap-2 rounded-sm border-2 border-dashed border-primary px-8 py-6">
            <.icon name="hero-paper-clip" class="size-7 text-primary" />
            <p class="font-mono text-xs uppercase tracking-wide text-primary">Drop to attach</p>
          </div>
        </div>
      </div>
    </section>
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
          <span data-chat-queued class="flex-1 truncate">{item.text}</span>
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

  # The transcript container's classes, shared by the live log and the skin
  # preview. One string, because a preview whose layout has drifted from the real
  # log is worse than no preview: it is where you go to check, so it is the last
  # place a difference would be noticed.
  defp log_class, do: "flex min-h-0 flex-1 flex-col gap-3 overflow-auto p-5"

  @doc """
  A short canned transcript in a given skin — the Appearance picker's preview.

  Renders the **real** bubbles through the same `Bubbles.chat_bubble/1` the live
  chat uses, inside the same `log_class/0` container. A second copy of the bubble
  markup would drift within a month and the drift would be invisible precisely
  because this is the surface someone uses to check what a skin looks like.

  ## What it deliberately leaves out

  **The composer.** It is a `<form>` carrying `phx-hook="Composer"`,
  `phx-submit="chat_send"` and hard-coded DOM ids; mounting it here would mean
  live hooks with no chat LiveView behind them and a submit that crashes the
  page. The caller says so in a line of copy instead.

  **The panel chrome.** The skins' translucency, radius and shadow rules are
  written against `.ic-home .ic-panel` — they describe a panel sitting over the
  homepage's live shader, which no settings page has. Everything inside the
  transcript is faithful; the frame around it is this page's own.
  """
  attr :skin, :string, required: true
  attr :text_size, :string, required: true
  attr :id, :string, default: "chat-skin-preview"

  def transcript_preview(assigns) do
    assigns = assign(assigns, :messages, preview_messages())

    ~H"""
    <div
      id={@id}
      data-chat-skin={@skin}
      data-chat-text-size={@text_size}
      data-chat-skin-preview
      class="overflow-hidden"
    >
      <div data-chat-log class={log_class()}>
        <.chat_bubble :for={{dom_id, msg} <- @messages} id={"#{@id}-#{dom_id}"} msg={msg} />
      </div>
    </div>
    """
  end

  # Four roles, because each one is a different part of the look: who said it
  # (user/assistant), the agent working (tool), and the run's own bookkeeping
  # (meta). The text is about the skins on purpose — a preview reading "Lorem
  # ipsum" tells you nothing about line length or wrapping.
  defp preview_messages do
    [
      {"user",
       %{
         id: 1,
         role: :user,
         text: "How does this look?",
         svg_ids: [],
         delivery: nil,
         attachments: []
       }},
      {"assistant",
       %{
         id: 2,
         role: :assistant,
         text:
           "That is up to you. This is the whole transcript — your messages, mine, " <>
             "the tools I run, and the notes in between.",
         svg_ids: [],
         delivery: nil,
         attachments: []
       }},
      {"tool",
       %{
         id: 3,
         role: :tool,
         text: "Bash: ./buster-claw note_list",
         svg_ids: [],
         delivery: nil,
         attachments: []
       }},
      {"meta",
       %{
         id: 4,
         role: :meta,
         text: "Run finished · 4.2s",
         svg_ids: [],
         delivery: nil,
         attachments: []
       }}
    ]
  end
end
