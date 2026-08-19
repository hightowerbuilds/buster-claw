defmodule BusterClawWeb.PhoneComponent do
  @moduledoc """
  The Message Machine: BusterPhone's call/text log as a shader window, behind a
  two-tab rail. **Messages** is the log (left) beside Playback (right, over the
  telephone `keypad` WGSL shader); **Contacts** is the address book and the
  shaderface card, which gets the whole panel rather than the bottom third of a
  column. Voicemails play inline from the
  Library (`/phone/recording`) and show their Twilio cost (back-filled — see
  `VOICEMAIL_COST_ROADMAP.md`), SMS reads as per-number threads, and unheard
  voicemails are the blinking light — selecting one marks it heard. Live-updates
  from `BusterClaw.Telephony` broadcasts as the relay drain lands new events and
  cost back-fills settle.

  The tab rail also prints the BusterPhone number itself — `Twilio.caller_id/0`,
  rendered at the DOM id `<id>-caller-id`. An intake-only phone is only useful if
  you can tell someone what to dial, and until 08-18 the app displayed its own
  number nowhere.

  ## An embeddable component, and why

  This renders inline with no layout of its own, so a host page provides the
  chrome. Two hosts use it: `BusterClawWeb.PhoneLive` (the `/phone` route and the
  split-pane view) and `BusterClawWeb.StatusLive` (the homepage "Phone" sub-tab).
  Keeping the behavior here means both surfaces stay in sync — the same reason
  `CalendarComponent` exists.

  ## The host contract

  A `LiveComponent` has no process, so it cannot subscribe or receive messages.
  **The host subscribes and forwards**, using two functions defined here so no
  host has to hand-roll the message shapes:

    * `notify/2` — forward a `Telephony`/`Contacts` broadcast.
    * The reload timer: this component asks its host to ping it back via
      `{__MODULE__, :reload, id}`, because `Process.send_after(self(), ...)` from
      a component lands in the *host's* mailbox. The debounce decision stays
      here; the host only relays.

  Hosts deliberately subscribe rather than having this component call
  `Telephony.subscribe/0` in `update/2`: a component shares its host's process,
  so a host that already subscribes (`StatusLive` does) would receive every
  broadcast twice.

  ## Assigns

  The host passes only `id`. Everything else is owned here, and initialization is
  guarded by `:loaded` so a host's unrelated re-renders — the homepage streams
  chat and ticks the sky — never reset the operator's selection.
  """
  use BusterClawWeb, :live_component

  alias BusterClaw.Contacts
  alias BusterClaw.Pockets.Faces
  alias BusterClaw.Telephony
  alias BusterClaw.Telephony.Event
  alias BusterClaw.Telephony.Twilio
  alias BusterClawWeb.Phone.ContactList
  alias BusterClawWeb.Phone.Log, as: PhoneLog
  alias BusterClawWeb.Phone.Playback
  alias BusterClawWeb.Phone.Registry

  # The one thing borrowed from the panels' shared display helpers: the header
  # prints the operator's own number, and it must be punctuated the same way
  # every caller's number in the log below it is.
  import BusterClawWeb.Phone.Shared, only: [format_phone: 1]

  # The sub-tab whitelist, read at COMPILE TIME from the same list the rail
  # renders — a `when` guard cannot call a remote function, and that constraint
  # is the point: the rail and the guard cannot become two literals that drift.
  # See `Registry`'s moduledoc for the 08-08 fault this prevents.
  @tab_keys Registry.tab_keys()

  @filters [
    %{key: "all", label: "All"},
    %{key: "voicemail", label: "Voicemail"},
    %{key: "sms", label: "Texts"},
    %{key: "call", label: "Calls"}
  ]

  # Shader palette for the Playback panel (base / accent / highlight), fed as
  # custom colors — hazard orange over near-black. The shader is still the
  # `keypad` one; it is the panel's backdrop, and it outlived the keypad that
  # `PHONE_INTAKE_ROADMAP` deleted along with outbound calling.
  @wave_colors %{
    playback: "#160d09,#ff4d1c,#ffc9b3"
  }

  @doc """
  Forward a host's `Telephony`/`Contacts` broadcast, or the reload ping. See the
  moduledoc: the host owns the subscription, this component owns the response.
  """
  def notify(id, message), do: send_update(__MODULE__, id: id, notify: message)

  @impl true
  def update(%{notify: message}, socket), do: {:ok, handle_notify(message, socket)}

  def update(assigns, socket) do
    socket = assign(socket, assigns)

    if socket.assigns[:loaded] do
      {:ok, socket}
    else
      {:ok, socket |> assign(:loaded, true) |> load_initial()}
    end
  end

  defp load_initial(socket) do
    # On-demand, per the workspace registry: the faces Pocket is created when the
    # operator opens the surface that owns it, never at install. Idempotent, and
    # it never overwrites a manifest they have edited.
    Faces.ensure()

    socket
    |> assign(:tab, "messages")
    |> assign(:filter, "all")
    # The number to give out. Read once here rather than on every reload: it is a
    # Clinch/env lookup, it changes only when an operator edits Settings, and an
    # intake-only phone whose own number appears nowhere is a machine you cannot
    # tell anyone how to reach.
    |> assign(:caller_id, Twilio.caller_id())
    |> assign(:selected_event, nil)
    |> assign(:selected_thread, nil)
    |> assign(:thread_messages, [])
    |> assign(:selected_contact, nil)
    |> assign(:adding_contact, false)
    |> assign(:contact_error, nil)
    |> assign(:contact_trusted, false)
    |> assign(:contact_history, [])
    |> assign(:reload_queued, false)
    |> assign(:face_shaders, Faces.choices())
    |> load_contacts()
    |> load_data()
  end

  @impl true
  def handle_event("select_phone_tab", %{"tab" => tab}, socket) when tab in @tab_keys do
    {:noreply, assign(socket, :tab, tab)}
  end

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

  # Manual "refresh costs" — back-fill Twilio prices now rather than waiting for
  # the drain tick. No-op (with a hint) when Twilio isn't configured.
  def handle_event("refresh_costs", _params, socket) do
    socket =
      if Twilio.configured?() do
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
    {:noreply, select_contact(socket, contact)}
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
         |> assign(:face_shaders, Faces.choices())
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
  # Every message a host forwards. Kept as one function so the set of broadcasts
  # this component understands is readable in one place, and an unrecognised one
  # is ignored rather than crashing a host that over-forwards.
  defp handle_notify({:telephony_event, _event}, socket), do: schedule_reload(socket)
  defp handle_notify(:telephony_costs_updated, socket), do: schedule_reload(socket)
  defp handle_notify(:telephony_contacts_changed, socket), do: load_contacts(socket)
  defp handle_notify(:contacts_changed, socket), do: load_contacts(socket)

  defp handle_notify(:reload, socket) do
    socket = socket |> assign(:reload_queued, false) |> load_data()

    case socket.assigns.selected_thread do
      nil -> socket
      number -> assign(socket, :thread_messages, Telephony.thread_messages(number))
    end
  end

  defp handle_notify(_message, socket), do: socket

  @reload_debounce_ms 250

  defp schedule_reload(%{assigns: %{reload_queued: true}} = socket), do: socket

  defp schedule_reload(socket) do
    # `self()` here is the HOST's process — a component has none. The host relays
    # this back through `notify/2`; see the moduledoc's host contract.
    Process.send_after(self(), {__MODULE__, :reload, socket.assigns.id}, @reload_debounce_ms)
    assign(socket, :reload_queued, true)
  end

  defp load_contacts(socket) do
    contacts = Contacts.list_contacts()

    socket
    |> assign(:contacts, contacts)
    |> assign(:contacts_by_number, Contacts.by_phone(contacts))
    |> assign(:orphan_numbers, Contacts.orphan_entries(contacts).numbers)
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

  # `nil` is a real state with its own sentence. "No number configured" says the
  # app has not been told its number; an empty label would read as the phone not
  # having one, which is a different (and usually wrong) fact.
  defp caller_id_label(nil), do: "No number configured"
  defp caller_id_label(number), do: "Your number: " <> format_phone(number)

  defp caller_id_hint(nil), do: "Set the Twilio Phone Number in Settings → Clinch"
  defp caller_id_hint(_number), do: "The BusterPhone number people reach you on"

  # One shader layer behind a panel. Hook-owned: LiveView never patches inside
  # (phx-update="ignore"); the SmokeBackground hook compiles the named built-in
  # WGSL and drives the canvas itself. WebGPU missing → canvas stays blank and
  # the panel is just a panel.
  attr :id, :string, required: true
  attr :colors, :string, required: true
  attr :shader, :string, default: "waves"

  @impl true
  def render(assigns) do
    assigns =
      assign(assigns, filters: @filters, wave_colors: @wave_colors, tabs: Registry.tabs())

    ~H"""
    <div id={"#{@id}-root"} class="flex h-full min-h-0 flex-col gap-3 p-3">
      <%!-- The rail shares its bottom rule with the number readout, so the border
            lives on this wrapper and the tabs keep their -mb-0.5 overlap. --%>
      <div class="flex shrink-0 items-end justify-between gap-3 border-b-2 border-base-content/20">
        <div role="tablist" aria-label="Phone" class="flex flex-wrap gap-1">
          <button
            :for={t <- @tabs}
            type="button"
            role="tab"
            title={t.blurb}
            aria-selected={to_string(@tab == t.key)}
            phx-click="select_phone_tab"
            phx-target={@myself}
            phx-value-tab={t.key}
            class={[
              "-mb-0.5 border-b-2 px-3 py-1.5 font-display text-xs font-bold uppercase tracking-wide transition",
              if(@tab == t.key,
                do: "border-primary text-primary",
                else: "border-transparent text-base-content/55 hover:text-base-content"
              )
            ]}
          >
            {t.label}
          </button>
        </div>

        <%!-- The number to give out. An unset number says so in words: an empty
              label would read as "no number exists", which is a different fact
              from "nobody has told this app what its number is". --%>
        <p
          id={"#{@id}-caller-id"}
          data-caller-id={@caller_id}
          title={caller_id_hint(@caller_id)}
          class="shrink-0 truncate pb-1.5 pr-1 font-mono text-[0.6875rem] text-base-content/55"
        >
          {caller_id_label(@caller_id)}
        </p>
      </div>

      <%!-- Messages: the log beside Playback. Both panels are `:if`-ed rather
            than hidden, so their `phx-update="ignore"` shader canvases are torn
            down and remounted on a tab switch instead of animating unseen. --%>
      <div
        :if={@tab == "messages"}
        data-phone-tab="messages"
        class="flex min-h-0 flex-1 flex-col gap-3 lg:grid lg:grid-cols-5"
      >
        <PhoneLog.event_log
          target={@myself}
          events={@events}
          threads={@threads}
          filter={@filter}
          filters={@filters}
          stats={@stats}
          selected_event={@selected_event}
          selected_thread={@selected_thread}
          contacts_by_number={@contacts_by_number}
        />

        <div class="flex min-h-0 flex-1 flex-col gap-3 lg:col-span-2">
          <Playback.playback
            target={@myself}
            selected_event={@selected_event}
            selected_thread={@selected_thread}
            thread_messages={@thread_messages}
            contacts_by_number={@contacts_by_number}
            wave_colors={@wave_colors}
          />
        </div>
      </div>

      <div
        :if={@tab == "contacts"}
        data-phone-tab="contacts"
        class="flex min-h-0 flex-1 flex-col"
      >
        <ContactList.contacts
          target={@myself}
          contacts={@contacts}
          orphan_numbers={@orphan_numbers}
          selected_contact={@selected_contact}
          contact_history={@contact_history}
          contact_trusted={@contact_trusted}
          adding_contact={@adding_contact}
          contact_error={@contact_error}
          face_shaders={@face_shaders}
        />
      </div>
    </div>
    """
  end
end
