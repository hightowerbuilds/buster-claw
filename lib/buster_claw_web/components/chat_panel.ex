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

  ## Skins are CSS, and that is a contract

  The panel's look is switchable (`BusterClaw.ChatSkin`), and the **only** thing
  that varies in what this module renders is `data-chat-skin` on the root
  `<section>`. Nothing here may branch on the skin: the transcript is a stream,
  so a message already on screen would keep the classes it was born with and the
  switch would half-apply. An element one skin needs is rendered by all three and
  hidden by CSS in the others. `BusterClawWeb.ChatPanelTest` asserts the rendered
  HTML is byte-identical across skins once the attribute is normalized away.
  """
  use BusterClawWeb, :html

  # Literals at compile time (an `attr` default and `values` may not be function
  # calls), so the component and `ChatSkin` cannot disagree about which skins
  # exist or which one is the default.
  @default_skin BusterClaw.ChatSkin.default()
  @skin_keys BusterClaw.ChatSkin.keys()

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

  def chat_panel(assigns) do
    ~H"""
    <section
      id="home-agent-chat"
      phx-hook="AgentChat"
      data-running={to_string(@running)}
      data-seq={@seq}
      data-chat-skin={@skin}
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

  attr :attachments, :list, default: []
  attr :attach_error, :any, default: nil
  attr :upload, :any, default: nil

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
        "flex shrink-0 flex-col gap-2 border-t-2 border-base-content/20",
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

      <.attach_error error={@attach_error} upload={@upload} />
      <.attach_chips attachments={@attachments} />

      <%!-- Anchored because two skins treat this row as one object: Minimal
            strips it to a bare prompt line, Workplace draws the bordered box
            that holds the input and the send button together. --%>
      <div data-chat-input-row class="flex items-end gap-2">
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

        <%!-- The keyboard (and mouse) route to the same upload the dropzone
              feeds. A drop-only affordance is not an affordance for everyone. --%>
        <label
          :if={@upload}
          title="Attach a file"
          class="inline-flex cursor-pointer items-center justify-center rounded border-2 border-base-content/25 px-2 py-1 text-base-content/60 transition hover:border-primary hover:text-primary"
        >
          <.icon name="hero-paper-clip" class="size-4" />
          <span class="sr-only">Attach a file</span>
          <.live_file_input upload={@upload} class="sr-only" />
        </label>
      </div>
    </form>
    """
  end

  @doc """
  Pending attachment chips — filename, size, a thumbnail for an image, and a way
  to take it back out.

  Above the input rather than beside it, and rendered *before* the send: an
  attachment the user cannot see and cannot cancel is worse than none, because
  the first they learn of it is the model answering a question about a file they
  did not mean to share.
  """
  attr :attachments, :list, required: true

  def attach_chips(%{attachments: []} = assigns), do: ~H""

  def attach_chips(assigns) do
    ~H"""
    <ul data-attach-chips class="flex flex-wrap items-center gap-2">
      <li
        :for={att <- @attachments}
        data-attach-chip={att.id}
        class="flex items-center gap-2 rounded-sm border-2 border-base-content/25 bg-base-200/70 py-1 pl-1 pr-2"
      >
        <img
          :if={att.preview}
          src={att.preview}
          alt=""
          class="size-8 shrink-0 rounded-xs object-cover"
        />
        <span
          :if={!att.preview}
          class="grid size-8 shrink-0 place-items-center rounded-xs bg-base-content/10"
        >
          <.icon name="hero-document" class="size-4 text-base-content/60" />
        </span>
        <span class="max-w-[11rem] truncate text-[13px]" title={att.filename}>{att.filename}</span>
        <span class="shrink-0 font-mono text-[0.6rem] uppercase tracking-wide text-base-content/55">
          {att.size_label}
        </span>
        <button
          type="button"
          phx-click="remove_attachment"
          phx-value-id={att.id}
          title={"Remove #{att.filename}"}
          aria-label={"Remove #{att.filename}"}
          class="shrink-0 text-base-content/45 transition hover:text-error"
        >
          <.icon name="hero-x-mark" class="size-4" />
        </button>
      </li>
    </ul>
    """
  end

  @doc """
  A refusal, said out loud where the send button is.

  Two sources, one banner: `error` is what the hook or the store refused (its
  `:blocked` key is added when a send was then stopped because of it), and
  `upload` carries what LiveView itself refused client-side — too large, too
  many — which is the refusal-at-the-drop the roadmap asks for. Both are
  dismissible, because a refusal that cannot be cleared blocks the composer
  forever.
  """
  attr :error, :any, required: true
  attr :upload, :any, required: true

  def attach_error(assigns) do
    ~H"""
    <div
      :if={@error}
      data-attach-error
      role="alert"
      class="flex items-start gap-2 rounded-sm border-2 border-error/60 bg-error/10 px-2 py-1.5 text-[15px] text-error"
    >
      <.icon name="hero-exclamation-triangle" class="mt-0.5 size-4 shrink-0" />
      <span class="flex-1">
        {@error.message}
        <span :if={@error[:blocked]} class="block font-semibold">{@error[:blocked]}</span>
      </span>
      <button
        type="button"
        phx-click="dismiss_attach_error"
        class="shrink-0 font-mono text-[0.6rem] uppercase tracking-wide underline"
      >
        Dismiss
      </button>
    </div>

    <div
      :for={entry <- (@upload && @upload.entries) || []}
      :if={upload_errors(@upload, entry) != []}
      data-attach-upload-error={entry.ref}
      role="alert"
      class="flex items-center gap-2 rounded-sm border-2 border-error/60 bg-error/10 px-2 py-1.5 text-[15px] text-error"
    >
      <.icon name="hero-exclamation-triangle" class="size-4 shrink-0" />
      <span class="flex-1">
        {entry.client_name} — {upload_error_text(hd(upload_errors(@upload, entry)))}
      </span>
      <button
        type="button"
        phx-click="cancel_attach_upload"
        phx-value-ref={entry.ref}
        class="shrink-0 font-mono text-[0.6rem] uppercase tracking-wide underline"
      >
        Dismiss
      </button>
    </div>
    """
  end

  # LiveView's own refusals, in the same vocabulary as the store's.
  defp upload_error_text(:too_large), do: "too large to attach."
  defp upload_error_text(:too_many_files), do: "too many files at once."
  defp upload_error_text(:not_accepted), do: "not a kind of file that can be attached."
  defp upload_error_text(other), do: "could not be attached (#{inspect(other)})."

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
    assigns =
      assigns
      |> assign(:delivery, Map.get(assigns.msg, :delivery))
      |> assign(:attachments, Map.get(assigns.msg, :attachments, []))

    ~H"""
    <div id={@id} data-chat-role="user" class="flex flex-col items-end gap-1">
      <.chat_author>You</.chat_author>
      <div
        :if={@msg.text != ""}
        data-chat-body
        class="ic-drop-in max-w-[85%] whitespace-pre-wrap rounded-sm bg-primary px-3 py-2 text-[17px] text-primary-content"
      >
        {@msg.text}
      </div>
      <%!-- What was attached, on the message that attached it. An image is a
            thumbnail that opens the SAME modal a drawing does — it joined the
            conversation's visual pool, so ← / → page across everything visual in
            the chat rather than treating attachments as a separate world. A file
            is a chip; there is nothing to preview and pretending otherwise would
            just be a grey rectangle. --%>
      <div
        :if={@attachments != []}
        data-chat-attachments
        class="flex max-w-[85%] flex-wrap justify-end gap-2"
      >
        <button
          :for={att <- Enum.filter(@attachments, & &1.preview)}
          type="button"
          phx-click="zoom_svg"
          phx-value-id={att.pool_id}
          data-attach-image={att.id}
          title={att.filename}
          aria-label={"Open #{att.filename} full-screen"}
          class="block cursor-zoom-in overflow-hidden rounded-sm border-2 border-primary/40 transition hover:border-primary"
        >
          <img src={att.preview} alt={att.filename} class="block max-h-40 w-auto" />
        </button>
        <span
          :for={att <- Enum.reject(@attachments, & &1.preview)}
          data-attach-file={att.id}
          class={[
            "inline-flex items-center gap-2 rounded-sm border-2 px-2 py-1 text-[13px]",
            if(att.available?,
              do: "border-base-content/25 bg-base-200/70",
              else: "border-base-content/20 bg-base-200/40 text-base-content/50 line-through"
            )
          ]}
        >
          <.icon name="hero-document" class="size-4 shrink-0" />
          <span class="max-w-[12rem] truncate">{att.filename}</span>
          <span class="font-mono text-[0.6rem] uppercase tracking-wide opacity-70">
            {att.size_label}
          </span>
          <span :if={!att.available?} class="font-mono text-[0.55rem] uppercase tracking-wider">
            No longer available
          </span>
        </span>
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
    assigns =
      assigns
      |> assign(:svg_ids, Map.get(assigns.msg, :svg_ids, []))
      |> assign(:scenes, Map.get(assigns.msg, :scenes, []))

    ~H"""
    <div id={@id} data-chat-role="assistant" class="flex flex-col items-start gap-1">
      <.chat_author>Buster Claw</.chat_author>
      <div
        :if={@msg.text != ""}
        data-chat-body
        class="max-w-[85%] whitespace-pre-wrap rounded-sm border-2 border-base-content/20 bg-base-100 px-3 py-2 text-[17px]"
      >
        {@msg.text}
      </div>
      <%!-- A 3D scene renders INLINE (unlike a drawing, which is a link) — the
              card is the message's point, not an attachment to it. Clicking still
              opens the same modal, so paging across every visual in the
              conversation keeps working. --%>
      <.scene_card :for={scene <- @scenes} scene={scene} />
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
      data-chat-role="tool"
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
      data-chat-role="meta"
      class="text-center font-mono text-[0.62rem] uppercase tracking-wide text-base-content/45"
    >
      {@msg.text}
    </div>
    """
  end

  defp chat_bubble(%{msg: %{role: :error}} = assigns) do
    ~H"""
    <div id={@id} data-chat-role="error" class="flex justify-start">
      <div
        data-chat-body
        class="max-w-[85%] rounded-sm border-2 border-error/50 bg-error/10 px-3 py-2 text-[17px] text-error"
      >
        {@msg.text}
      </div>
    </div>
    """
  end

  # Who said it — a line every skin renders and only one skin shows.
  #
  # `sr-only`, so it costs no layout and no visual change in the skins that
  # distinguish speakers some other way (Industrial by alignment and colour,
  # Minimal by a prompt glyph). The Workplace skin promotes it to a visible
  # author line. Two things follow from it being real DOM rather than a CSS
  # `content:` string: it is announced by a screen reader in EVERY skin — which
  # alignment and colour never were — and it survives copy-paste.
  #
  # The rule is worth stating because the next skin will face it too: content
  # belongs in the DOM, decoration belongs in CSS. A name is content. Minimal's
  # `>` sigil is decoration, so it is a `::before` and appears nowhere here — a
  # screen reader should not read a glyph aloud, and it should not land in
  # copied text.
  slot :inner_block, required: true

  defp chat_author(assigns) do
    ~H"""
    <span data-chat-author class="sr-only">{render_slot(@inner_block)}</span>
    """
  end

  @doc """
  One inline 3D scene card in the transcript.

  `scene` is a `%{id, svg}` from the session's visual pool, where `svg` was
  **generated** by `BusterClaw.Scene3d.Svg` from a validated scene — not authored
  by the model. That is why it is safe to render live here with `raw/1` without a
  sanitizer pass: no model-controlled markup exists in the string, and the only
  model-controlled text (labels) is escaped at generation.

  The card is a button so the whole surface zooms into `svg_modal/1`. `svg` has a
  `viewBox` but no `width`/`height`, so the CSS cap below scales it rather than
  cropping it — the same failure `SvgViewer.normalize/1` exists to prevent.
  """
  attr :scene, :map, required: true

  def scene_card(assigns) do
    ~H"""
    <button
      type="button"
      phx-click="zoom_svg"
      phx-value-id={@scene.id}
      aria-label="Open 3D scene full-screen"
      class="ic-scene-card group block w-full max-w-[85%] cursor-zoom-in overflow-hidden rounded-sm border-2 border-base-content/20 bg-base-100 transition hover:border-primary"
    >
      <div class="[&>svg]:block [&>svg]:h-auto [&>svg]:w-full">
        {Phoenix.HTML.raw(@scene.svg)}
      </div>
      <div class="flex items-center gap-1.5 border-t-2 border-base-content/10 px-2 py-1 font-mono text-[0.6rem] uppercase tracking-wider text-base-content/50 transition group-hover:text-primary">
        <.icon name="hero-cube" class="size-3" /> 3D scene
      </div>
    </button>
    """
  end
end
