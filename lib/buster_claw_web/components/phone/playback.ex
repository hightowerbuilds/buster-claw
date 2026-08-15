defmodule BusterClawWeb.Phone.Playback do
  @moduledoc """
  Playback and the dialpad, over the telephone-keypad WGSL shader.
  """
  use BusterClawWeb, :html

  import BusterClawWeb.Phone.Shared

  alias BusterClaw.Telephony
  alias BusterClawWeb.Phone.CallAction

  attr :target, :any, required: true
  attr :keypad_keys, :list, required: true
  attr :dialed_number, :string, required: true
  attr :dial_match, :any, default: nil
  attr :voice_ready, :any, required: true
  attr :caller_id, :string, default: nil
  attr :pending_call, :any, default: nil
  attr :call_error, :string, default: nil
  attr :call_notice, :string, default: nil
  attr :selected_event, :any, default: nil
  attr :selected_thread, :any, default: nil
  attr :selected_contact, :any, default: nil
  attr :thread_messages, :list, required: true
  attr :contacts_by_number, :map, required: true
  attr :wave_colors, :map, required: true

  @doc "Playback and the dialpad, over the telephone-keypad WGSL shader."
  def playback(assigns) do
    ~H"""
    <section class="ic-panel relative isolate flex min-h-0 flex-1 flex-col overflow-hidden">
      <div class="relative z-10 flex min-h-0 flex-1 flex-col">
        <div class="ic-panel-h ic-glass shrink-0">
          <span>
            {cond do
              @selected_event -> event_label(@selected_event)
              @selected_thread -> display_name(@contacts_by_number, @selected_thread)
              true -> "Playback"
            end}
          </span>
          <button
            :if={@selected_event || @selected_thread}
            id="phone-close-detail"
            phx-click="close_detail"
            phx-target={@target}
            class="text-base-content/50 transition hover:text-base-content"
            title="Close"
          >
            <.icon name="hero-x-mark" class="size-4" />
          </button>
        </div>

        <div
          :if={!@selected_event and !@selected_thread}
          id="phone-keypad-stage"
          class="relative min-h-0 flex-1 overflow-hidden"
        >
          <.shader_bg
            id="phone-keypad-playback"
            shader="keypad"
            colors={@wave_colors.playback}
          />

          <div class="absolute inset-x-4 top-3 z-10">
            <div class="flex min-h-9 items-center gap-2 border-b-2 border-base-content/20 pb-2">
              <span
                id="phone-dialed-number"
                class="min-w-0 flex-1 truncate font-mono text-lg font-bold tracking-normal text-base-content"
              >
                {if @dialed_number == "",
                  do: "Enter a number",
                  else: format_dialed(@dialed_number)}
              </span>
              <button
                :if={@dialed_number != ""}
                id="phone-dial-clear"
                type="button"
                phx-click="dial_clear"
                phx-target={@target}
                class="grid size-8 shrink-0 place-items-center text-base-content/45 transition hover:bg-base-content/10 hover:text-base-content focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-accent"
                title="Clear number"
                aria-label="Clear number"
              >
                <.icon name="hero-x-mark" class="size-4" />
              </button>
              <button
                :if={@dialed_number != ""}
                id="phone-dial-backspace"
                type="button"
                phx-click="dial_backspace"
                phx-target={@target}
                class="grid size-8 shrink-0 place-items-center text-base-content/45 transition hover:bg-base-content/10 hover:text-base-content focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-accent"
                title="Delete last digit"
                aria-label="Delete last digit"
              >
                <.icon name="hero-backspace" class="size-4" />
              </button>
            </div>

            <%!-- The keypad is a dialer now — `phone_call` shipped 08-15 — but it
                  is still also a contact search, and it is still off until the
                  operator sets the voice switch. `CallAction` owns both halves of
                  that disclosure and the button itself; see its moduledoc for why
                  the G-37 line narrowed rather than went away. --%>
            <CallAction.call_action
              target={@target}
              dialed_number={@dialed_number}
              selected_contact={@selected_contact}
              voice_ready={@voice_ready}
              caller_id={@caller_id}
              pending_call={@pending_call}
              call_error={@call_error}
              call_notice={@call_notice}
            />

            <button
              :if={@dial_match && (!@selected_contact || @selected_contact.id != @dial_match.id)}
              id="phone-dial-match"
              type="button"
              phx-click="select_contact"
              phx-target={@target}
              phx-value-id={@dial_match.id}
              class="mt-2 flex w-full items-center justify-between gap-3 border-l-2 border-accent px-2 py-1 text-left transition hover:bg-accent/10 focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-accent"
            >
              <span class="min-w-0 truncate font-mono text-xs font-bold">
                {@dial_match.name}
              </span>
              <span class="shrink-0 font-mono text-[11px] text-base-content/60">
                {format_phone(@dial_match.phone)}
              </span>
            </button>

            <div
              :if={@selected_contact && @selected_contact.phone}
              id="phone-contact-actions"
              class="mt-2 grid grid-cols-2 gap-2"
            >
              <button
                id="phone-contact-text"
                type="button"
                disabled
                aria-disabled="true"
                class="flex h-8 cursor-not-allowed items-center justify-center gap-2 border-2 border-base-content/15 bg-base-100/30 font-mono text-[11px] font-bold uppercase text-base-content/40"
                title="Outbound texting is not enabled yet"
              >
                <.icon name="hero-chat-bubble-left-right" class="size-3.5" /> Text
              </button>
              <%!-- Text is still inert and Call no longer is, which is the whole
                    A2P story in two buttons: outbound SMS waits on a registration
                    at Twilio, outbound voice never needed one. --%>
              <button
                id="phone-contact-call"
                type="button"
                disabled={@voice_ready != :ok}
                aria-disabled={to_string(@voice_ready != :ok)}
                phx-click={@voice_ready == :ok && "call_prompt"}
                phx-target={@target}
                phx-value-number={@selected_contact.phone}
                class={[
                  "flex h-8 items-center justify-center gap-2 border-2 font-mono text-[11px] font-bold uppercase transition",
                  if(@voice_ready == :ok,
                    do: "border-accent bg-accent/15 text-base-content hover:bg-accent/30",
                    else:
                      "cursor-not-allowed border-base-content/15 bg-base-100/30 text-base-content/40"
                  )
                ]}
              >
                <.icon name="hero-phone" class="size-3.5" /> Call
              </button>
            </div>

            <p
              :if={@dialed_number != "" and is_nil(@dial_match) and is_nil(@selected_contact)}
              id="phone-dial-no-match"
              class="mt-2 px-2 font-mono text-[10px] uppercase tracking-wide text-base-content/40"
            >
              No contact match
            </p>
          </div>

          <div
            id="phone-keypad-controls"
            phx-hook="Dtmf"
            data-sound-on={to_string(BusterClaw.Notifications.Sound.enabled?())}
            class="absolute bottom-[4%] left-1/2 z-10 grid h-[66%] max-w-[86%] -translate-x-1/2 grid-cols-3 grid-rows-4 aspect-[0.78]"
            aria-label="Contact number search keypad"
          >
            <button
              :for={key <- @keypad_keys}
              id={"phone-dial-key-#{if key == "*", do: "star", else: if(key == "#", do: "hash", else: key)}"}
              type="button"
              phx-click="dial_key"
              phx-target={@target}
              phx-value-key={key}
              class="grid min-h-0 min-w-0 place-items-center bg-transparent transition hover:bg-accent/10 active:bg-accent/25 focus-visible:outline-2 focus-visible:-outline-offset-2 focus-visible:outline-accent"
              aria-label={"Enter #{if key == "*", do: "star", else: if(key == "#", do: "hash", else: key)}"}
            >
              <span class="sr-only">{key}</span>
            </button>
          </div>
        </div>

        <div
          :if={@selected_event || @selected_thread}
          id="phone-message-detail"
          class="min-h-0 flex-1 overflow-y-auto p-3"
        >
          <div
            :if={@selected_event}
            id="phone-event-player"
            class="ic-glass space-y-4 border-2 border-base-content/20 p-4"
          >
            <div>
              <div class="font-mono text-xl font-bold">
                {display_name(@contacts_by_number, Telephony.counterparty(@selected_event))}
              </div>
              <div class="font-mono text-xs uppercase tracking-wide text-base-content/50">
                {format_dt_full(@selected_event.occurred_at)}
                <span :if={@selected_event.duration_seconds}>
                  · {format_duration(@selected_event.duration_seconds)}
                </span>
              </div>
              <div
                :if={@selected_event.kind == "voicemail"}
                class="mt-2 flex items-center gap-2"
              >
                <span class="ic-eyebrow !mb-0">Cost</span>
                <span
                  :if={format_cost(@selected_event.cost_micros)}
                  class="font-mono text-sm font-bold text-accent"
                >
                  {format_cost(@selected_event.cost_micros)}
                  <span
                    :if={is_nil(@selected_event.cost_synced_at)}
                    class="text-[10px] font-normal uppercase text-base-content/45"
                  >
                    (pricing…)
                  </span>
                </span>
                <span
                  :if={is_nil(@selected_event.cost_micros)}
                  class="font-mono text-xs text-base-content/45"
                >
                  pricing…
                </span>
                <.cost_breakdown event={@selected_event} />
              </div>
            </div>

            <audio
              :if={@selected_event.recording_path}
              controls
              preload="metadata"
              class="w-full"
              src={~p"/phone/recording?path=#{@selected_event.recording_path}"}
            >
            </audio>

            <div :if={@selected_event.transcript}>
              <p class="ic-eyebrow">Transcript</p>
              <blockquote class="mt-2 border-l-4 border-base-content/20 pl-3 text-sm leading-relaxed text-base-content/80">
                {@selected_event.transcript}
              </blockquote>
            </div>

            <p
              :if={@selected_event.direction == "inbound"}
              class="font-mono text-[10px] uppercase tracking-wider text-base-content/40"
            >
              Untrusted caller input — fenced like email bodies.
            </p>
          </div>

          <div :if={@selected_thread} id="phone-text-thread" class="space-y-3">
            <div
              :for={message <- @thread_messages}
              class={[
                "max-w-[85%]",
                message.direction == "outbound" && "ml-auto"
              ]}
            >
              <div class={[
                "border-2 px-3 py-2 text-sm",
                if(message.direction == "outbound",
                  do: "border-base-content bg-base-content text-base-100",
                  else: "ic-glass border-base-content/25"
                )
              ]}>
                {message.body}
              </div>
              <div class={[
                "mt-1 font-mono text-[10px] uppercase tracking-wider text-base-content/50",
                message.direction == "outbound" && "text-right"
              ]}>
                {if message.direction == "outbound",
                  do: "Buster",
                  else: display_name(@contacts_by_number, message.from_number)} · {format_dt(
                  message.occurred_at
                )}
              </div>
            </div>
          </div>
        </div>
      </div>
    </section>
    """
  end
end
