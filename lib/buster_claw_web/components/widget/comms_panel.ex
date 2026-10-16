defmodule BusterClawWeb.Widget.CommsPanel do
  @moduledoc """
  The corner widget's **Contacts** tab, in two inline columns: the people (with
  an Email action, and the place to add one) and the trusted-sender list.

  Markup only. Every event (`toggle_add_contact`, `add_contact`,
  `remove_contact`, `email_contact`) is handled by `StatusLive`, and the rows
  are pre-shaped there, so this stays presentational.

  Adding a contact lived on the Phone tab from 09-13 until the phone was removed
  (10-15, `PHONE_REMOVAL` D10). It is back here because this is the one place
  contacts are shown; a person is created and trusted in one step. The recent
  phone activity column, and the inert Text/Call buttons, left with the phone.

  Split out of `HomeWidget` on 08-15 (`WIDGET_BACKGROUND_ROADMAP` Phase 0).
  """
  use BusterClawWeb, :html

  attr :contacts, :list, required: true
  attr :adding_contact, :boolean, required: true
  attr :contact_error, :any, required: true
  attr :trusted, :list, required: true
  attr :entries, :list, required: true

  def comms_panel(assigns) do
    ~H"""
    <section id="home-comms-panel" class="ic-panel grid h-full grid-cols-2 overflow-hidden">
      <%!-- Left: contacts with an Email action; the + opens the add form. --%>
      <div class="flex min-h-0 flex-col border-r-2 border-base-content/20">
        <div class="flex shrink-0 items-center justify-between gap-2 border-b border-base-content/15 px-3 pb-2 pt-3">
          <p class="ic-eyebrow">Contacts</p>
          <button
            id="home-add-contact-toggle"
            type="button"
            phx-click="toggle_add_contact"
            title={if @adding_contact, do: "Cancel", else: "Add a contact"}
            aria-label={if @adding_contact, do: "Cancel adding a contact", else: "Add a contact"}
            aria-expanded={to_string(@adding_contact)}
            class="grid size-6 place-items-center rounded-xs text-base-content/50 transition hover:text-primary"
          >
            <.icon name={if @adding_contact, do: "hero-x-mark", else: "hero-plus"} class="size-3.5" />
          </button>
        </div>

        <form
          :if={@adding_contact}
          id="home-add-contact-form"
          phx-submit="add_contact"
          class="flex shrink-0 flex-col gap-1.5 border-b border-base-content/15 p-3"
        >
          <input
            type="text"
            name="name"
            placeholder="Name"
            required
            autocomplete="off"
            class="border-2 border-base-content/25 bg-base-100 px-2 py-1 font-mono text-sm"
          />
          <input
            type="email"
            name="email"
            placeholder="name@example.com"
            required
            autocomplete="off"
            class="border-2 border-base-content/25 bg-base-100 px-2 py-1 font-mono text-sm"
          />
          <p class="font-mono text-[10px] leading-relaxed text-base-content/40">
            Saved and trusted in one step: their mail becomes queue work.
          </p>
          <p :if={@contact_error} class="font-mono text-[10px] uppercase text-error">
            {@contact_error}
          </p>
          <button
            type="submit"
            class="border-2 border-base-content px-2 py-1 font-mono text-xs font-bold uppercase tracking-wider transition hover:bg-base-content hover:text-base-100"
          >
            Save contact
          </button>
        </form>

        <ul :if={@contacts != []} class="min-h-0 flex-1 space-y-2 overflow-y-auto p-3">
          <li :for={c <- @contacts} class="flex items-center gap-2">
            <span class="flex min-w-0 flex-1 items-center gap-1">
              <span
                :if={c.trusted?}
                title="Trusted"
                aria-label="Trusted"
                class="shrink-0 font-mono text-[0.625rem] font-bold text-success"
              >
                ✓
              </span>
              <span class="truncate font-display text-xs font-bold text-base-content">{c.name}</span>
            </span>
            <div class="flex shrink-0 items-center gap-1">
              <button
                :if={c.email}
                type="button"
                phx-click="email_contact"
                phx-value-id={c.id}
                title={"Email #{c.name} via the chat"}
                aria-label={"Email #{c.name}"}
                class="rounded-xs border border-primary/50 p-1 text-primary transition hover:bg-primary hover:text-primary-content"
              >
                <.icon name="hero-envelope" class="size-3.5" />
              </button>
            </div>
          </li>
        </ul>
        <p
          :if={@contacts == [] and not @adding_contact}
          class="p-3 font-mono text-[0.6875rem] text-base-content/55"
        >
          No contacts yet — press + to add one.
        </p>
      </div>

      <%!-- Right: trusted-sender allowlist (the chips render via TrustedContactsPanel). --%>
      <div id="home-contacts-panel" class="flex min-h-0 flex-col">
        <p class="ic-eyebrow shrink-0 border-b border-base-content/15 px-3 pb-2 pt-3">
          Trusted senders
        </p>
        <div class="min-h-0 flex-1 overflow-y-auto p-3">
          <BusterClawWeb.TrustedContactsPanel.panel contacts={@trusted} entries={@entries} />
        </div>
      </div>
    </section>
    """
  end
end
