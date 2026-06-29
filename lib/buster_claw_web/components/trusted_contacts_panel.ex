defmodule BusterClawWeb.TrustedContactsPanel do
  @moduledoc """
  Home corner-widget "Contacts" tab: manage the trusted-sender allow-list. Only
  mail from a trusted sender is queued for the on-shift agent to act on (and reply
  to); everything else is still archived to the Library but never queued.

  Presentation only — the `add_contact` / `remove_contact` events are handled by
  the parent LiveView (`StatusLive`), which owns `BusterClaw.TrustedSenders`.

  Minimalist + non-scrolling, to match the redesigned Calendar tab: a compact add
  row above wrapping sender chips that fill the panel. A full address trusts one
  person (green chip); `*@domain` trusts everyone at that domain (blue chip) — the
  `*@` prefix in the value makes the kind self-evident, the border just reinforces.
  """
  use BusterClawWeb, :html

  attr :entries, :list, required: true

  def panel(assigns) do
    ~H"""
    <section id="home-contacts-panel" class="ic-panel flex h-full flex-col overflow-hidden">
      <form
        phx-submit="add_contact"
        class="flex shrink-0 items-center gap-2 border-b-2 border-base-content/20 p-3"
      >
        <input
          type="text"
          name="entry"
          value=""
          autocomplete="off"
          spellcheck="false"
          placeholder="alice@example.com · *@acme.com"
          class="input input-sm min-w-0 flex-1 font-mono text-xs"
        />
        <button
          type="submit"
          class="shrink-0 rounded-xs bg-primary px-3 py-1.5 font-display text-xs font-bold uppercase tracking-wide text-primary-content transition hover:opacity-85"
        >
          Add
        </button>
      </form>

      <div
        :if={@entries != []}
        id="trusted-contacts-list"
        class="flex min-h-0 flex-1 flex-wrap content-start gap-1.5 overflow-hidden p-3"
      >
        <span
          :for={entry <- @entries}
          id={"trusted-contact-#{entry.value}"}
          class={[
            "inline-flex max-w-full items-center gap-1.5 rounded-xs border px-2 py-1",
            if(entry.type == :domain, do: "border-info/50", else: "border-success/50")
          ]}
        >
          <span class="truncate font-mono text-[0.6875rem] text-base-content">{entry.value}</span>
          <button
            type="button"
            phx-click="remove_contact"
            phx-value-entry={entry.value}
            data-confirm={"Stop trusting #{entry.value}?"}
            aria-label={"Remove #{entry.value}"}
            class="shrink-0 font-mono text-sm leading-none text-base-content/45 transition hover:text-error"
          >
            ×
          </button>
        </span>
      </div>

      <div
        :if={@entries == []}
        class="flex min-h-0 flex-1 flex-col items-center justify-center gap-1 p-4 text-center"
      >
        <p class="ic-eyebrow">No trusted senders</p>
        <p class="font-mono text-[0.6875rem] text-base-content/55">
          Add a sender above to queue their mail.
        </p>
      </div>
    </section>
    """
  end
end
