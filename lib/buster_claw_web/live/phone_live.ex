defmodule BusterClawWeb.PhoneLive do
  @moduledoc """
  The Message Machine: BusterPhone's call/text log as a shader window — the log
  fills the left column; the right column divides into Playback (top, over the
  telephone `keypad` WGSL shader) and Contacts (bottom). Voicemails play inline from the
  Library (`/phone/recording`) and show their Twilio cost (back-filled — see
  `VOICEMAIL_COST_ROADMAP.md`), SMS reads as per-number threads, and unheard
  voicemails are the blinking light — selecting one marks it heard. Live-updates
  from `BusterClaw.Telephony` broadcasts as the relay drain lands new events and
  cost back-fills settle.
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

  @keypad_keys ~w(1 2 3 4 5 6 7 8 9 * 0 #)

  # Shader palette for the Playback panel (base / accent / highlight), fed as
  # custom colors — hazard orange over near-black behind the keypad.
  @wave_colors %{
    playback: "#160d09,#ff4d1c,#ffc9b3"
  }

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Telephony.subscribe()
      Contacts.subscribe()
    end

    {:ok,
     socket
     |> assign(:page_title, "Phone")
     |> assign(:keypad_keys, @keypad_keys)
     |> assign(:filter, "all")
     |> assign(:selected_event, nil)
     |> assign(:selected_thread, nil)
     |> assign(:thread_messages, [])
     |> assign(:dialed_number, "")
     |> assign(:dial_match, nil)
     |> assign(:selected_contact, nil)
     |> assign(:adding_contact, false)
     |> assign(:contact_error, nil)
     |> assign(:contact_trusted, false)
     |> assign(:contact_history, [])
     |> assign(:reload_queued, false)
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

  def handle_event("dial_key", %{"key" => key}, socket) when key in @keypad_keys do
    dialed_number =
      if String.length(socket.assigns.dialed_number) < 15,
        do: socket.assigns.dialed_number <> key,
        else: socket.assigns.dialed_number

    {:noreply, assign_dial(socket, dialed_number)}
  end

  def handle_event("dial_backspace", _params, socket) do
    length = max(String.length(socket.assigns.dialed_number) - 1, 0)
    dialed_number = String.slice(socket.assigns.dialed_number, 0, length)
    {:noreply, assign_dial(socket, dialed_number)}
  end

  def handle_event("dial_clear", _params, socket) do
    {:noreply, assign_dial(socket, "")}
  end

  # Manual "refresh costs" — back-fill Twilio prices now rather than waiting for
  # the drain tick. No-op (with a hint) when Twilio isn't configured.
  def handle_event("refresh_costs", _params, socket) do
    socket =
      if BusterClaw.Telephony.Twilio.configured?() do
        Telephony.refresh_unpriced_costs()
        load_data(socket)
      else
        put_flash(
          socket,
          :error,
          "Twilio isn't configured — set TWILIO_ACCOUNT_SID / TWILIO_AUTH_TOKEN."
        )
      end

    {:noreply, socket}
  end

  def handle_event("select_contact", %{"id" => id}, socket) do
    contact = Contacts.get_contact!(id)

    {:noreply,
     socket
     |> select_contact(contact)
     |> select_contact_number(contact)}
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
         |> select_contact_number(contact)
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

  # Telephony broadcasts arrive in bursts — the drain tick can land several
  # events back-to-back — so reloads are coalesced: the first message arms a
  # short timer, the rest ride along, and one `:reload_telephony` does the
  # actual re-query.
  @impl true
  def handle_info({:telephony_event, _event}, socket) do
    {:noreply, schedule_reload(socket)}
  end

  def handle_info(:telephony_costs_updated, socket) do
    {:noreply, schedule_reload(socket)}
  end

  def handle_info(:reload_telephony, socket) do
    socket =
      socket
      |> assign(:reload_queued, false)
      |> load_data()

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

  @reload_debounce_ms 250

  defp schedule_reload(%{assigns: %{reload_queued: true}} = socket), do: socket

  defp schedule_reload(socket) do
    Process.send_after(self(), :reload_telephony, @reload_debounce_ms)
    assign(socket, :reload_queued, true)
  end

  defp load_contacts(socket) do
    contacts = Contacts.list_contacts()

    socket
    |> assign(:contacts, contacts)
    |> assign(:contacts_by_number, Contacts.by_phone(contacts))
    |> assign(:orphan_numbers, Contacts.orphan_entries(contacts).numbers)
    |> assign(:dial_match, closest_contact(contacts, socket.assigns[:dialed_number] || ""))
    |> refresh_selected_contact(contacts)
  end

  defp assign_dial(socket, dialed_number) do
    assign(socket,
      dialed_number: dialed_number,
      dial_match: closest_contact(socket.assigns.contacts, dialed_number)
    )
  end

  defp select_contact_number(socket, %{phone: phone}) when is_binary(phone) do
    assign_dial(socket, national_digits(phone))
  end

  defp select_contact_number(socket, _contact), do: socket

  defp closest_contact(_contacts, ""), do: nil

  defp closest_contact(contacts, dialed_number) do
    query = digits_only(dialed_number)

    if query == "" do
      nil
    else
      contacts
      |> Enum.reject(&is_nil(&1.phone))
      |> Enum.map(&{dial_match_score(&1.phone, query), &1})
      |> Enum.reject(fn {score, _contact} -> is_nil(score) end)
      |> Enum.max_by(fn {score, contact} -> {score, contact.name} end, fn -> nil end)
      |> case do
        nil -> nil
        {_score, contact} -> contact
      end
    end
  end

  defp dial_match_score(phone, query) do
    full = digits_only(phone)
    national = national_digits(phone)

    cond do
      String.starts_with?(national, query) -> {3, -String.length(national)}
      String.starts_with?(full, query) -> {2, -String.length(full)}
      String.contains?(national, query) -> {1, -String.length(national)}
      true -> nil
    end
  end

  defp digits_only(value), do: String.replace(value, ~r/\D/, "")

  defp national_digits(phone) do
    digits = digits_only(phone)

    if String.starts_with?(digits, "1") and byte_size(digits) == 11,
      do: binary_part(digits, 1, 10),
      else: digits
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
    |> refresh_selected_event()
  end

  # Re-fetch the open voicemail so its detail (cost especially) tracks back-fill
  # updates that arrive while it's selected.
  defp refresh_selected_event(socket) do
    case socket.assigns[:selected_event] do
      %Event{id: id} -> assign(socket, :selected_event, Telephony.get_event(id) || nil)
      _ -> socket
    end
  end

  # One shader layer behind a panel. Hook-owned: LiveView never patches inside
  # (phx-update="ignore"); the SmokeBackground hook compiles the named built-in
  # WGSL and drives the canvas itself. WebGPU missing → canvas stays blank and
  # the panel is just a panel.
  attr :id, :string, required: true
  attr :colors, :string, required: true
  attr :shader, :string, default: "waves"

  defp shader_bg(assigns) do
    ~H"""
    <div
      id={@id}
      phx-hook="SmokeBackground"
      phx-update="ignore"
      data-shader={@shader}
      data-custom="true"
      data-colors={@colors}
      class="ic-shader-fill"
      aria-hidden="true"
    >
      <canvas data-smoke-canvas></canvas>
    </div>
    """
  end

  # The three components of a voicemail's cost (call leg / recording /
  # transcription), from the back-filled `metadata["cost_breakdown"]`. Shown small
  # under the total so the operator can see *where* the money goes — the point of
  # the whole feature (transcription is usually the driver).
  attr :event, :map, required: true

  defp cost_breakdown(assigns) do
    parts =
      case assigns.event.metadata do
        %{"cost_breakdown" => %{} = b} ->
          [{"call", b["call"]}, {"rec", b["recording"]}, {"txt", b["transcription"]}]
          |> Enum.filter(fn {_label, micros} -> is_integer(micros) end)

        _ ->
          []
      end

    assigns = assign(assigns, :parts, parts)

    ~H"""
    <span
      :if={@parts != []}
      class="font-mono text-[10px] text-base-content/45"
    >
      ({Enum.map_join(@parts, " + ", fn {label, micros} -> "#{label} #{format_cost(micros)}" end)})
    </span>
    """
  end

  @impl true
  def render(assigns) do
    assigns = assign(assigns, filters: @filters, wave_colors: @wave_colors)

    ~H"""
    <Layouts.app flash={@flash} socket={@socket} full_bleed>
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
                <span
                  :if={@stats.spent_micros > 0}
                  class="font-mono text-[10px] text-base-content/55"
                  title="Total Twilio spend on voicemails"
                >
                  {format_cost(@stats.spent_micros)}{if @stats.pending_cost > 0, do: "+"}
                </span>
                <button
                  phx-click="refresh_costs"
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
                      class="grid size-8 shrink-0 place-items-center text-base-content/45 transition hover:bg-base-content/10 hover:text-base-content focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-accent"
                      title="Delete last digit"
                      aria-label="Delete last digit"
                    >
                      <.icon name="hero-backspace" class="size-4" />
                    </button>
                  </div>

                  <button
                    :if={
                      @dial_match && (!@selected_contact || @selected_contact.id != @dial_match.id)
                    }
                    id="phone-dial-match"
                    type="button"
                    phx-click="select_contact"
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
                    <button
                      id="phone-contact-call"
                      type="button"
                      disabled
                      aria-disabled="true"
                      class="flex h-8 cursor-not-allowed items-center justify-center gap-2 border-2 border-base-content/15 bg-base-100/30 font-mono text-[11px] font-bold uppercase text-base-content/40"
                      title="Outbound calling is not enabled yet"
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
                  class="absolute bottom-[4%] left-1/2 z-10 grid h-[66%] max-w-[86%] -translate-x-1/2 grid-cols-3 grid-rows-4 aspect-[0.78]"
                  aria-label="Contact number search keypad"
                >
                  <button
                    :for={key <- @keypad_keys}
                    id={"phone-dial-key-#{if key == "*", do: "star", else: if(key == "#", do: "hash", else: key)}"}
                    type="button"
                    phx-click="dial_key"
                    phx-value-key={key}
                    class="grid min-h-0 min-w-0 place-items-center bg-transparent transition hover:bg-accent/10 active:bg-accent/25 focus-visible:outline-2 focus-visible:-outline-offset-2 focus-visible:outline-accent"
                    aria-label={"Dial #{if key == "*", do: "star", else: if(key == "#", do: "hash", else: key)}"}
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

  # NANP pretty-print; anything else (short codes, international) stays raw.
  defp format_phone("+1" <> <<a::binary-size(3), b::binary-size(3), c::binary-size(4)>>),
    do: "(#{a}) #{b}-#{c}"

  defp format_phone(number), do: number

  defp format_dialed(<<a::binary-size(3), b::binary-size(3), c::binary-size(4)>>),
    do: "(#{a}) #{b}-#{c}"

  defp format_dialed(number), do: number

  defp format_duration(seconds) when is_integer(seconds) do
    "#{div(seconds, 60)}:#{seconds |> rem(60) |> Integer.to_string() |> String.pad_leading(2, "0")}"
  end

  # Micro-USD → a dollar string, up to 4 decimals with trailing zeros trimmed but
  # at least cents (2 places). So a 24¢ total reads "$0.24" while a sub-cent
  # component like the call leg still reads "$0.0085" instead of rounding to
  # "$0.01". `nil` (not priced yet) → nil; the caller renders "pricing…".
  defp format_cost(micros) when is_integer(micros) do
    "$" <> ((micros / 1_000_000) |> :erlang.float_to_binary(decimals: 4) |> trim_cost_zeros())
  end

  defp format_cost(_nil), do: nil

  defp trim_cost_zeros(str) do
    [whole, frac] = String.split(str, ".")
    frac = String.trim_trailing(frac, "0") |> String.pad_trailing(2, "0")
    "#{whole}.#{frac}"
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
