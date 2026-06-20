defmodule BusterClawWeb.TrustedContactsPanel do
  @moduledoc """
  Home left-column panel: manage the trusted-sender allow-list. Only mail from a
  trusted sender is queued for the on-shift agent to act on (and reply to);
  everything else is still archived to the Library but never put on the queue.

  Presentation only — the `add_contact` / `remove_contact` events are handled by
  the parent LiveView (`StatusLive`), which owns `BusterClaw.TrustedSenders`.
  """
  use BusterClawWeb, :html

  attr :entries, :list, required: true

  def panel(assigns) do
    ~H"""
    <section
      id="home-left-panel"
      class="ic-panel flex min-h-0 flex-1 flex-col overflow-hidden"
    >
      <header class="flex items-start justify-between gap-3 border-b-2 border-base-content/20 px-5 py-4">
        <div class="min-w-0">
          <p class="ic-eyebrow">Trusted Contacts</p>
          <h2 class="font-display text-2xl font-black uppercase tracking-tight">
            Trusted Contacts
          </h2>
          <p class="mt-1 text-sm text-base-content/65">
            Only mail from these senders is queued for the agent to act on.
          </p>
        </div>
        <span class="shrink-0 rounded bg-base-200 px-2 py-0.5 font-mono text-xs font-bold text-base-content/60">
          {length(@entries)}
        </span>
      </header>

      <div class="flex min-h-0 flex-1 flex-col gap-4 overflow-auto p-5">
        <form phx-submit="add_contact" class="flex flex-wrap items-center gap-2">
          <input
            type="text"
            name="entry"
            value=""
            autocomplete="off"
            spellcheck="false"
            placeholder="alice@example.com or *@acme.com"
            class="input min-w-0 flex-1"
          />
          <button
            type="submit"
            class="rounded bg-primary px-4 py-2 text-sm font-semibold text-primary-content transition hover:opacity-85"
          >
            Add
          </button>
        </form>

        <p class="font-mono text-[0.68rem] uppercase tracking-wide text-base-content/45">
          A full address trusts one person; <code class="font-mono">*@domain</code>
          trusts everyone at that domain.
        </p>

        <ul
          :if={@entries != []}
          id="trusted-contacts-list"
          class="divide-y divide-base-300 rounded border border-base-300"
        >
          <li
            :for={entry <- @entries}
            id={"trusted-contact-#{entry.value}"}
            class="flex items-center justify-between gap-3 px-3 py-2 text-sm"
          >
            <div class="flex min-w-0 items-center gap-2">
              <span class="size-2 shrink-0 rounded-full bg-success" />
              <span class="truncate font-mono">{entry.value}</span>
              <span
                :if={entry.type == :domain}
                class="rounded bg-base-200 px-2 py-0.5 font-mono text-[0.6rem] uppercase tracking-wide text-base-content/55"
              >
                domain
              </span>
            </div>
            <button
              type="button"
              phx-click="remove_contact"
              phx-value-entry={entry.value}
              data-confirm={"Stop trusting #{entry.value}?"}
              class="shrink-0 rounded border border-base-content/20 px-2 py-1 font-mono text-[0.65rem] uppercase tracking-wide text-base-content/60 transition hover:border-error hover:text-error"
            >
              Remove
            </button>
          </li>
        </ul>

        <div
          :if={@entries == []}
          class="rounded border border-dashed border-base-300 px-4 py-8 text-center text-sm text-base-content/60"
        >
          <p class="font-semibold text-base-content/80">No trusted contacts yet.</p>
          <p class="mt-1">Add a sender above to start queueing their mail for the agent.</p>
        </div>
      </div>
    </section>
    """
  end
end
