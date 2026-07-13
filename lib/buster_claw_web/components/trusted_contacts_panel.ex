defmodule BusterClawWeb.TrustedContactsPanel do
  @moduledoc """
  Home corner-widget "Contacts" tab: the trust gate, seen from the mail side.

  This is one of **two views onto the same contact list**. The other is the
  Message Machine's shaderface card (`PhoneLive`), which is the phone-side view.
  Same rows, same policy files, different affordances: this panel is a dense chip
  grid built for a corner widget; that one is a full-height face card built to be
  looked at. Neither owns the data — `BusterClaw.Contacts` does.

  Only a trusted sender's mail is queued for the on-shift agent to act on (and
  reply to); everything else is still archived to the Library but never queued.

  Presentation only — `add_contact` / `remove_contact` / `untrust_contact` are
  handled by the parent LiveView (`StatusLive`).

  ## Three chip kinds, and why the third exists

    * **Contact** (name chip) — a row in `contacts` whose email is trusted.
    * **Orphan address** (mono chip) — an address in the policy file with no
      contact behind it; typically added by the agent over the CLI.
    * **Domain wildcard** (`*@acme.com`, info-bordered) — trusts *everyone* at a
      domain. It can never have a contact row, because it isn't a person.

  The panel must show all three. Rendering only the named contacts would draw a
  trust surface smaller than the one the gate enforces, which is the most
  dangerous kind of wrong a security UI can be.
  """
  use BusterClawWeb, :html

  attr :contacts, :list, required: true, doc: "contacts whose email is trusted"
  attr :entries, :list, required: true, doc: "policy entries with no contact behind them"

  def panel(assigns) do
    assigns = assign(assigns, :empty?, assigns.contacts == [] and assigns.entries == [])

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
        :if={!@empty?}
        id="trusted-contacts-list"
        class="flex min-h-0 flex-1 flex-wrap content-start gap-1.5 overflow-hidden p-3"
      >
        <%!-- Named people first: a contact you can also see, and face, on /phone. --%>
        <span
          :for={contact <- @contacts}
          id={"trusted-contact-#{contact.id}"}
          class="inline-flex max-w-full items-center gap-1.5 rounded-xs border border-success/50 px-2 py-1"
          title={contact.email}
        >
          <span class="truncate font-display text-[0.6875rem] font-bold text-base-content">
            {contact.name}
          </span>
          <button
            type="button"
            phx-click="untrust_contact"
            phx-value-id={contact.id}
            data-confirm={"Stop trusting #{contact.name}? They stay in your contacts; their mail just stops reaching the agent."}
            aria-label={"Stop trusting #{contact.name}"}
            class="shrink-0 font-mono text-sm leading-none text-base-content/45 transition hover:text-error"
          >
            ×
          </button>
        </span>

        <%!-- Then the entries with nobody behind them. --%>
        <span
          :for={entry <- @entries}
          id={"trusted-entry-#{entry.value}"}
          class={[
            "inline-flex max-w-full items-center gap-1.5 rounded-xs border px-2 py-1",
            if(entry.type == :domain, do: "border-info/50", else: "border-base-content/30")
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
        :if={@empty?}
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
