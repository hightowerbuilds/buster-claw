defmodule BusterClawWeb.Vox.Messages do
  @moduledoc """
  Vox2B's **Notes to yourself** panel: named lines, spoken in the operator's own
  voice, fired as notifications.

  Moved here from Settings → Notify on 09-05 (`VOX_TAB_ROADMAP` Phase 2). It was
  built there because a spoken message *is* a notification — which is true of how
  it FIRES and wrong about where you make one. Everything upstream of the firing
  is voice work: it needs the engine, it needs the reference clip, and it is
  judged by listening. Notify keeps the routing table, which is its job; the lines
  live with the voice that speaks them.

  ## Preview needs its own hook mount

  The Preview button carries `data-preview-url` and is played by the `SoundPreview`
  hook, which is a **delegated** click listener — it fires for any descendant of
  the element it is mounted on. On Settings → Notify that element wraps the whole
  page, so the button worked by being inside it. Here the panel mounts its own,
  because a delegated listener that no longer contains the button is a control
  that silently stops working and looks fine.
  """
  use BusterClawWeb, :html

  @doc "The spoken-messages panel."
  attr :messages, :list, required: true
  attr :form, :map, required: true
  attr :note, :string, default: nil
  attr :id, :string, required: true
  attr :target, :any, required: true

  def panel(assigns) do
    ~H"""
    <section class="ic-vox-section" id={"#{@id}-messages"} phx-hook="SoundPreview">
      <h3>Notes to yourself</h3>
      <p class="ic-vox-hint">
        A line, spoken in your voice and kept as a sound. Fire it now or set it for later — it
        arrives like any other notification, with the words on screen. The agent can leave you
        one too: <code class="text-xs">voice_message_create</code>
        and <code class="text-xs">voice_message_fire</code>.
      </p>

      <div class="flex flex-col gap-3 text-sm">
        <form phx-submit="message_create" phx-target={@target} class="flex flex-col gap-2">
          <div class="grid gap-2 sm:grid-cols-[12rem_1fr]">
            <input
              type="text"
              name="message[name]"
              value={@form["name"]}
              placeholder="stand-up"
              maxlength="41"
              class="input input-bordered input-xs font-mono text-xs"
            />
            <input
              type="text"
              name="message[text]"
              value={@form["text"]}
              placeholder="Stand up and stretch."
              maxlength="300"
              class="input input-bordered input-xs text-sm"
            />
          </div>
          <div class="flex flex-wrap items-center gap-2">
            <button type="submit" class="btn btn-primary btn-xs">Make it</button>
            <span class="ic-vox-note">{@note}</span>
          </div>
        </form>

        <ul :if={@messages != []} class="flex flex-col gap-1.5">
          <li :for={msg <- @messages} class="flex flex-wrap items-center gap-2">
            <span class="w-28 shrink-0 truncate font-mono text-[0.6875rem] text-base-content/55">
              {msg.name}
            </span>
            <span class="min-w-0 flex-1 truncate text-xs">{msg.text}</span>

            <%= if msg.ready? do %>
              <button
                type="button"
                data-preview-url={~p"/notify/sound/#{msg.sound}"}
                class="btn btn-ghost btn-xs"
                aria-label={"Preview #{msg.name}"}
              >
                Preview
              </button>
              <button
                type="button"
                phx-click="message_fire"
                phx-target={@target}
                phx-value-name={msg.name}
                class="btn btn-ghost btn-xs"
              >
                Fire now
              </button>
              <button
                type="button"
                phx-click="message_fire"
                phx-target={@target}
                phx-value-name={msg.name}
                phx-value-in_seconds="600"
                class="btn btn-ghost btn-xs"
              >
                In 10 min
              </button>
            <% else %>
              <%!-- No `Progress.chip` here, deliberately. Readiness is read off
                    DISK on every re-list rather than tracked as a job, so this
                    panel does not know when its render started and cannot honestly
                    show a clock. "making…" is the whole of what it knows. --%>
              <span class="ic-vox-note">making…</span>
            <% end %>

            <button
              type="button"
              phx-click="message_delete"
              phx-target={@target}
              phx-value-name={msg.name}
              data-claw-confirm={"Delete “#{msg.name}”?"}
              class="btn btn-ghost btn-xs text-error"
              aria-label={"Delete #{msg.name}"}
            >
              Delete
            </button>
          </li>
        </ul>
      </div>
    </section>
    """
  end
end
