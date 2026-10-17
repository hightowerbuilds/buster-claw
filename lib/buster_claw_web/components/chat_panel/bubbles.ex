defmodule BusterClawWeb.ChatPanel.Bubbles do
  @moduledoc """
  The transcript's bubbles — one clause per role (user, assistant, tool, meta,
  error), the author line every skin renders and one skin shows, and the SVG
  modal a drawing opens into.

  Cut out of `BusterClawWeb.ChatPanel` on 10-16 (CODE_QUALITY_SWEEP Phase 7),
  which is the cut that file's size-cap note had named. The skin contract is
  unchanged by the move and is the reason `chat_bubble/1` is public here rather
  than copied: the Appearance picker's `transcript_preview/1` and the live chat
  log both import this one implementation, so there is still exactly one place
  a bubble's markup can drift from. Nothing here branches on the skin or the
  text size — see the `ChatPanel` moduledoc.
  """
  use BusterClawWeb, :html

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

  attr :id, :string, required: true
  attr :msg, :map, required: true

  def chat_bubble(%{msg: %{role: :user}} = assigns) do
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
        class="ic-drop-in max-w-[85%] whitespace-pre-wrap rounded-sm bg-primary px-3 py-2 text-primary-content"
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

  def chat_bubble(%{msg: %{role: :assistant}} = assigns) do
    assigns = assign(assigns, :svg_ids, Map.get(assigns.msg, :svg_ids, []))

    ~H"""
    <div id={@id} data-chat-role="assistant" class="flex flex-col items-start gap-1">
      <.chat_author>Buster Claw</.chat_author>
      <div
        :if={@msg.text != ""}
        data-chat-body
        class="max-w-[85%] whitespace-pre-wrap rounded-sm border-2 border-base-content/20 bg-base-100 px-3 py-2"
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

  def chat_bubble(%{msg: %{role: :tool}} = assigns) do
    ~H"""
    <div
      id={@id}
      data-chat-role="tool"
      class="flex items-center gap-2 font-mono text-base-content/55"
    >
      <.icon name="hero-command-line" class="size-3.5 shrink-0" />
      <span class="truncate">{@msg.text}</span>
    </div>
    """
  end

  def chat_bubble(%{msg: %{role: :meta}} = assigns) do
    ~H"""
    <div
      id={@id}
      data-chat-role="meta"
      class="text-center font-mono uppercase tracking-wide text-base-content/45"
    >
      {@msg.text}
    </div>
    """
  end

  def chat_bubble(%{msg: %{role: :error}} = assigns) do
    ~H"""
    <div id={@id} data-chat-role="error" class="flex justify-start">
      <div
        data-chat-body
        class="max-w-[85%] rounded-sm border-2 border-error/50 bg-error/10 px-3 py-2 text-error"
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
end
