defmodule BusterClawWeb.PhoneLive do
  @moduledoc """
  The Message Machine: BusterPhone's call/text log as a three-panel shader
  window — the log fills the left column; the right column divides into
  Playback (top) and Machine status (bottom). Every panel runs the built-in
  `waves` WGSL shader through its own `SmokeBackground` mount, with content
  glassed above it. Voicemails play inline from the Library
  (`/phone/recording`), SMS reads as per-number threads, and unheard voicemails
  are the blinking light — selecting one marks it heard. Live-updates from
  `BusterClaw.Telephony` broadcasts as the relay drain lands new events.
  """
  use BusterClawWeb, :live_view

  alias BusterClaw.Contacts
  alias BusterClaw.Telephony
  alias BusterClaw.Telephony.Event

  @filters [
    %{key: "all", label: "All"},
    %{key: "voicemail", label: "Voicemail"},
    %{key: "sms", label: "Texts"},
    %{key: "call", label: "Calls"}
  ]

  # Per-panel wave palettes (colA background / colB mid / colC crest), fed to
  # the shader as custom colors: bone greyscale behind the log so rows stay
  # readable, hazard orange for Playback (the star panel), signal blue for the
  # Machine readout.
  @wave_colors %{
    playback: "#160d09,#ff4d1c,#ffc9b3"
  }

  # Rotary dial geometry — real Western Electric layout. The finger stop sits at
  # 65° (4:30 on the clock face); hole `1` is nearest the stop (one pulse, the
  # shortest wind) and the digits run counter-clockwise up and around so `0`
  # lands at the bottom with the longest travel. SVG angles are y-down, so
  # positive = clockwise and hole angle = 35° − 30°·n; the clockwise wind needed
  # to reach the stop is 30° + 30°·n. Exchange letters ride under the digits
  # (no Q, no Z — just like the plate they're copied from).
  @dial_center 200
  @dial_hole_ring 122
  @dial_letters %{
    "2" => "ABC",
    "3" => "DEF",
    "4" => "GHI",
    "5" => "JKL",
    "6" => "MNO",
    "7" => "PRS",
    "8" => "TUV",
    "9" => "WXY",
    "0" => "OPER"
  }

  @dial_holes (for n <- 1..10 do
                 digit = if n == 10, do: "0", else: Integer.to_string(n)
                 radians = (35 - 30 * n) * :math.pi() / 180

                 %{
                   digit: digit,
                   travel: 30 + 30 * n,
                   x: Float.round(@dial_center + @dial_hole_ring * :math.cos(radians), 2),
                   y: Float.round(@dial_center + @dial_hole_ring * :math.sin(radians), 2),
                   letters: @dial_letters[digit]
                 }
               end)

  @max_dialed 15

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Telephony.subscribe()
      Contacts.subscribe()
    end

    {:ok,
     socket
     |> assign(:page_title, "Phone")
     |> assign(:filter, "all")
     |> assign(:selected_event, nil)
     |> assign(:selected_thread, nil)
     |> assign(:thread_messages, [])
     |> assign(:dialed, "")
     |> assign(:selected_contact, nil)
     |> assign(:adding_contact, false)
     |> assign(:contact_error, nil)
     |> assign(:contact_trusted, false)
     |> assign(:contact_history, [])
     |> assign(:face_shaders, BusterClaw.Shaders.list())
     |> load_contacts()
     |> load_data()}
  end

  @impl true
  def handle_event("filter", %{"kind" => kind}, socket)
      when kind in ["all", "voicemail", "sms", "call"] do
    {:noreply,
     socket
     |> assign(:filter, kind)
     |> assign(:selected_event, nil)
     |> assign(:selected_thread, nil)
     |> load_data()}
  end

  def handle_event("select_event", %{"id" => id}, socket) do
    event = Telephony.get_event!(id)

    event =
      case Telephony.mark_heard(event) do
        {:ok, heard} -> %{heard | document: event.document}
        _ -> event
      end

    {:noreply,
     socket
     |> assign(:selected_event, event)
     |> assign(:selected_thread, nil)
     |> load_data()}
  end

  def handle_event("select_thread", %{"number" => number}, socket) do
    {:noreply,
     socket
     |> assign(:selected_thread, number)
     |> assign(:thread_messages, Telephony.thread_messages(number))
     |> assign(:selected_event, nil)}
  end

  def handle_event("close_detail", _params, socket) do
    {:noreply,
     socket
     |> assign(:selected_event, nil)
     |> assign(:selected_thread, nil)}
  end

  def handle_event("dial_digit", %{"digit" => digit}, socket)
      when digit in ~w(0 1 2 3 4 5 6 7 8 9) do
    {:noreply,
     assign(socket, :dialed, String.slice(socket.assigns.dialed <> digit, 0, @max_dialed))}
  end

  def handle_event("dial_clear", _params, socket) do
    {:noreply, assign(socket, :dialed, "")}
  end

  def handle_event("select_contact", %{"id" => id}, socket) do
    {:noreply, select_contact(socket, Contacts.get_contact!(id))}
  end

  def handle_event("close_contact", _params, socket) do
    {:noreply,
     assign(socket,
       selected_contact: nil,
       contact_error: nil,
       contact_trusted: false,
       contact_history: []
     )}
  end

  def handle_event("toggle_add_contact", _params, socket) do
    {:noreply, assign(socket, adding_contact: !socket.assigns.adding_contact, contact_error: nil)}
  end

  def handle_event("add_contact", params, socket) do
    attrs = Map.take(params, ["name", "phone", "email"])

    case Contacts.create_contact(attrs) do
      {:ok, contact} ->
        {:noreply,
         socket
         |> assign(adding_contact: false, contact_error: nil)
         |> select_contact(contact)
         |> load_contacts()}

      {:error, changeset} ->
        {:noreply, assign(socket, :contact_error, first_error(changeset))}
    end
  end

  # The trust switch. It does not write to this contact's row — there is no trust
  # column to write to. It edits the markdown policy file that `Telephony.Drain`
  # and `GmailSync` actually consult, which is the only reason the toggle means
  # anything. See `BusterClaw.Contacts` for why trust is derived, not stored.
  def handle_event("toggle_trust", _params, socket) do
    case socket.assigns.selected_contact do
      nil ->
        {:noreply, socket}

      contact ->
        case Contacts.set_trusted(contact, !socket.assigns.contact_trusted) do
          {:ok, _} ->
            {:noreply, socket |> select_contact(contact) |> load_contacts()}

          {:error, reason} ->
            {:noreply,
             socket
             |> assign(:contact_error, "could not update trust: #{inspect(reason)}")
             |> select_contact(contact)}
        end
    end
  end

  def handle_event("set_face", %{"shader" => shader}, socket) do
    case socket.assigns.selected_contact do
      nil ->
        {:noreply, socket}

      contact ->
        face = if shader == "", do: nil, else: shader
        {:ok, updated} = Contacts.update_contact(contact, %{face_shader: face})

        {:noreply,
         socket
         |> select_contact(updated)
         |> assign(:face_shaders, BusterClaw.Shaders.list())
         |> load_contacts()}
    end
  end

  def handle_event("delete_contact", _params, socket) do
    case socket.assigns.selected_contact do
      nil ->
        {:noreply, socket}

      contact ->
        {:ok, _} = Contacts.delete_contact(contact)

        {:noreply,
         socket
         |> assign(selected_contact: nil, contact_trusted: false, contact_history: [])
         |> load_contacts()}
    end
  end

  @impl true
  def handle_info({:telephony_event, _event}, socket) do
    socket = load_data(socket)

    socket =
      case socket.assigns.selected_thread do
        nil -> socket
        number -> assign(socket, :thread_messages, Telephony.thread_messages(number))
      end

    {:noreply, socket}
  end

  def handle_info(:telephony_contacts_changed, socket) do
    {:noreply, load_contacts(socket)}
  end

  def handle_info(:contacts_changed, socket) do
    {:noreply, load_contacts(socket)}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  defp load_contacts(socket) do
    contacts = Contacts.list_contacts()

    socket
    |> assign(:contacts, contacts)
    |> assign(:contacts_by_number, Contacts.by_phone())
    |> assign(:orphan_numbers, Contacts.orphan_entries().numbers)
    |> refresh_selected_contact(contacts)
  end

  # Re-read the selected contact's derived state whenever the list moves, so the
  # detail pane can never show a stale trust badge (the policy file is edited by
  # the CLI and the agent too, not just by this tab).
  defp refresh_selected_contact(socket, contacts) do
    case socket.assigns[:selected_contact] do
      nil -> socket
      selected -> select_contact(socket, Enum.find(contacts, selected, &(&1.id == selected.id)))
    end
  end

  # Trust and history are *derived*, so they are recomputed on selection rather
  # than carried on the struct.
  defp select_contact(socket, contact) do
    assign(socket,
      selected_contact: contact,
      contact_trusted: Contacts.trusted?(contact),
      contact_history: Contacts.history(contact, 20)
    )
  end

  defp first_error(changeset) do
    changeset.errors
    |> Enum.map(fn {field, {message, _opts}} -> "#{field} #{message}" end)
    |> List.first() || "invalid contact"
  end

  defp load_data(socket) do
    kind =
      case socket.assigns.filter do
        "all" -> nil
        other -> other
      end

    socket
    |> assign(:stats, Telephony.stats())
    |> assign(
      :events,
      if(socket.assigns.filter == "sms",
        do: [],
        else: Telephony.list_events(kind: kind, limit: 200)
      )
    )
    |> assign(:threads, if(socket.assigns.filter == "sms", do: Telephony.sms_threads(), else: []))
  end

  # One wave-shader layer behind a panel. Hook-owned: LiveView never patches
  # inside (phx-update="ignore"); the SmokeBackground hook compiles the built-in
  # `waves` WGSL and drives the canvas itself. WebGPU missing → canvas stays
  # blank and the panel is just a panel.
  attr :id, :string, required: true
  attr :colors, :string, required: true

  defp shader_bg(assigns) do
    ~H"""
    <div
      id={@id}
      phx-hook="SmokeBackground"
      phx-update="ignore"
      data-shader="waves"
      data-custom="true"
      data-colors={@colors}
      class="ic-shader-fill"
      aria-hidden="true"
    >
      <canvas data-smoke-canvas></canvas>
    </div>
    """
  end

  # The antique instrument: a fine-grain SVG rotary dial living in the Playback
  # panel's resting state. The fingerwheel (`data-rotor`) is spun by the
  # RotaryDial hook; its ten finger holes and centre opening are true mask
  # cutouts, so the panel's wave shader blazes through the holes while the
  # wheel winds and returns. Digits + exchange letters print on the fixed
  # plate beneath, exactly like the real hardware.
  attr :holes, :list, required: true

  defp rotary_dial(assigns) do
    ~H"""
    <div
      id="rotary-dial"
      phx-hook="RotaryDial"
      phx-update="ignore"
      class="min-h-0 w-full max-w-[340px] flex-1 touch-none select-none"
    >
      <svg viewBox="0 0 400 400" class="mx-auto h-full w-full" role="img" aria-label="Rotary dialer">
        <defs>
          <linearGradient id="rd-bezel" x1="0" y1="0" x2="0" y2="1">
            <stop offset="0" stop-color="#52504c" />
            <stop offset="0.35" stop-color="#22211f" />
            <stop offset="0.7" stop-color="#3a3936" />
            <stop offset="1" stop-color="#161514" />
          </linearGradient>
          <linearGradient id="rd-chrome" x1="0" y1="0" x2="0" y2="1">
            <stop offset="0" stop-color="#e8e6df" />
            <stop offset="0.5" stop-color="#8d8b84" />
            <stop offset="1" stop-color="#d5d3cc" />
          </linearGradient>
          <radialGradient id="rd-wheel" cx="0.38" cy="0.32" r="0.9">
            <stop offset="0" stop-color="#2a2926" />
            <stop offset="0.65" stop-color="#191817" />
            <stop offset="1" stop-color="#0d0d0c" />
          </radialGradient>
          <radialGradient id="rd-card" cx="0.4" cy="0.35" r="0.9">
            <stop offset="0" stop-color="#f7f4ec" />
            <stop offset="1" stop-color="#dcd7c9" />
          </radialGradient>
          <filter id="rd-shadow" x="-20%" y="-20%" width="140%" height="140%">
            <feDropShadow dx="0" dy="5" stdDeviation="7" flood-color="#000" flood-opacity="0.55" />
          </filter>
          <mask id="rd-wheel-mask">
            <rect x="0" y="0" width="400" height="400" fill="white" />
            <circle :for={hole <- @holes} cx={hole.x} cy={hole.y} r="21" fill="black" />
            <circle cx="200" cy="200" r="66" fill="black" />
          </mask>
        </defs>

        <%!-- Bezel + fixed number plate. The plate is translucent so the wave
              shader glows through it; digits print on the plate and stay put
              while the fingerwheel spins over them. --%>
        <circle cx="200" cy="200" r="188" fill="url(#rd-bezel)" />
        <circle
          cx="200"
          cy="200"
          r="188"
          fill="none"
          stroke="#000"
          stroke-opacity="0.6"
          stroke-width="1.5"
        />
        <circle
          cx="200"
          cy="200"
          r="172"
          fill="#0c0c0c"
          fill-opacity="0.62"
          stroke="#000"
          stroke-opacity="0.5"
        />

        <g :for={hole <- @holes}>
          <text
            x={hole.x}
            y={hole.y + 7}
            text-anchor="middle"
            font-family="ui-monospace, monospace"
            font-size="21"
            font-weight="700"
            fill="#f4f1ea"
          >
            {hole.digit}
          </text>
          <text
            :if={hole.letters}
            x={hole.x}
            y={hole.y + 16}
            text-anchor="middle"
            font-family="ui-monospace, monospace"
            font-size="6"
            letter-spacing="1"
            fill="#f4f1ea"
            fill-opacity="0.6"
          >
            {hole.letters}
          </text>
        </g>

        <%!-- Fingerwheel: the rotor the hook spins. Finger holes + centre
              opening are cutouts — the shader shines straight through. --%>
        <g data-rotor data-cx="200" data-cy="200">
          <g filter="url(#rd-shadow)">
            <circle
              cx="200"
              cy="200"
              r="158"
              fill="url(#rd-wheel)"
              fill-opacity="0.94"
              mask="url(#rd-wheel-mask)"
            />
          </g>
          <g mask="url(#rd-wheel-mask)">
            <ellipse cx="150" cy="120" rx="120" ry="70" fill="#ffffff" fill-opacity="0.05" />
            <circle cx="200" cy="200" r="146" fill="none" stroke="#ffffff" stroke-opacity="0.05" />
            <circle cx="200" cy="200" r="98" fill="none" stroke="#ffffff" stroke-opacity="0.04" />
          </g>
          <circle
            cx="200"
            cy="200"
            r="158"
            fill="none"
            stroke="#000"
            stroke-opacity="0.55"
            stroke-width="1.5"
          />
          <g :for={hole <- @holes}>
            <circle
              cx={hole.x}
              cy={hole.y}
              r="21"
              fill="none"
              stroke="url(#rd-chrome)"
              stroke-width="2.5"
            />
            <circle
              cx={hole.x}
              cy={hole.y}
              r="22.5"
              fill="none"
              stroke="#000"
              stroke-opacity="0.5"
              stroke-width="1"
            />
            <circle
              cx={hole.x}
              cy={hole.y}
              r="27"
              fill="#fff"
              fill-opacity="0"
              data-digit={hole.digit}
              data-travel={hole.travel}
              class="cursor-grab"
              style="pointer-events: all;"
            />
          </g>
        </g>

        <%!-- Centre cap: fixed, wearing the subscriber card every desk set
              carried. --%>
        <circle cx="200" cy="200" r="64" fill="url(#rd-bezel)" filter="url(#rd-shadow)" />
        <circle cx="200" cy="200" r="56" fill="url(#rd-card)" />
        <circle cx="200" cy="200" r="56" fill="none" stroke="#8d8b84" stroke-width="1.5" />
        <text
          x="200"
          y="186"
          text-anchor="middle"
          font-family="ui-monospace, monospace"
          font-size="10"
          font-weight="700"
          letter-spacing="2"
          fill="#1a1a1a"
        >
          BUSTER
        </text>
        <text
          x="200"
          y="198"
          text-anchor="middle"
          font-family="ui-monospace, monospace"
          font-size="10"
          font-weight="700"
          letter-spacing="2"
          fill="#1a1a1a"
        >
          CLAW
        </text>
        <line x1="172" y1="205" x2="228" y2="205" stroke="#1a1a1a" stroke-opacity="0.25" />
        <text
          x="200"
          y="218"
          text-anchor="middle"
          font-family="ui-monospace, monospace"
          font-size="10"
          fill="#3a3a3a"
        >
          844·687·8016
        </text>

        <%!-- Finger stop, hooked over the rim at 65°. --%>
        <g transform="rotate(65 200 200)" filter="url(#rd-shadow)">
          <rect
            x="296"
            y="192"
            width="62"
            height="16"
            rx="8"
            fill="url(#rd-chrome)"
            stroke="#4a4a46"
            stroke-width="1"
          />
          <circle cx="350" cy="200" r="4" fill="#6b6963" />
        </g>
      </svg>
    </div>
    """
  end

  @impl true
  def render(assigns) do
    assigns =
      assign(assigns, filters: @filters, wave_colors: @wave_colors, dial_holes: @dial_holes)

    ~H"""
    <Layouts.app flash={@flash} full_bleed>
      <div class="flex h-full min-h-0 flex-col gap-3 p-3 lg:grid lg:grid-cols-5">
        <%!-- LEFT: full column — the log --%>
        <%!-- No background shader here — the clips themselves are the shader
              surface (one waveform pipeline per recording). --%>
        <section class="ic-panel relative isolate flex min-h-[22rem] flex-col overflow-hidden lg:col-span-3 lg:min-h-0">
          <div class="relative z-10 flex min-h-0 flex-1 flex-col">
            <div class="ic-panel-h ic-glass shrink-0">
              <span class="flex items-center gap-2">
                <span class="ic-eyebrow !mb-0">Message machine</span>
                <span :if={@stats.unheard > 0} class="ic-dot"></span>
              </span>
              <div class="flex items-center gap-1">
                <button
                  :for={f <- @filters}
                  phx-click="filter"
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
                    <span class="shrink-0 font-mono text-[10px] text-base-content/60">
                      {format_duration(event.duration_seconds || 0)} · {format_dt(event.occurred_at)}
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

        <%!-- RIGHT: divided column — Playback over Machine --%>
        <div class="flex min-h-0 flex-1 flex-col gap-3 lg:col-span-2">
          <section class="ic-panel relative isolate flex min-h-0 flex-1 flex-col overflow-hidden">
            <.shader_bg id="phone-waves-playback" colors={@wave_colors.playback} />
            <div class="relative z-10 flex min-h-0 flex-1 flex-col">
              <div class="ic-panel-h ic-glass shrink-0">
                <span>
                  {cond do
                    @selected_event -> event_label(@selected_event)
                    @selected_thread -> display_name(@contacts_by_number, @selected_thread)
                    true -> "Dial"
                  end}
                </span>
                <button
                  :if={@selected_event || @selected_thread}
                  phx-click="close_detail"
                  class="text-base-content/50 transition hover:text-base-content"
                  title="Close"
                >
                  <.icon name="hero-x-mark" class="size-4" />
                </button>
              </div>

              <div class="min-h-0 flex-1 overflow-y-auto p-3">
                <div
                  :if={!@selected_event and !@selected_thread}
                  class="flex h-full min-h-0 flex-col items-center gap-3"
                >
                  <div class="ic-glass flex w-full shrink-0 items-center justify-between border-2 border-base-content/20 px-4 py-2">
                    <span class="font-mono text-lg font-bold tracking-[0.3em] tabular-nums">
                      {format_dialed(@dialed)}
                    </span>
                    <button
                      :if={@dialed != ""}
                      phx-click="dial_clear"
                      title="Hang up"
                      class="font-mono text-[10px] uppercase tracking-wider text-base-content/50 transition hover:text-accent"
                    >
                      Hang up
                    </button>
                  </div>
                  <.rotary_dial holes={@dial_holes} />
                </div>

                <div
                  :if={@selected_event}
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

                <div :if={@selected_thread} class="space-y-3">
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

          <%!-- Contacts: no background shader — the shaderface IS the shader.
                List view scrolls; selecting a contact swaps in the face card. --%>
          <section class="ic-panel relative isolate flex min-h-0 flex-1 flex-col overflow-hidden">
            <div class="relative z-10 flex min-h-0 flex-1 flex-col">
              <div class="ic-panel-h shrink-0">
                <span class="flex items-center gap-2">
                  <button
                    :if={@selected_contact}
                    phx-click="close_contact"
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
                  data-confirm="Remove this contact?"
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
                    data-confirm={
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
                <div
                  :if={@contact_history != []}
                  class="max-h-32 shrink-0 overflow-y-auto border-t-2 border-base-content/20 p-2"
                >
                  <p class="pb-1 font-mono text-[10px] uppercase tracking-wider text-base-content/40">
                    History
                  </p>
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

                <div class="shrink-0 space-y-1 border-t-2 border-base-content/20 p-2">
                  <form phx-change="set_face" class="flex items-center gap-2">
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
        </div>
      </div>
    </Layouts.app>
    """
  end

  defp unheard?(%Event{kind: "voicemail", heard_at: nil}), do: true
  defp unheard?(_event), do: false

  # Keyed on heard-state so marking a voicemail heard remounts the AudioClip
  # hook (phx-update="ignore" otherwise pins the mount-time waveform color).
  defp clip_id(%Event{} = event) do
    if unheard?(event), do: "clip-#{event.id}-hot", else: "clip-#{event.id}"
  end

  # Keyed on the chosen face so switching Generative ↔ custom remounts the
  # ShaderFace hook (phx-update="ignore" pins whatever compiled at mount).
  defp face_id(contact), do: "face-#{contact.id}-#{contact.face_shader || "gen"}"

  defp face_source(%{face_shader: nil}), do: nil
  defp face_source(%{face_shader: name}), do: ~p"/shaders/#{name}"

  # A known contact shows by name everywhere; strangers stay as numbers.
  defp display_name(contacts, number) do
    case contacts[number] do
      %{name: name} -> name
      _ -> format_phone(number)
    end
  end

  defp kind_icon(%Event{kind: "voicemail"}), do: "hero-phone-arrow-down-left"
  defp kind_icon(%Event{kind: "sms", direction: "outbound"}), do: "hero-chat-bubble-left"
  defp kind_icon(%Event{kind: "sms"}), do: "hero-chat-bubble-left-ellipsis"
  defp kind_icon(%Event{}), do: "hero-phone"

  defp event_label(%Event{kind: "voicemail"}), do: "Voicemail"
  defp event_label(%Event{kind: "sms", direction: "outbound"}), do: "Text · Sent"
  defp event_label(%Event{kind: "sms"}), do: "Text"
  defp event_label(%Event{direction: "outbound"}), do: "Call · Out"
  defp event_label(%Event{}), do: "Call"

  defp preview(%Event{kind: "voicemail", transcript: transcript}) when is_binary(transcript),
    do: transcript

  defp preview(%Event{kind: "voicemail"}), do: "(no transcript yet)"
  defp preview(%Event{kind: "sms", body: body}), do: body
  defp preview(_event), do: nil

  defp format_dialed(""), do: "—"

  defp format_dialed(digits) do
    digits
    |> String.graphemes()
    |> Enum.chunk_every(3)
    |> Enum.map_join(" ", &Enum.join/1)
  end

  # NANP pretty-print; anything else (short codes, international) stays raw.
  defp format_phone("+1" <> <<a::binary-size(3), b::binary-size(3), c::binary-size(4)>>),
    do: "(#{a}) #{b}-#{c}"

  defp format_phone(number), do: number

  defp format_duration(seconds) when is_integer(seconds) do
    "#{div(seconds, 60)}:#{seconds |> rem(60) |> Integer.to_string() |> String.pad_leading(2, "0")}"
  end

  defp format_dt(%DateTime{} = dt), do: Elixir.Calendar.strftime(to_local(dt), "%b %d %H:%M")
  defp format_dt(_), do: ""

  defp format_dt_full(%DateTime{} = dt),
    do: Elixir.Calendar.strftime(to_local(dt), "%A, %B %d %Y · %H:%M")

  defp format_dt_full(_), do: ""

  # OS-local wall time via Erlang's tz handling — the app carries no tzdata dep,
  # and a phone log in UTC misreads ("who called me at 03:00?").
  defp to_local(%DateTime{} = dt) do
    dt
    |> DateTime.to_naive()
    |> NaiveDateTime.to_erl()
    |> :calendar.universal_time_to_local_time()
    |> NaiveDateTime.from_erl!()
  end
end
