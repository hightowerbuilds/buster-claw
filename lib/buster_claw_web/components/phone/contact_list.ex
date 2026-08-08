defmodule BusterClawWeb.Phone.ContactList do
  @moduledoc """
  The contact list, and the shaderface card a selection swaps in.

  Named `ContactList` rather than `Contacts` so it cannot be confused with
  `BusterClaw.Contacts`, the context it reads from.
  """
  use BusterClawWeb, :html

  import BusterClawWeb.Phone.Shared

  alias BusterClaw.Contacts
  attr :target, :any, required: true
  attr :contacts, :list, required: true
  attr :orphan_numbers, :list, required: true
  attr :selected_contact, :any, default: nil
  attr :contact_history, :list, required: true
  attr :contact_trusted, :boolean, required: true
  attr :adding_contact, :boolean, required: true
  attr :contact_error, :any, default: nil
  attr :face_shaders, :list, required: true

  @doc "The contact list, and the shaderface card a selection swaps in."
  def contacts(assigns) do
    ~H"""
    <%!-- Contacts: no background shader — the shaderface IS the shader.
            List view scrolls; selecting a contact swaps in the face card. --%>
    <section class="ic-panel relative isolate flex min-h-0 flex-1 flex-col overflow-hidden">
      <div class="relative z-10 flex min-h-0 flex-1 flex-col">
        <div class="ic-panel-h shrink-0">
          <span class="flex items-center gap-2">
            <button
              :if={@selected_contact}
              phx-click="close_contact"
              phx-target={@target}
              class="text-base-content/50 transition hover:text-base-content"
              title="Back to list"
            >
              <.icon name="hero-arrow-left" class="size-4" />
            </button>
            Contacts
          </span>
          <button
            :if={!@selected_contact}
            phx-click="toggle_add_contact"
            phx-target={@target}
            class="text-base-content/50 transition hover:text-base-content"
            title="Add contact"
          >
            <.icon
              name={if @adding_contact, do: "hero-x-mark", else: "hero-plus"}
              class="size-4"
            />
          </button>
          <button
            :if={@selected_contact}
            phx-click="delete_contact"
            phx-target={@target}
            data-claw-confirm="Remove this contact?"
            class="font-mono text-[10px] uppercase tracking-wider text-base-content/40 transition hover:text-error"
          >
            Remove
          </button>
        </div>

        <%!-- List view --%>
        <div
          :if={!@selected_contact}
          class="flex min-h-0 flex-1 flex-col gap-1.5 overflow-y-auto p-2"
        >
          <form
            :if={@adding_contact}
            phx-submit="add_contact"
            phx-target={@target}
            class="flex shrink-0 flex-col gap-1.5 border-2 border-base-content/20 p-2"
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
              type="tel"
              name="phone"
              placeholder="(503) 555-0142"
              autocomplete="off"
              class="border-2 border-base-content/25 bg-base-100 px-2 py-1 font-mono text-sm"
            />
            <input
              type="email"
              name="email"
              placeholder="name@example.com"
              autocomplete="off"
              class="border-2 border-base-content/25 bg-base-100 px-2 py-1 font-mono text-sm"
            />
            <p class="font-mono text-[10px] leading-relaxed text-base-content/40">
              One of the two is enough — the same contact answers both channels.
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

          <p
            :if={@contacts == [] and !@adding_contact}
            class="px-3 py-8 text-center font-mono text-xs uppercase tracking-wide text-base-content/50"
          >
            No contacts yet — add one with +
          </p>

          <button
            :for={contact <- @contacts}
            phx-click="select_contact"
            phx-target={@target}
            phx-value-id={contact.id}
            class="flex w-full shrink-0 items-center justify-between gap-2 border-2 border-base-content/20 px-3 py-2 text-left transition hover:border-base-content/60"
          >
            <span class="flex min-w-0 items-center gap-2">
              <span
                class={[
                  "size-1.5 shrink-0 rounded-full",
                  if(Contacts.trusted?(contact),
                    do: "bg-[#FF4D1C]",
                    else: "bg-base-content/20"
                  )
                ]}
                title={
                  if Contacts.trusted?(contact),
                    do: "Trusted — their messages reach the agent",
                    else: "Filed only — never reaches the agent"
                }
              />
              <span class="truncate font-mono text-sm font-bold">{contact.name}</span>
            </span>
            <span class="shrink-0 font-mono text-xs text-base-content/55">
              {contact.phone && format_phone(contact.phone)}
            </span>
          </button>

          <%!-- Live gate entries that no contact owns: a domain wildcard, or a
                  number the agent trusted over the CLI. Showing the contact list
                  alone would understate the real trust surface. --%>
          <div
            :if={@orphan_numbers != [] and !@adding_contact}
            class="shrink-0 border-t-2 border-base-content/15 pt-2"
          >
            <p class="px-1 pb-1 font-mono text-[10px] uppercase tracking-wider text-base-content/40">
              Trusted, no contact
            </p>
            <span
              :for={number <- @orphan_numbers}
              class="mr-1 inline-block border-2 border-[#FF4D1C]/50 px-1.5 py-0.5 font-mono text-[11px]"
            >
              {format_phone(number)}
            </span>
          </div>
        </div>

        <%!-- Face card --%>
        <div :if={@selected_contact} class="flex min-h-0 flex-1 flex-col">
          <div class="relative min-h-0 flex-1">
            <div
              id={face_id(@selected_contact)}
              phx-hook="ShaderFace"
              phx-update="ignore"
              data-seed={@selected_contact.face_seed / 10_000}
              data-shader-source={face_source(@selected_contact)}
              class="absolute inset-0"
            >
              <canvas data-face-canvas class="absolute inset-0 block h-full w-full"></canvas>
            </div>
            <div class="ic-glass absolute inset-x-2 bottom-2 border-2 border-base-content/20 px-3 py-1.5">
              <div class="truncate font-mono text-sm font-bold">{@selected_contact.name}</div>
              <div :if={@selected_contact.phone} class="font-mono text-xs text-base-content/60">
                {format_phone(@selected_contact.phone)}
              </div>
              <div
                :if={@selected_contact.email}
                class="truncate font-mono text-xs text-base-content/60"
              >
                {@selected_contact.email}
              </div>
            </div>
          </div>

          <%!-- The trust switch. It writes the markdown policy file, not this
                  contact's row — that is the only reason it means anything. --%>
          <div class="shrink-0 border-t-2 border-base-content/20 p-2">
            <button
              phx-click="toggle_trust"
              phx-target={@target}
              data-claw-confirm={
                if !@contact_trusted,
                  do:
                    "Trust #{@selected_contact.name}? Their voicemail and mail will become work the on-duty agent picks up and acts on.",
                  else: nil
              }
              class={[
                "flex w-full items-center justify-between border-2 px-3 py-2 text-left transition",
                if(@contact_trusted,
                  do: "border-[#FF4D1C] bg-[#FF4D1C]/10 hover:bg-[#FF4D1C]/20",
                  else: "border-base-content/25 hover:border-base-content/60"
                )
              ]}
            >
              <span class="flex flex-col">
                <span class="font-mono text-xs font-bold uppercase tracking-wider">
                  {if @contact_trusted, do: "Trusted", else: "Filed only"}
                </span>
                <span class="font-mono text-[10px] leading-tight text-base-content/50">
                  {if @contact_trusted,
                    do: "Reaches the agent's queue",
                    else: "Recorded, never queued"}
                </span>
              </span>
              <span class={[
                "size-3 shrink-0 rounded-full",
                if(@contact_trusted, do: "bg-[#FF4D1C]", else: "bg-base-content/20")
              ]} />
            </button>
          </div>

          <%!-- History: this contact's calls and voicemails. --%>
          <details
            :if={@contact_history != []}
            id="phone-contact-history"
            class="group max-h-36 shrink-0 overflow-y-auto border-t-2 border-base-content/20"
          >
            <summary
              id="phone-contact-history-toggle"
              class="flex cursor-pointer list-none items-center justify-between gap-2 px-3 py-2 font-mono text-[10px] font-bold uppercase tracking-wider text-base-content/50 transition hover:bg-base-content/5 hover:text-base-content focus-visible:outline-2 focus-visible:-outline-offset-2 focus-visible:outline-accent"
            >
              <span>Caller history</span>
              <span class="flex items-center gap-1.5">
                <span class="text-base-content/35">{length(@contact_history)}</span>
                <.icon
                  name="hero-chevron-down"
                  class="size-3 transition-transform group-open:rotate-180"
                />
              </span>
            </summary>
            <div
              id="phone-contact-history-items"
              class="border-t border-base-content/10 px-3 py-1.5"
            >
              <div
                :for={event <- @contact_history}
                class="flex items-baseline justify-between gap-2 py-0.5"
              >
                <span class="font-mono text-[11px] text-base-content/70">
                  {event_label(event)}
                </span>
                <span class="shrink-0 font-mono text-[10px] text-base-content/40">
                  {format_dt(event.occurred_at)}
                </span>
              </div>
            </div>
          </details>

          <div class="shrink-0 space-y-1 border-t-2 border-base-content/20 p-2">
            <form phx-change="set_face" phx-target={@target} class="flex items-center gap-2">
              <label class="font-mono text-[10px] uppercase tracking-wider text-base-content/50">
                Face
              </label>
              <select
                name="shader"
                class="flex-1 border-2 border-base-content/25 bg-base-100 px-1 py-0.5 font-mono text-xs"
              >
                <option value="" selected={is_nil(@selected_contact.face_shader)}>
                  Generative (seed {@selected_contact.face_seed})
                </option>
                <option
                  :for={name <- @face_shaders}
                  value={name}
                  selected={@selected_contact.face_shader == name}
                >
                  {name}
                </option>
              </select>
            </form>
            <p class="font-mono text-[10px] leading-relaxed text-base-content/40">
              Want a custom face? Ask Buster to design one — it lands in
              workspace/shaders/ and shows up in this picker.
            </p>
          </div>
        </div>
      </div>
    </section>
    """
  end
end
