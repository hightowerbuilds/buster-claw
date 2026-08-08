defmodule BusterClawWeb.PhoneComponent do
  @moduledoc """
  The Message Machine: BusterPhone's call/text log as a shader window — the log
  fills the left column; the right column divides into Playback (top, over the
  telephone `keypad` WGSL shader) and Contacts (bottom). Voicemails play inline from the
  Library (`/phone/recording`) and show their Twilio cost (back-filled — see
  `VOICEMAIL_COST_ROADMAP.md`), SMS reads as per-number threads, and unheard
  voicemails are the blinking light — selecting one marks it heard. Live-updates
  from `BusterClaw.Telephony` broadcasts as the relay drain lands new events and
  cost back-fills settle.

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
  alias BusterClaw.Telephony
  alias BusterClaw.Telephony.Event
  alias BusterClawWeb.Phone.ContactList
  alias BusterClawWeb.Phone.Log, as: PhoneLog
  alias BusterClawWeb.Phone.Playback

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
    socket
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
    |> load_data()
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

  @impl true
  def render(assigns) do
    assigns = assign(assigns, filters: @filters, wave_colors: @wave_colors)

    ~H"""
    <div id={"#{@id}-root"} class="flex h-full min-h-0 flex-col gap-3 p-3 lg:grid lg:grid-cols-5">
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

      <%!-- RIGHT: divided column — Playback over Machine --%>
      <div class="flex min-h-0 flex-1 flex-col gap-3 lg:col-span-2">
        <Playback.playback
          target={@myself}
          keypad_keys={@keypad_keys}
          dialed_number={@dialed_number}
          dial_match={@dial_match}
          selected_event={@selected_event}
          selected_thread={@selected_thread}
          selected_contact={@selected_contact}
          thread_messages={@thread_messages}
          contacts_by_number={@contacts_by_number}
          wave_colors={@wave_colors}
        />

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
