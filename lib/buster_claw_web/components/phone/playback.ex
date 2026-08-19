defmodule BusterClawWeb.Phone.Playback do
  @moduledoc """
  Playback, over the telephone-keypad WGSL shader.

  ## There is no keypad here any more

  BusterPhone is intake-only (`PHONE_INTAKE_ROADMAP`): outbound calling and
  outbound SMS are deleted, not switched off. The dialpad that used to sit on
  this shader existed to *originate* — dial a number, search a contact for one,
  press Call — and with nothing to originate it would have gone back to being
  decoration, which is the exact state `LAUNCH_ROADMAP` G-37 refused. So it was
  deleted rather than relabelled.

  **The shader stays**, and it is still the `keypad` one: it is the backdrop of
  the Playback panel, not a control surface, and the ids below name the shader
  region rather than a thing you can press.
  """
  use BusterClawWeb, :html

  import BusterClawWeb.Phone.Shared

  alias BusterClaw.Telephony

  attr :target, :any, required: true
  attr :selected_event, :any, default: nil
  attr :selected_thread, :any, default: nil
  attr :thread_messages, :list, required: true
  attr :contacts_by_number, :map, required: true
  attr :wave_colors, :map, required: true

  @doc "A voicemail, a text thread, or the bare shader when nothing is selected."
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
          <%!-- Idle: the shader and nothing else. Nothing is pressable here —
                the buttons that were are gone with outbound, and this panel's
                job is to play back what came IN, chosen from the log beside it.
                A control on this stage would have to originate something, and
                there is nothing left to originate. --%>
          <.shader_bg
            id="phone-keypad-playback"
            shader="keypad"
            colors={@wave_colors.playback}
          />

          <p
            id="phone-playback-idle"
            class="absolute inset-x-4 top-3 z-10 font-mono text-[10px] uppercase tracking-wide text-base-content/40"
          >
            Pick a voicemail or a thread from the log
          </p>
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
              <%!-- Voicemails, which are what the back-fill prices now, plus
                    the outbound-call rows already in the ledger — those stay as
                    a true record of what happened and keep showing their cost,
                    even though nothing creates another one. An SMS row has no
                    cost to show and an inbound call row is not something this
                    app created. --%>
              <div
                :if={priced_kind?(@selected_event)}
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

          <%!-- The outbound branch stays even though nothing sends any more.
                `direction: "outbound"` rows already in the ledger are a true
                record of texts that were sent, and a thread that rendered them
                as the other party's words would be a lie about who said what. --%>
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
