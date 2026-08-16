defmodule BusterClawWeb.Widget.CommsPanel do
  @moduledoc """
  The corner widget's **Contacts** tab: a comms hub in three inline columns —
  contacts with per-person actions, recent phone activity, and the trusted-sender
  list.

  Markup only. Every event (`add_contact`, `remove_contact`, `email_contact`) is
  handled by `StatusLive`, and the rows are pre-shaped there, so this stays
  presentational.

  Split out of `HomeWidget` on 08-15 (`WIDGET_BACKGROUND_ROADMAP` Phase 0). That
  file was 699 lines and FROZEN — capped with no headroom — and three tabs
  sharing one file because they share a card is not a reason to keep them there.
  """
  use BusterClawWeb, :html

  attr :contacts, :list, required: true
  attr :activity, :list, required: true
  attr :show_add, :boolean, required: true
  attr :trusted, :list, required: true
  attr :entries, :list, required: true

  # The Contacts tab as a comms hub — three inline columns: contacts (with
  # per-person Text / Call / Email), recent phone activity, and the trusted-sender
  # list. Text and Call are inert for now (outbound telephony isn't wired — the
  # same decorative state as the /phone dialpad); Email drops a templated request
  # into the home chat, handled by StatusLive's `email_contact`. Rows/people are
  # pre-shaped by StatusLive, so this stays presentational.
  def comms_panel(assigns) do
    ~H"""
    <section id="home-comms-panel" class="ic-panel grid h-full grid-cols-3 overflow-hidden">
      <%!-- Left: contacts with per-person Text / Call / Email actions. --%>
      <div class="flex min-h-0 flex-col border-r-2 border-base-content/20">
        <div class="flex shrink-0 items-center justify-between gap-2 border-b border-base-content/15 px-3 pb-2 pt-3">
          <p class="ic-eyebrow">Contacts</p>
          <button
            type="button"
            phx-click="toggle_add_contact"
            aria-expanded={to_string(@show_add)}
            title="Add a trusted sender"
            aria-label="Add contact"
            class={[
              "inline-flex shrink-0 items-center gap-1 rounded-xs border px-1.5 py-0.5 font-mono text-[0.625rem] font-bold uppercase tracking-wide transition",
              if(@show_add,
                do: "border-primary text-primary",
                else: "border-base-content/25 text-base-content/55 hover:text-base-content"
              )
            ]}
          >
            <.icon name="hero-plus" class="size-3" /> Add
          </button>
        </div>

        <form
          :if={@show_add}
          phx-submit="add_contact"
          class="flex shrink-0 items-center gap-1.5 border-b border-base-content/15 px-3 py-2"
        >
          <input
            type="text"
            name="entry"
            value=""
            autocomplete="off"
            spellcheck="false"
            placeholder="alice@example.com · *@acme.com"
            class="input input-xs min-w-0 flex-1 font-mono text-[0.6875rem]"
          />
          <button
            type="submit"
            class="shrink-0 rounded-xs bg-primary px-2 py-1 font-display text-[0.625rem] font-bold uppercase tracking-wide text-primary-content transition hover:opacity-85"
          >
            Add
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
              <%!-- Inert: outbound telephony isn't wired. `title` is a hover
                    tooltip only, so these carry an aria-label too — otherwise the
                    accessible name is empty (the icons are decorative) and the
                    "not built" state is reachable by mouse alone. --%>
              <button
                :if={c.phone}
                type="button"
                disabled
                aria-disabled="true"
                title="Texting isn't available yet"
                aria-label={"Text #{c.name} — not available yet"}
                class="cursor-not-allowed rounded-xs border border-base-content/20 p-1 text-base-content/35"
              >
                <.icon name="hero-chat-bubble-left-ellipsis" class="size-3.5" />
              </button>
              <button
                :if={c.phone}
                type="button"
                disabled
                aria-disabled="true"
                title="Calling isn't available yet"
                aria-label={"Call #{c.name} — not available yet"}
                class="cursor-not-allowed rounded-xs border border-base-content/20 p-1 text-base-content/35"
              >
                <.icon name="hero-phone" class="size-3.5" />
              </button>
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
        <p :if={@contacts == []} class="p-3 font-mono text-[0.6875rem] text-base-content/55">
          No contacts yet.
        </p>
      </div>

      <%!-- Middle: recent phone activity (voicemails, texts, calls). --%>
      <div class="flex min-h-0 flex-col border-r-2 border-base-content/20">
        <p class="ic-eyebrow shrink-0 border-b border-base-content/15 px-3 pb-2 pt-3">
          Recent activity
        </p>
        <ul :if={@activity != []} class="min-h-0 flex-1 space-y-1.5 overflow-y-auto p-3">
          <li :for={row <- @activity} class="flex items-baseline gap-2 font-mono text-[0.6875rem]">
            <span class="shrink-0 text-base-content/45" title={row.title}>{row.mark}</span>
            <span class="shrink-0 truncate font-bold text-base-content">{row.label}</span>
            <span class="min-w-0 flex-1 truncate text-base-content/60">{row.snippet}</span>
            <span class="shrink-0 text-base-content/45">{row.when}</span>
          </li>
        </ul>
        <p :if={@activity == []} class="p-3 font-mono text-[0.6875rem] text-base-content/50">
          No recent phone activity.
        </p>
      </div>

      <%!-- Right: trusted-sender allowlist (the chips render via TrustedContactsPanel;
            add lives with the Contacts header's "+ Add"). --%>
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
