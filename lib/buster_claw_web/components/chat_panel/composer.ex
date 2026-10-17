defmodule BusterClawWeb.ChatPanel.Composer do
  @moduledoc """
  The message composer and its attachment pieces: the one `<form>` every chat
  surface sends from, the pending-attachment chips, and the refusal banner.

  Cut out of `BusterClawWeb.ChatPanel` on 10-16 (CODE_QUALITY_SWEEP Phase 7),
  whole. The events (`chat_send`, `cut_run`, `remove_attachment`,
  `dismiss_attach_error`) still land in the LiveView the composer renders
  inside; `delivery_for/2` and `primary_label/2` still mirror
  `assets/js/lib/compose_keys.js`, and `chat_panel_test.exs` still pins them.
  """
  use BusterClawWeb, :html

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
            if(@compact, do: "px-2 py-1.5", else: "px-3 py-2")
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
end
