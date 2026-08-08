defmodule BusterClawWeb.Phone.Log do
  @moduledoc """
  The call/text log — the left column, and the surface the voicemail clips
  render on.
  """
  use BusterClawWeb, :html

  import BusterClawWeb.Phone.Shared

  alias BusterClaw.Telephony
  attr :target, :any, required: true, doc: "the owning LiveComponent's @myself"
  attr :events, :list, required: true
  attr :threads, :list, required: true
  attr :filter, :string, required: true
  attr :filters, :list, required: true
  attr :stats, :map, required: true
  attr :selected_event, :any, default: nil
  attr :selected_thread, :any, default: nil
  attr :contacts_by_number, :map, required: true

  @doc "The call/text log — the left column, and the surface the clips render on."
  def event_log(assigns) do
    ~H"""
    <%!-- LEFT: full column — the log --%>
    <%!-- No background shader here — the clips themselves are the shader
            surface (one waveform pipeline per recording). --%>
    <section class="ic-panel relative isolate flex min-h-[22rem] flex-col overflow-hidden lg:col-span-3 lg:min-h-0">
      <div class="relative z-10 flex min-h-0 flex-1 flex-col">
        <div class="ic-panel-h ic-glass shrink-0">
          <span class="flex items-center gap-2">
            <span class="ic-eyebrow !mb-0">Message machine</span>
            <span :if={@stats.unheard > 0} class="ic-dot"></span>
            <span
              :if={@stats.spent_micros > 0}
              class="font-mono text-[10px] text-base-content/55"
              title="Total Twilio spend on voicemails"
            >
              {format_cost(@stats.spent_micros)}{if @stats.pending_cost > 0, do: "+"}
            </span>
            <button
              phx-click="refresh_costs"
              phx-target={@target}
              title="Refresh Twilio costs"
              aria-label="Refresh Twilio costs"
              class="text-base-content/40 transition hover:text-accent"
            >
              <.icon name="hero-arrow-path" class="size-3" />
            </button>
          </span>
          <div class="flex items-center gap-1">
            <button
              :for={f <- @filters}
              phx-click="filter"
              phx-target={@target}
              phx-value-kind={f.key}
              class={[
                "px-2 py-1 font-mono text-xs uppercase tracking-wide transition",
                if(@filter == f.key,
                  do: "border-b-2 border-current font-bold",
                  else: "text-base-content/50 hover:text-base-content"
                )
              ]}
            >
              {f.label}
            </button>
          </div>
        </div>

        <div class="flex min-h-0 flex-1 flex-col gap-2 overflow-y-auto p-3">
          <div
            :if={@filter != "sms" and @events == []}
            class="ic-glass border-2 border-base-content/20 px-5 py-10 text-center"
          >
            <p class="font-mono text-sm uppercase tracking-wide text-base-content/60">
              No messages. The machine is listening.
            </p>
          </div>

          <div :for={event <- @events} :if={@filter != "sms"} class="contents">
            <%!-- Recordings render as DAW regions: colored header strip,
                    real decoded waveform under a WGSL shader, transcript
                    footer. Everything else stays a plain row. --%>
            <button
              :if={event.recording_path}
              phx-click="select_event"
              phx-target={@target}
              phx-value-id={event.id}
              class={[
                "ic-glass w-full shrink-0 overflow-hidden rounded-[4px] border-2 text-left transition",
                if(@selected_event && @selected_event.id == event.id,
                  do: "border-accent",
                  else: "border-base-content/20 hover:border-base-content/60"
                )
              ]}
            >
              <div class={[
                "flex items-center justify-between gap-2 border-b px-2.5 py-1",
                if(unheard?(event),
                  do: "border-accent/40 bg-accent/20",
                  else: "border-base-content/15 bg-base-content/10"
                )
              ]}>
                <span class="flex min-w-0 items-center gap-1.5">
                  <span :if={unheard?(event)} class="ic-dot shrink-0"></span>
                  <span class="truncate font-mono text-[10px] font-bold uppercase tracking-wider">
                    {display_name(@contacts_by_number, Telephony.counterparty(event))} · {event_label(
                      event
                    )}
                  </span>
                </span>
                <span class="flex shrink-0 items-center gap-1.5 font-mono text-[10px]">
                  <span
                    :if={format_cost(event.cost_micros)}
                    class="rounded-sm bg-accent/20 px-1.5 py-0.5 font-bold text-accent"
                  >
                    {format_cost(event.cost_micros)}
                  </span>
                  <span class="text-base-content/60">
                    {format_duration(event.duration_seconds || 0)} · {format_dt(event.occurred_at)}
                  </span>
                </span>
              </div>
              <div
                id={clip_id(event)}
                phx-hook="AudioClip"
                phx-update="ignore"
                data-src={~p"/phone/recording?path=#{event.recording_path}"}
                data-color-a={if unheard?(event), do: "#ff4d1c", else: "#f4f1ea"}
                data-color-b={if unheard?(event), do: "#66210e", else: "#6b665c"}
                class="relative h-16 w-full"
              >
                <canvas data-clip-canvas class="absolute inset-0 h-full w-full"></canvas>
                <div
                  data-clip-fallback
                  class="absolute inset-x-3 inset-y-5 hidden opacity-30"
                  style="background: repeating-linear-gradient(90deg, currentColor 0 2px, transparent 2px 6px);"
                >
                </div>
              </div>
              <p
                :if={event.transcript}
                class="truncate border-t border-base-content/10 px-2.5 py-1 text-xs text-base-content/55"
              >
                {event.transcript}
              </p>
            </button>

            <button
              :if={!event.recording_path}
              phx-click={if event.kind == "sms", do: "select_thread", else: "select_event"}
              phx-target={@target}
              phx-value-id={event.id}
              phx-value-number={Telephony.counterparty(event)}
              class={[
                "ic-glass flex w-full shrink-0 items-center gap-3 border-2 px-4 py-3 text-left transition",
                if(@selected_event && @selected_event.id == event.id,
                  do: "border-accent",
                  else: "border-base-content/20 hover:border-base-content/60"
                )
              ]}
            >
              <.icon name={kind_icon(event)} class="size-5 shrink-0 opacity-70" />
              <div class="min-w-0 flex-1">
                <div class="flex items-center gap-2">
                  <span :if={unheard?(event)} class="ic-dot shrink-0"></span>
                  <span class="font-mono text-sm font-bold">
                    {display_name(@contacts_by_number, Telephony.counterparty(event))}
                  </span>
                  <span class="font-mono text-[10px] uppercase tracking-wider text-base-content/50">
                    {event_label(event)}
                  </span>
                </div>
                <p :if={preview(event)} class="truncate text-sm text-base-content/65">
                  {preview(event)}
                </p>
              </div>
              <div class="shrink-0 text-right">
                <div class="font-mono text-xs text-base-content/60">
                  {format_dt(event.occurred_at)}
                </div>
                <div :if={event.duration_seconds} class="font-mono text-xs text-base-content/40">
                  {format_duration(event.duration_seconds)}
                </div>
              </div>
            </button>
          </div>

          <div
            :if={@filter == "sms" and @threads == []}
            class="ic-glass border-2 border-base-content/20 px-5 py-10 text-center"
          >
            <p class="font-mono text-sm uppercase tracking-wide text-base-content/60">
              No text threads yet.
            </p>
          </div>

          <button
            :for={thread <- @threads}
            :if={@filter == "sms"}
            phx-click="select_thread"
            phx-target={@target}
            phx-value-number={thread.number}
            class={[
              "ic-glass flex w-full items-center gap-3 border-2 px-4 py-3 text-left transition",
              if(@selected_thread == thread.number,
                do: "border-accent",
                else: "border-base-content/20 hover:border-base-content/60"
              )
            ]}
          >
            <.icon name="hero-chat-bubble-left-right" class="size-5 shrink-0 opacity-70" />
            <div class="min-w-0 flex-1">
              <span class="font-mono text-sm font-bold">
                {display_name(@contacts_by_number, thread.number)}
              </span>
              <p class="truncate text-sm text-base-content/65">{thread.latest.body}</p>
            </div>
            <div class="shrink-0 text-right">
              <div class="font-mono text-xs text-base-content/60">
                {format_dt(thread.latest.occurred_at)}
              </div>
              <div class="font-mono text-xs text-base-content/40">
                {thread.count} msg{if thread.count != 1, do: "s"}
              </div>
            </div>
          </button>
        </div>
      </div>
    </section>
    """
  end
end
