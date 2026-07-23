defmodule BusterClawWeb.StatusLive do
  use BusterClawWeb, :live_view

  alias BusterClaw.Agent.Chat
  alias BusterClaw.Agent.Conversations
  alias BusterClaw.Agent.Transcript, as: AgentTranscript
  alias BusterClaw.Appearance
  alias BusterClaw.Contacts
  alias BusterClaw.LocalTime
  alias BusterClaw.Notifications
  alias BusterClaw.Runtime.Status
  alias BusterClaw.Setup
  alias BusterClaw.SvgViewer
  alias BusterClaw.Telephony
  alias BusterClaw.Trading
  alias BusterClaw.TrustedSenders
  alias BusterClaw.Weather

  # Cap the retained in-memory transcript / SVG bank on the always-open home tab
  # so a long-lived session can't grow its assigns unbounded (oldest drop off the
  # front). The rendered history stays generous; the persisted transcript is the
  # source of truth and is re-read on tab-switch / reload.
  @max_chat_messages 200
  @max_chat_svgs 200

  # How often the homepage sky (weather-shader background) re-checks real
  # conditions. Matches Weather's cache TTL, so each tick is at most one fetch.
  @sky_refresh_ms :timer.minutes(10)

  @impl true
  def mount(_params, _session, socket) do
    today = LocalTime.today()

    if connected?(socket) do
      Phoenix.PubSub.subscribe(BusterClaw.PubSub, Appearance.home_topic())
      Notifications.subscribe()
      # Keep the corner-widget's "Recent activity" live as calls/texts land.
      Telephony.subscribe()
      Process.send_after(self(), :sky_refresh, @sky_refresh_ms)
    end

    {:ok,
     socket
     |> assign(:page_title, "Home")
     |> assign(:home_bg, Appearance.home_background_state())
     |> assign(status: Status.snapshot())
     |> assign(:today, today)
     |> assign(:setup_status, Setup.status())
     # Gate the composer proactively: discovering the missing CLI by typing into
     # a silent void was the review's worst day-one failure.
     |> assign(:agent_cli_missing, match?({:error, _}, BusterClaw.AgentRunner.detect()))
     |> load_trust()
     |> load_comms()
     # Home main view: "chat" (default) or "calendar". The sub-tab toggle swaps
     # the whole panel — the chat is hidden while the calendar is showing.
     |> assign(:home_tab, "chat")
     # Header widget: which sub-tab is showing. Order is Time & Place / Contacts /
     # Notify, and Time & Place leads (its analog clock renders instantly, and
     # `mount_weather/1` fills conditions on connect).
     |> assign(:widget_tab, "place")
     # The "add a trusted sender" input is collapsed behind the Contacts header's
     # + button; hidden until toggled so the tab stays uncluttered.
     |> assign(:show_add_contact, false)
     |> assign(:weather, nil)
     |> assign(:weather_form, false)
     |> assign(:notify_form, notify_form())
     |> assign(:notify_kind, "timer")
     |> load_notifications()
     |> init_chats()
     |> then(fn s -> if connected?(s), do: mount_weather(s), else: s end)}
  end

  # Load the open conversations (tabs), subscribe to each so background runs update
  # the tab badges, and show the most recent one's transcript.
  defp init_chats(socket) do
    chats = Conversations.list() |> Enum.map(&to_chat_tab/1)
    active = (List.first(chats) || %{id: Chat.default_conv_id()}).id

    if connected?(socket) do
      Enum.each(chats, &Chat.subscribe(&1.id))
      # The Trading tab's pinned conversation has no Conversations row (so it
      # never shows in the chat strip) but still streams over PubSub.
      Chat.subscribe(Trading.conv_id())
    end

    socket
    |> assign(:chats, chats)
    |> assign(:active_chat, active)
    # Where to return when leaving the Trading tab (the last ordinary chat).
    |> assign(:last_chat, active)
    |> assign(:trading_unread, false)
    # Agentic-account panel: nil | {:loading, prev} | {:ok, snap} |
    # {:error, reason, prev} — prev = last good snapshot (or nil), kept visible
    # under the spinner/error line instead of blanking real data.
    |> assign(:trading_account, nil)
    |> assign(:chat_running, Chat.running?(active))
    |> assign(:chat_thinking, nil)
    |> assign(:chat_queue, Chat.queue(active))
    |> assign(:zoomed_id, nil)
    # The transcript is a stream: appends send one bubble, not the whole list,
    # and the server doesn't hold 200 messages per socket. dom_id matches the
    # ids chat_bubble always rendered.
    |> stream_configure(:chat_messages, dom_id: &"chat-msg-#{&1.id}")
    |> load_chat_history(active)
  end

  defp to_chat_tab(conv), do: %{id: conv.id, title: conv.title, running: false, unread: false}

  # The gate, split into the part with a person behind it and the part without.
  # Both halves are rendered — see `TrustedContactsPanel` for why omitting the
  # orphans would understate the trust surface.
  #
  # Trust is read from the policy files on every load rather than cached in the
  # socket, because this tab is not the only writer: the `/phone` view, the
  # `phone_trusted_*` commands, and the agent editing the markdown directly all
  # move the same gate.
  defp load_trust(socket) do
    people = Enum.filter(Contacts.list_contacts(), &Contacts.email_trusted?/1)

    socket
    |> assign(:trusted_people, people)
    |> assign(:trusted_entries, Contacts.orphan_entries().emails)
  end

  # The corner-widget "Contacts" tab is a comms hub: recent phone activity plus
  # the contact list (with a trusted marker) and per-person actions. Both are
  # pre-shaped here so HomeWidget stays presentational.
  defp load_comms(socket) do
    contacts = Contacts.list_contacts()
    names = Contacts.by_phone(contacts)

    people =
      Enum.map(contacts, fn c ->
        %{id: c.id, name: c.name, phone: c.phone, email: c.email, trusted?: Contacts.trusted?(c)}
      end)

    activity = Enum.map(Telephony.list_events(limit: 6), &activity_row(&1, names))

    socket
    |> assign(:comms_contacts, people)
    |> assign(:phone_activity, activity)
  end

  # Shape one telephony event into a compact widget row: the other party's name
  # (or bare number), a direction mark + human title, a one-line snippet, and a
  # relative timestamp.
  defp activity_row(event, names) do
    number = Telephony.counterparty(event)

    label =
      case Map.get(names, number) do
        %{name: name} -> name
        _ -> number || "Unknown"
      end

    %{
      id: event.id,
      label: label,
      mark: if(event.direction == "outbound", do: "↗", else: "↙"),
      title: "#{String.capitalize(event.direction)} #{kind_label(event.kind)}",
      snippet: activity_snippet(event),
      when: relative_time(event.occurred_at)
    }
  end

  defp kind_label("voicemail"), do: "voicemail"
  defp kind_label("sms"), do: "text"
  defp kind_label("call"), do: "call"
  defp kind_label(other), do: other

  defp activity_snippet(%{kind: "sms", body: body}) when is_binary(body), do: snip(body)

  defp activity_snippet(%{kind: "voicemail", transcript: t}) when is_binary(t) and t != "",
    do: snip(t)

  defp activity_snippet(%{kind: "voicemail"}), do: "voicemail"
  defp activity_snippet(%{kind: "call"}), do: "call"
  defp activity_snippet(_), do: ""

  defp snip(text) do
    text = String.trim(text)
    if String.length(text) > 60, do: String.slice(text, 0, 60) <> "…", else: text
  end

  # A coarse relative timestamp for the activity feed ("3m", "2h", "5d"); older
  # than a week falls back to a short date. occurred_at is UTC; so is now/0.
  defp relative_time(nil), do: ""

  defp relative_time(%DateTime{} = dt) do
    seconds = DateTime.diff(now(), dt, :second)

    cond do
      seconds < 60 -> "now"
      seconds < 3600 -> "#{div(seconds, 60)}m"
      seconds < 86_400 -> "#{div(seconds, 3600)}h"
      seconds < 604_800 -> "#{div(seconds, 86_400)}d"
      true -> Elixir.Calendar.strftime(dt, "%b %-d")
    end
  end

  # --- Notify widget ---------------------------------------------------------

  defp load_notifications(socket), do: assign(socket, :notifications, Notifications.upcoming())

  defp notify_form, do: to_form(%{"label" => "", "minutes" => "", "at" => ""}, as: :notify)

  defp assign_notify_error(socket, params, field, message) do
    assign(socket, :notify_form, to_form(params, as: :notify, errors: [{field, {message, []}}]))
  end

  defp parse_minutes(value) do
    case value |> to_string() |> String.trim() |> Integer.parse() do
      {minutes, _rest} when minutes > 0 -> minutes
      _ -> :error
    end
  end

  # An alarm's label is optional — a bedside clock doesn't need naming — so a
  # blank one becomes "Alarm" (the schema and the list/modal require a label).
  # Timers and reminders keep theirs: the label IS the message.
  defp default_notify_label("", "alarm"), do: "Alarm"
  defp default_notify_label(label, _kind), do: label

  # The moment a widget submission should fire, per kind: a timer counts down;
  # alarms AND reminders arm the next local wall-clock occurrence of the picked
  # time. (The `notify_create` command's reminder fires immediately — that's the
  # agent announcing something now; a human setting a reminder is scheduling
  # its announcement.)
  defp notify_fire_at("timer", params) do
    case params |> Map.get("minutes", "") |> parse_minutes() do
      :error -> {:error, :minutes, "minutes must be a positive number"}
      minutes -> {:ok, DateTime.add(now(), minutes * 60, :second)}
    end
  end

  defp notify_fire_at(kind, params) when kind in ["alarm", "reminder"] do
    case parse_wall_time(Map.get(params, "at", "")) do
      {:ok, time} -> {:ok, next_local_occurrence(time)}
      :error -> {:error, :at, "pick a time"}
    end
  end

  defp notify_fire_at(_kind, _params), do: {:error, :label, "unknown kind"}

  # <input type="time"> submits "HH:MM" (sometimes "HH:MM:SS").
  defp parse_wall_time(value) do
    value = String.trim(to_string(value))
    padded = if String.length(value) == 5, do: value <> ":00", else: value

    case Time.from_iso8601(padded) do
      {:ok, time} -> {:ok, time}
      _ -> :error
    end
  end

  # The next moment the Mac's local clock reads `time`, as UTC: today if still
  # ahead, else tomorrow. The offset comes from comparing the OS local clock to
  # UTC (no tz database in the app); rounded to 15-minute granularity — real
  # offsets are — so the seconds between the two reads can't skew it. An alarm
  # set across a DST flip lands an hour off; acceptable for a bedside clock.
  defp next_local_occurrence(%Time{} = time) do
    local_now = NaiveDateTime.from_erl!(:calendar.local_time())
    candidate = NaiveDateTime.new!(NaiveDateTime.to_date(local_now), time)

    candidate =
      if NaiveDateTime.compare(candidate, local_now) == :gt,
        do: candidate,
        else: NaiveDateTime.add(candidate, 86_400, :second)

    utc_now = NaiveDateTime.from_erl!(:calendar.universal_time())
    offset = round(NaiveDateTime.diff(local_now, utc_now) / 900) * 900

    candidate
    |> NaiveDateTime.add(-offset, :second)
    |> DateTime.from_naive!("Etc/UTC")
    |> DateTime.truncate(:second)
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)

  @impl true
  def handle_event("toggle_add_contact", _params, socket) do
    {:noreply, assign(socket, :show_add_contact, !socket.assigns.show_add_contact)}
  end

  def handle_event("add_contact", %{"entry" => entry}, socket) do
    case TrustedSenders.add_entry(entry) do
      {:ok, _value} ->
        {:noreply, load_trust(socket)}

      {:error, :invalid_entry} ->
        {:noreply,
         put_flash(socket, :error, "Enter a full email address or a *@domain wildcard.")}
    end
  end

  # Removing an *orphan* entry — an address or wildcard with no contact behind it.
  # There is nothing else to clean up, so the policy line is simply dropped.
  def handle_event("remove_contact", %{"entry" => entry}, socket) do
    TrustedSenders.remove_entry(entry)
    {:noreply, load_trust(socket)}
  end

  # Untrusting a *contact* is not the same act as deleting them. This revokes the
  # policy entry and leaves the person in your contacts — their mail stops being
  # queued, their name and face stay. Conflating the two would let a UI tidy-up
  # quietly rewrite the security policy.
  def handle_event("untrust_contact", %{"id" => id}, socket) do
    contact = Contacts.get_contact!(id)

    case Contacts.set_trusted(contact, false) do
      {:ok, _} ->
        {:noreply, load_trust(socket)}

      {:error, reason} ->
        {:noreply,
         socket
         |> put_flash(:error, "Could not update the trust policy: #{inspect(reason)}")
         |> load_trust()}
    end
  end

  def handle_event("select_home_tab", %{"tab" => tab}, socket)
      when tab in ["chat", "calendar", "notes", "trading"] do
    {:noreply, switch_home_tab(socket, tab)}
  end

  def handle_event("trading_refresh", _params, socket) do
    {:noreply, maybe_refresh_account(socket)}
  end

  def handle_event("select_widget_tab", %{"tab" => tab}, socket)
      when tab in ["contacts", "place", "notify"] do
    socket = assign(socket, :widget_tab, tab)

    # Selecting Time & Place (re)loads conditions (TTL-cached, so a real fetch at
    # most once per TTL); Notify re-reads its list so it's fresh on open.
    case tab do
      "place" -> {:noreply, load_weather(socket)}
      "notify" -> {:noreply, load_notifications(socket)}
      "contacts" -> {:noreply, load_comms(socket)}
      _ -> {:noreply, socket}
    end
  end

  # The corner-widget "Email <contact>" button: hand the chat a templated request
  # and flip to the Chat sub-tab so the user can type the message body. The agent
  # (not us) sends the mail — this only stages the ask; texting/calling are inert
  # until outbound telephony exists.
  def handle_event("email_contact", %{"id" => id}, socket) do
    case Enum.find(socket.assigns.comms_contacts, &(to_string(&1.id) == id)) do
      %{email: email, name: name} when is_binary(email) ->
        template = "Please email #{name} (#{email}) with the following message:\n\n"

        {:noreply,
         socket
         # switch_home_tab, not a bare assign: fired while on the Trading tab,
         # a raw tab flip would prefill the mail ask into the trading chat.
         |> switch_home_tab("chat")
         |> push_event("bc:chat_prefill", %{text: template})}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("notify_kind", %{"kind" => kind}, socket)
      when kind in ["timer", "alarm", "reminder"] do
    {:noreply, socket |> assign(:notify_kind, kind) |> assign(:notify_form, notify_form())}
  end

  def handle_event("notify_create", %{"notify" => params}, socket) do
    kind = Map.get(params, "kind", "timer")
    label = params |> Map.get("label", "") |> String.trim() |> default_notify_label(kind)

    with :ok <- if(label == "", do: {:error, :label, "add a label"}, else: :ok),
         {:ok, fire_at} <- notify_fire_at(kind, params) do
      attrs = %{
        "kind" => kind,
        "label" => label,
        "fire_at" => fire_at,
        "status" => "pending",
        "source" => "manual"
      }

      case Notifications.create_notification(attrs) do
        {:ok, _notification} ->
          {:noreply, socket |> assign(:notify_form, notify_form()) |> load_notifications()}

        {:error, _changeset} ->
          {:noreply, assign_notify_error(socket, params, :label, "could not create #{kind}")}
      end
    else
      {:error, field, message} ->
        {:noreply, assign_notify_error(socket, params, field, message)}
    end
  end

  def handle_event("notify_dismiss", %{"id" => id}, socket) do
    notification = Enum.find(socket.assigns.notifications, &(to_string(&1.id) == id))
    if notification, do: Notifications.dismiss(notification)
    {:noreply, load_notifications(socket)}
  end

  def handle_event("notify_snooze", %{"id" => id}, socket) do
    notification = Enum.find(socket.assigns.notifications, &(to_string(&1.id) == id))
    if notification, do: Notifications.snooze(notification, 300)
    {:noreply, load_notifications(socket)}
  end

  def handle_event("set_weather_location", %{"query" => query}, socket) do
    socket = assign(socket, :weather, :loading)

    {:noreply,
     start_async(socket, :weather, fn ->
       with {:ok, _location} <- Weather.set_location(query) do
         Weather.current()
       end
     end)}
  end

  def handle_event("edit_weather_location", _params, socket) do
    {:noreply, assign(socket, :weather_form, true)}
  end

  def handle_event("chat_send", %{"message" => text}, socket) do
    # Sending barges in on any reply still being spoken.
    socket = push_event(socket, "bc:stop_speak", %{})

    case String.trim(text) do
      "" -> {:noreply, socket}
      trimmed -> {:noreply, dispatch_chat(socket, trimmed)}
    end
  end

  def handle_event("cancel_queued", %{"id" => id}, socket) do
    case Integer.parse(id) do
      {qid, ""} -> Chat.remove_queued(socket.assigns.active_chat, qid)
      _ -> :ok
    end

    {:noreply, socket}
  end

  def handle_event("cut_run", _params, socket) do
    Chat.interrupt(socket.assigns.active_chat)
    {:noreply, push_event(socket, "bc:stop_speak", %{})}
  end

  def handle_event("barge_queued", %{"id" => id}, socket) do
    case Integer.parse(id) do
      {qid, ""} -> Chat.barge(socket.assigns.active_chat, qid)
      _ -> :ok
    end

    {:noreply, socket}
  end

  def handle_event("reorder_queue", %{"ids" => ids}, socket) do
    parsed =
      ids
      |> List.wrap()
      |> Enum.map(&Integer.parse/1)
      |> Enum.flat_map(fn
        {n, ""} -> [n]
        _ -> []
      end)

    Chat.reorder_queue(socket.assigns.active_chat, parsed)
    {:noreply, socket}
  end

  def handle_event("select_chat", %{"id" => id}, socket),
    do: {:noreply, activate_chat(socket, id)}

  def handle_event("new_chat", _params, socket) do
    {:ok, conv} = Conversations.create()
    if connected?(socket), do: Chat.subscribe(conv.id)

    socket =
      socket
      |> assign(:chats, socket.assigns.chats ++ [to_chat_tab(conv)])
      |> assign(:active_chat, conv.id)
      |> assign(:chat_running, false)
      |> assign(:chat_thinking, nil)
      |> assign(:chat_queue, [])
      |> stream(:chat_messages, [], reset: true)
      |> assign(:chat_seq, 0)
      |> assign(:chat_svgs, [])
      |> assign(:svg_seq, 0)
      |> assign(:zoomed_id, nil)

    {:noreply, socket}
  end

  # Open / close / page the full-screen SVG viewer modal. `@zoomed_id` is the id of
  # the SVG currently shown (or nil).
  def handle_event("zoom_svg", %{"id" => id}, socket) do
    zoomed =
      case Integer.parse(id) do
        {n, ""} -> if Enum.any?(socket.assigns.chat_svgs, &(&1.id == n)), do: n, else: nil
        _ -> nil
      end

    {:noreply, assign(socket, :zoomed_id, zoomed)}
  end

  def handle_event("close_zoom", _params, socket),
    do: {:noreply, assign(socket, :zoomed_id, nil)}

  def handle_event("zoom_nav", %{"dir" => dir}, socket),
    do: {:noreply, zoom_step(socket, dir)}

  # Keyboard while the modal is open: Esc closes, arrows page through the SVG viewer.
  def handle_event("zoom_key", %{"key" => "Escape"}, socket),
    do: {:noreply, assign(socket, :zoomed_id, nil)}

  def handle_event("zoom_key", %{"key" => "ArrowLeft"}, socket),
    do: {:noreply, zoom_step(socket, "prev")}

  def handle_event("zoom_key", %{"key" => "ArrowRight"}, socket),
    do: {:noreply, zoom_step(socket, "next")}

  def handle_event("zoom_key", _params, socket), do: {:noreply, socket}

  def handle_event("close_chat", %{"id" => id}, socket) do
    Chat.stop(id)
    Conversations.close(id)
    # Drop the subscription to the now-closed conversation's topic so its future
    # broadcasts (if any) no longer reach this LiveView.
    if connected?(socket),
      do: Phoenix.PubSub.unsubscribe(BusterClaw.PubSub, Chat.topic(id))

    remaining = Enum.reject(socket.assigns.chats, &(&1.id == id))

    socket =
      cond do
        # Always keep at least one chat open.
        remaining == [] ->
          {:ok, conv} = Conversations.create()
          if connected?(socket), do: Chat.subscribe(conv.id)
          socket |> assign(:chats, [to_chat_tab(conv)]) |> activate_chat(conv.id)

        # Closing the active tab → switch to the first remaining.
        socket.assigns.active_chat == id ->
          socket |> assign(:chats, remaining) |> activate_chat(hd(remaining).id)

        true ->
          assign(socket, :chats, remaining)
      end

    {:noreply, socket}
  end

  defp dispatch_chat(socket, text) do
    # The user echo and all agent events arrive via the active conversation's
    # PubSub broadcast, so on success we don't append here. send_message/2 starts
    # the conversation's process on demand (a dev refresh is enough). Errors are
    # appended inline as a persistent message.
    conv_id = socket.assigns.active_chat

    if conv_id == Trading.conv_id() do
      # Trading requires the Claude CLI specifically: the MCP flags in
      # Trading.chat_opts/0 are Claude's, and codex would choke on them.
      case BusterClaw.AgentRunner.detect() do
        {:ok, {:claude, _path}} ->
          # One audit line per money-adjacent send. Length only — the full text
          # already persists in the conversation transcript.
          BusterClaw.Sentinel.observe(:outbound_send, "Trading chat message sent", %{
            source: "trading_chat",
            conv_id: conv_id,
            chars: String.length(text)
          })

          Chat.ensure_started(conv_id, Trading.chat_opts())
          do_send(socket, conv_id, text)

        _other ->
          push_msg(socket, :error, "Trading requires the Claude Code CLI.")
      end
    else
      # Start the conversation taught the SVG viewer vocabulary (idempotent — the
      # guide is fixed at first start; a no-op once the process exists).
      Chat.ensure_started(conv_id, append_system_prompt: SvgViewer.guide())
      do_send(socket, conv_id, text)
    end
  catch
    :exit, _reason ->
      push_msg(socket, :error, "Chat backend isn't running — restart the server.")
  end

  # While a run is in flight send_message/2 queues the text (returns :ok) rather
  # than rejecting it; the queued item arrives back over PubSub as {:queue, …}.
  defp do_send(socket, conv_id, text) do
    case Chat.send_message(conv_id, text) do
      :ok ->
        maybe_autotitle(socket, conv_id, text)

      {:error, :no_agent_cli} ->
        socket

      {:error, reason} ->
        push_msg(socket, :error, "Could not start the run: #{inspect(reason)}")
    end
  end

  @impl true
  def handle_info({:agent_chat, conv_id, payload}, socket),
    do: {:noreply, apply_chat(socket, conv_id, payload)}

  # The homepage background changed in settings — re-render it live. Switching
  # onto the weather shader also feeds it the real sky right away (from the
  # already-loaded conditions, or a fresh fetch).
  def handle_info({:home_background, state}, socket) do
    socket = assign(socket, :home_bg, state)

    socket =
      cond do
        state.mode != "weather" -> socket
        is_map(socket.assigns.weather) -> push_sky(socket)
        true -> maybe_fetch_sky(socket)
      end

    {:noreply, socket}
  end

  # Periodic sky tick: keep the weather-shader background tracking real
  # conditions while the homepage sits open. Cheap no-op in any other mode.
  def handle_info(:sky_refresh, socket) do
    Process.send_after(self(), :sky_refresh, @sky_refresh_ms)
    {:noreply, maybe_fetch_sky(socket)}
  end

  # A notification was created / snoozed / dismissed / fired somewhere (this view,
  # another session, or the agent). Re-read the widget list so it stays current.
  def handle_info({:notifications, :changed, _notification}, socket),
    do: {:noreply, load_notifications(socket)}

  # A notification fired — refresh the widget list so it leaves "upcoming". The
  # modal itself is the app-wide NotifyLive's job (a separate subscriber).
  def handle_info({:notification_fired, _notification}, socket),
    do: {:noreply, load_notifications(socket)}

  # A call/text landed — refresh the corner-widget "Recent activity" feed.
  def handle_info({:telephony_event, _event}, socket), do: {:noreply, load_comms(socket)}

  def handle_info(_message, socket), do: {:noreply, socket}

  @impl true
  def handle_async(:weather, {:ok, result}, socket) do
    case result do
      {:ok, conditions} ->
        {:noreply,
         socket |> assign(:weather, conditions) |> assign(:weather_form, false) |> push_sky()}

      {:error, :not_found} ->
        # Geocode miss: keep the form up with its inline hint.
        {:noreply,
         socket |> assign(:weather, {:error, :not_found}) |> assign(:weather_form, true)}

      {:error, reason} ->
        {:noreply, socket |> assign(:weather, {:error, reason}) |> assign(:weather_form, false)}
    end
  end

  def handle_async(:weather, {:exit, reason}, socket) do
    {:noreply, assign(socket, :weather, {:error, {:exit, reason}})}
  end

  def handle_async(:trading_account, {:ok, result}, socket) do
    case result do
      {:ok, snap} ->
        Trading.store_snapshot(snap)
        {:noreply, assign(socket, :trading_account, {:ok, snap})}

      {:error, reason} ->
        # Keep the last good snapshot visible under the error line.
        prev = last_snapshot(socket.assigns.trading_account)
        {:noreply, assign(socket, :trading_account, {:error, reason, prev})}
    end
  end

  # A crashed fetch task degrades to the error state — never a stalled panel.
  def handle_async(:trading_account, {:exit, reason}, socket) do
    prev = last_snapshot(socket.assigns.trading_account)
    {:noreply, assign(socket, :trading_account, {:error, {:exit, reason}, prev})}
  end

  # Fetch off the LiveView process; a slow weather API must never stall the
  # homepage. No location yet → show the form instead of spawning a fetch; a
  # loaded map is kept (Weather.current/0 handles staleness via its own TTL).
  defp load_weather(socket) do
    cond do
      is_nil(Weather.location()) ->
        assign(socket, :weather_form, true)

      is_map(socket.assigns.weather) ->
        socket

      true ->
        socket
        |> assign(:weather, :loading)
        |> start_async(:weather, fn -> Weather.current() end)
    end
  end

  # On connect, populate the default Time & Place widget tab and, when the
  # background is in weather mode, the sky. Both read the TTL-cached Weather and
  # both would start_async(:weather); the branch keeps exactly one of them from
  # firing so two tasks never race on the same async key. In weather mode
  # `maybe_fetch_sky/1` covers both surfaces (its result also lands in `@weather`
  # via `handle_async/3`); otherwise `load_weather/1` just fills the widget.
  defp mount_weather(socket) do
    if socket.assigns.home_bg.mode == "weather" do
      maybe_fetch_sky(socket)
    else
      load_weather(socket)
    end
  end

  # The weather-shader background needs real conditions whether or not the
  # widget's Time & Place tab is open: when the homepage background is in
  # weather mode and a location is set, (re)fetch. Unlike load_weather/1 this
  # refetches even when conditions are already loaded (the :sky_refresh tick),
  # but keeps the loaded map on screen instead of flashing :loading.
  defp maybe_fetch_sky(socket) do
    if socket.assigns.home_bg.mode == "weather" and not is_nil(Weather.location()) do
      socket
      |> then(fn s ->
        if is_map(s.assigns.weather), do: s, else: assign(s, :weather, :loading)
      end)
      |> start_async(:weather, fn -> Weather.current() end)
    else
      socket
    end
  end

  # Hand the SmokeBackground hook the real sky: condition code plus wind/cloud,
  # sunrise/sunset as day-fractions, and the location's UTC offset (the hook
  # derives the place's live time-of-day from it each frame). Skipped when the
  # conditions predate the sunrise/sunset fields.
  defp push_sky(socket) do
    case socket.assigns.weather do
      %{sunrise_frac: sr, sunset_frac: ss} = w when is_number(sr) and is_number(ss) ->
        push_event(socket, "bc:sky", %{
          code: w.code,
          wind_mph: w.wind_mph,
          cloud_pct: w.cloud_pct,
          sunrise_frac: sr,
          sunset_frac: ss,
          utc_offset: w.utc_offset
        })

      _incomplete ->
        socket
    end
  end

  # --- chat transcript projection (from each conversation's PubSub broadcasts) ---
  #
  # A status/message for the ACTIVE conversation updates the rendered transcript;
  # for a background conversation it only flips that tab's running/unread badge —
  # which is what makes concurrent chats visible.

  defp apply_chat(socket, conv_id, {:status, status}) do
    socket = update_tab(socket, conv_id, &%{&1 | running: status == :running})

    socket =
      if conv_id == socket.assigns.active_chat do
        socket
        |> assign(:chat_running, status == :running)
        # Start the live timer on :running; clear it on :idle (the finished duration
        # lives on in the transcript's :meta line, so the header chip can disappear).
        |> assign(:chat_thinking, if(status == :running, do: :running, else: nil))
      else
        socket
      end

    # A finished trading run may have moved money — re-snapshot the account
    # while the operator is looking at it.
    if status == :idle and conv_id == Trading.conv_id() and
         socket.assigns.home_tab == "trading",
       do: maybe_refresh_account(socket),
       else: socket
  end

  defp apply_chat(socket, conv_id, {:thinking, ms}) do
    if conv_id == socket.assigns.active_chat,
      do: assign(socket, :chat_thinking, {:done, ms}),
      else: socket
  end

  defp apply_chat(socket, conv_id, {:queue, items}) do
    if conv_id == socket.assigns.active_chat,
      do: assign(socket, :chat_queue, items),
      else: socket
  end

  # Assistant replies may carry ```svg blocks: strip them from the spoken/shown
  # bubble text and stash the drawings, tagging this message's bubble with their
  # ids so it renders a "View drawing" link into the modal. An SVG-only reply
  # still gets a bubble (text-less) so the drawing stays reachable.
  defp apply_chat(socket, conv_id, {:message, %{role: :assistant, text: text}}) do
    if conv_id == socket.assigns.active_chat do
      {clean, svgs} = SvgViewer.extract(text)
      base = socket.assigns.svg_seq
      socket = collect_svgs(socket, svgs)
      svg_ids = svg_ids_for(base, svgs)

      cond do
        clean != "" ->
          socket |> maybe_speak(:assistant, clean) |> push_msg(:assistant, clean, svg_ids)

        svgs != [] ->
          push_msg(socket, :assistant, "", svg_ids)

        true ->
          socket
      end
    else
      mark_unread(socket, conv_id)
    end
  end

  defp apply_chat(socket, conv_id, {:message, %{role: role, text: text}}) do
    if conv_id == socket.assigns.active_chat do
      socket
      |> maybe_speak(role, text)
      |> push_msg(role, text)
    else
      mark_unread(socket, conv_id)
    end
  end

  defp apply_chat(socket, _conv_id, _other), do: socket

  # The trading conversation has no chat-strip tab; its unread signal is a dot
  # on the Trading home sub-tab instead.
  defp mark_unread(socket, conv_id) do
    if conv_id == Trading.conv_id(),
      do: assign(socket, :trading_unread, true),
      else: update_tab(socket, conv_id, &%{&1 | unread: true})
  end

  # The pool ids `collect_svgs/2` just assigned to this batch (it numbers a batch
  # `svg_seq+1 .. svg_seq+n`), so a bubble can link straight to its own drawings.
  defp svg_ids_for(_base, []), do: []
  defp svg_ids_for(base, svgs), do: Enum.to_list((base + 1)..(base + length(svgs)))

  # Speak the model's replies aloud (client gates on the Voice toggle + desktop
  # app). Only `:assistant` text — never tool/meta/error lines. A turn emits one
  # `:assistant` message per text block; each is enqueued and spoken in order.
  defp maybe_speak(socket, :assistant, text), do: push_event(socket, "bc:speak", %{text: text})
  defp maybe_speak(socket, _role, _text), do: socket

  # Trading is a pinned conversation riding the single active-chat surface:
  # entering the tab activates it; returning to Chat re-activates the last
  # ordinary conversation. Calendar/Notes never touch the active chat.
  defp switch_home_tab(socket, "trading") do
    last =
      if socket.assigns.active_chat == Trading.conv_id(),
        do: socket.assigns.last_chat,
        else: socket.assigns.active_chat

    socket
    |> assign(:home_tab, "trading")
    |> assign(:last_chat, last)
    |> assign(:trading_unread, false)
    |> activate_chat(Trading.conv_id())
    |> load_trading_account()
  end

  defp switch_home_tab(socket, "chat") do
    socket = assign(socket, :home_tab, "chat")

    if socket.assigns.active_chat == Trading.conv_id(),
      do: activate_chat(socket, socket.assigns.last_chat),
      else: socket
  end

  defp switch_home_tab(socket, tab), do: assign(socket, :home_tab, tab)

  # Show whatever snapshot is cached immediately; refresh only when missing or
  # stale — every refresh is a real (haiku) agent run, cents not free.
  defp load_trading_account(socket) do
    case Trading.cached_snapshot() do
      {:ok, snap} ->
        socket = assign(socket, :trading_account, {:ok, snap})
        if Trading.snapshot_stale?(snap), do: maybe_refresh_account(socket), else: socket

      :none ->
        maybe_refresh_account(socket)
    end
  end

  # One in-flight refresh max; the last good snapshot stays visible while a
  # fresh one loads (or fails — see handle_async).
  defp maybe_refresh_account(socket) do
    case socket.assigns.trading_account do
      {:loading, _prev} ->
        socket

      current ->
        socket
        |> assign(:trading_account, {:loading, last_snapshot(current)})
        |> start_async(:trading_account, fn -> Trading.fetch_account_snapshot() end)
    end
  end

  defp last_snapshot({:ok, snap}), do: snap
  defp last_snapshot({:loading, prev}), do: prev
  defp last_snapshot({:error, _reason, prev}), do: prev
  defp last_snapshot(_), do: nil

  # The Agentic-account panel (Trading tab, right column). Shows whichever
  # snapshot we have — including a stale one under a spinner or error line —
  # with an honest as-of stamp; the truth costs an agent run, so it is never
  # silently auto-polled.
  defp trading_account_card(assigns) do
    assigns = assign(assigns, :snap, last_snapshot(assigns.account))

    ~H"""
    <aside
      id="trading-account-card"
      class="ic-panel flex min-h-0 flex-col overflow-y-auto p-4 font-mono text-xs"
    >
      <div class="flex items-center justify-between border-b-2 border-base-content/20 pb-2">
        <p class="font-bold uppercase tracking-widest">Agentic account</p>
        <span :if={@snap} class="text-base-content/60">{@snap["account"]}</span>
      </div>

      <div :if={@snap} class="space-y-5 pt-3">
        <div class="grid grid-cols-3 gap-2">
          <div>
            <p class="ic-stat-n text-3xl">{money(@snap["value"])}</p>
            <p class="uppercase tracking-wide text-base-content/60">Account value</p>
          </div>
          <div class="pt-1">
            <p class="text-lg font-bold">{money(@snap["cash"])}</p>
            <p class="uppercase text-base-content/60">Cash</p>
          </div>
          <div class="pt-1">
            <p class="text-lg font-bold">{money(@snap["buying_power"])}</p>
            <p class="uppercase text-base-content/60">Buying power</p>
          </div>
        </div>

        <%!-- Allocation: one measure (value) per symbol — single-hue thin bars,
              direct labels in text tokens, no legend (single series). --%>
        <div>
          <p class="border-b border-base-content/15 pb-1 uppercase tracking-wide text-base-content/60">
            Positions
          </p>
          <p :if={@snap["positions"] == []} class="pt-2 text-base-content/50">
            No positions — the account is all cash.
          </p>
          <div :if={@snap["positions"] != []} class="space-y-2 pt-2">
            <div
              :for={pos <- sorted_positions(@snap)}
              class="grid grid-cols-[5rem_minmax(0,1fr)_6rem] items-center gap-2"
              title={"#{pos["symbol"]}: #{pos["quantity"]} worth #{money(pos["value"])}"}
            >
              <span class="truncate font-bold">{pos["symbol"]}</span>
              <div class="h-2.5 w-full rounded-xs bg-base-content/10">
                <div
                  class="h-full rounded-xs bg-primary"
                  style={"width: #{bar_width(pos, @snap)}%"}
                >
                </div>
              </div>
              <span class="text-right text-base-content/80">{money(pos["value"])}</span>
            </div>
          </div>
        </div>

        <%!-- Trades: an event list, not a chart — side is written (BUY/SELL),
              never carried by color alone. --%>
        <div>
          <p class="border-b border-base-content/15 pb-1 uppercase tracking-wide text-base-content/60">
            Recent trades
          </p>
          <p :if={List.wrap(@snap["orders"]) == []} class="pt-2 text-base-content/50">
            No trades yet.
          </p>
          <div :if={List.wrap(@snap["orders"]) != []} class="divide-y divide-base-content/10">
            <div
              :for={order <- List.wrap(@snap["orders"])}
              class="grid grid-cols-[3.5rem_4.5rem_minmax(0,1fr)_auto] items-center gap-2 py-1.5"
            >
              <span class={[
                "border px-1.5 py-0.5 text-center font-bold uppercase",
                order_side_class(order["side"])
              ]}>
                {order["side"] || "?"}
              </span>
              <span class="font-bold">{order["symbol"]}</span>
              <span class="truncate text-base-content/70">
                {order["quantity"]} @ {money(order["price"])}
                <span class="text-base-content/50">· {order["state"]}</span>
              </span>
              <span class="text-right text-base-content/50">{order_when(order)}</span>
            </div>
          </div>
        </div>
      </div>

      <p :if={is_nil(@snap) and not match?({:loading, _}, @account)} class="pt-3 text-base-content/60">
        No snapshot yet — refresh to load the account.
      </p>
      <p :if={is_nil(@snap) and match?({:loading, _}, @account)} class="pt-3 text-base-content/60">
        Loading account…
      </p>
      <p :if={match?({:error, _, _}, @account)} class="pt-3 font-bold text-error">
        Refresh failed: {card_error(@account)}
      </p>

      <div class="mt-auto flex items-center justify-between gap-2 border-t-2 border-base-content/20 pt-2">
        <span class="text-base-content/50">{card_asof(@snap)}</span>
        <button
          type="button"
          phx-click="trading_refresh"
          disabled={match?({:loading, _}, @account)}
          class="border-2 border-base-content/40 px-3 py-1 font-bold uppercase tracking-wide transition hover:bg-base-content/10 disabled:opacity-50"
        >
          {if match?({:loading, _}, @account), do: "Refreshing…", else: "Refresh"}
        </button>
      </div>
    </aside>
    """
  end

  defp money(v) when is_number(v), do: "$" <> :erlang.float_to_binary(v * 1.0, decimals: 2)
  defp money(_v), do: "—"

  defp sorted_positions(%{"positions" => positions}),
    do: Enum.sort_by(List.wrap(positions), &(-position_value(&1)))

  # Bar length as a % of the LARGEST position (allocation-relative, so one
  # holding always reads full-width). Guarded so a zero/garbage value can't
  # divide by zero or overflow the track.
  defp bar_width(pos, snap) do
    max =
      snap
      |> sorted_positions()
      |> Enum.map(&position_value/1)
      |> Enum.max(fn -> 0 end)

    if max > 0, do: Float.round(position_value(pos) / max * 100, 1), else: 0
  end

  defp position_value(%{"value" => v}) when is_number(v) and v > 0, do: v
  defp position_value(_pos), do: 0

  # Buy/sell chips: status colors validated vs both surfaces (CVD ΔE 9.7 dark /
  # 7.4 light); the written BUY/SELL word is the required secondary encoding.
  defp order_side_class("buy"), do: "border-success/50 text-success"
  defp order_side_class("sell"), do: "border-error/50 text-error"
  defp order_side_class(_side), do: "border-base-content/30 text-base-content/60"

  defp order_when(%{"placed_at" => stamp}) when is_binary(stamp) do
    case DateTime.from_iso8601(stamp) do
      {:ok, at, _} -> relative_time(at)
      _ -> ""
    end
  end

  defp order_when(_order), do: ""

  defp card_asof(%{"fetched_at" => stamp}) when is_binary(stamp) do
    case DateTime.from_iso8601(stamp) do
      {:ok, at, _} -> "as of #{relative_time(at)}"
      _ -> ""
    end
  end

  defp card_asof(_snap), do: ""

  defp card_error({:error, {:robinhood, msg}, _prev}), do: msg
  defp card_error({:error, :bad_snapshot, _prev}), do: "unreadable snapshot"
  defp card_error({:error, {:agent_exit, status}, _prev}), do: "agent exited #{status}"
  defp card_error({:error, :no_agent_cli, _prev}), do: "Claude Code CLI not found"
  defp card_error({:error, _reason, _prev}), do: "agent run failed"

  defp activate_chat(socket, id) do
    Conversations.touch(id)

    socket
    |> assign(:active_chat, id)
    |> assign(:chat_running, Chat.running?(id))
    |> assign(:chat_thinking, if(Chat.running?(id), do: :running, else: nil))
    |> assign(:chat_queue, Chat.queue(id))
    |> assign(:zoomed_id, nil)
    |> update_tab(id, &%{&1 | unread: false})
    |> load_chat_history(id)
  end

  defp update_tab(socket, conv_id, fun) do
    chats = Enum.map(socket.assigns.chats, fn c -> if c.id == conv_id, do: fun.(c), else: c end)
    assign(socket, :chats, chats)
  end

  # Title a still-"New chat" conversation from its first user message.
  defp maybe_autotitle(socket, conv_id, text) do
    tab = Enum.find(socket.assigns.chats, &(&1.id == conv_id))

    if tab && tab.title == Conversations.default_title() do
      title = title_from(text)
      Conversations.rename(conv_id, title)
      update_tab(socket, conv_id, &%{&1 | title: title})
    else
      socket
    end
  end

  defp title_from(text) do
    text |> String.trim() |> String.replace(~r/\s+/, " ") |> String.slice(0, 40)
  end

  defp push_msg(socket, role, text, svg_ids \\ []) do
    seq = socket.assigns.chat_seq + 1
    msg = %{id: seq, role: role, text: text, svg_ids: svg_ids}

    socket
    |> assign(:chat_seq, seq)
    |> stream_insert(:chat_messages, msg, limit: -@max_chat_messages)
  end

  # Keep an appended list to a bound by dropping the oldest entries off the front.
  defp cap_list(list, max) do
    over = length(list) - max
    if over > 0, do: Enum.drop(list, over), else: list
  end

  # Append newly-drawn SVGs to the SVG viewer (sanitized before they're stored,
  # since they render live in the DOM).
  defp collect_svgs(socket, []), do: socket

  defp collect_svgs(socket, svgs) do
    base = socket.assigns.svg_seq

    new =
      svgs
      |> Enum.with_index(base + 1)
      |> Enum.map(fn {svg, i} ->
        %{id: i, svg: svg |> SvgViewer.sanitize() |> SvgViewer.normalize()}
      end)

    socket
    |> assign(:svg_seq, base + length(svgs))
    |> update(:chat_svgs, &cap_list(&1 ++ new, @max_chat_svgs))
  end

  # Move the zoomed image one step through the SVG viewer (clamped at the ends).
  defp zoom_step(socket, dir) do
    svgs = socket.assigns.chat_svgs

    case Enum.find_index(svgs, &(&1.id == socket.assigns.zoomed_id)) do
      nil ->
        socket

      idx ->
        next =
          case dir do
            "prev" -> max(0, idx - 1)
            "next" -> min(length(svgs) - 1, idx + 1)
            _ -> idx
          end

        assign(socket, :zoomed_id, Enum.at(svgs, next).id)
    end
  end

  # Restore the transcript AND the SVG viewer from the conversation's history:
  # assistant rows are stored with their ```svg blocks intact, so re-extract them
  # to (a) strip the raw markup from the bubble and (b) refill the SVG viewer. The
  # bank thus reflects every SVG in the conversation and survives reload /
  # tab-switch. It is NOT a saved gallery — the drawings only live as long as the
  # chat's transcript does, so deleting the chat takes them with it.
  defp load_chat_history(socket, conv_id) do
    # Reading-order entries built by prepending (++ in the reduce would be
    # quadratic over the 200-row transcript) then reversing. Each assistant entry
    # keeps the drawings pulled from its ```svg blocks, so its bubble can link to
    # them; an SVG-only reply keeps a text-less bubble rather than vanishing.
    entries =
      conv_id
      |> AgentTranscript.recent(limit: 200)
      |> Enum.reduce([], fn row, acc ->
        case history_role(row.role) do
          :assistant ->
            {clean, block_svgs} = SvgViewer.extract(row.content)

            drawings =
              Enum.map(block_svgs, &(&1 |> SvgViewer.sanitize() |> SvgViewer.normalize()))

            if clean == "" and drawings == [],
              do: acc,
              else: [%{role: :assistant, text: clean, drawings: drawings} | acc]

          role ->
            [%{role: role, text: row.content, drawings: []} | acc]
        end
      end)
      |> Enum.reverse()

    # Number every drawing across the transcript (reading order), hand each
    # message the ids of its own drawings, and build the flat modal pool in step.
    {messages_rev, pool_rev, _next} =
      Enum.reduce(entries, {[], [], 1}, fn entry, {msgs, pool, next} ->
        n = length(entry.drawings)
        ids = if n == 0, do: [], else: Enum.to_list(next..(next + n - 1))

        pool =
          Enum.reduce(Enum.zip(ids, entry.drawings), pool, fn {id, svg}, p ->
            [%{id: id, svg: svg} | p]
          end)

        {[%{role: entry.role, text: entry.text, svg_ids: ids} | msgs], pool, next + n}
      end)

    messages =
      messages_rev
      |> Enum.reverse()
      |> Enum.with_index(1)
      |> Enum.map(fn {m, i} -> Map.put(m, :id, i) end)

    svgs = Enum.reverse(pool_rev)

    socket
    |> stream(:chat_messages, messages, reset: true)
    |> assign(:chat_seq, length(messages))
    |> assign(:chat_svgs, svgs)
    |> assign(:svg_seq, length(svgs))
    |> assign(:zoomed_id, nil)
  end

  @history_roles %{
    "user" => :user,
    "assistant" => :assistant,
    "tool" => :tool,
    "meta" => :meta,
    "error" => :error
  }
  defp history_role(role), do: Map.get(@history_roles, role, :assistant)

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} socket={@socket}>
      <section class="ic-home relative isolate flex flex-1 flex-col">
        <%!-- Homepage background (Appearance setting): an uploaded image, or a
              hook-owned WebGPU shader canvas that LiveView never patches inside.
              The shader div is keyed by design name, so changing it remounts the
              hook with the new shader. --%>
        <div
          :if={@home_bg.mode == "image"}
          class="ic-home-bg"
          style={"background-image:url('#{@home_bg.image_url}');background-size:cover;background-position:center;"}
          aria-hidden="true"
        >
        </div>
        <div
          :if={@home_bg.mode not in ["image", "off"]}
          id={"home-shader-#{@home_bg.mode}-#{:erlang.phash2({@home_bg.custom, @home_bg.colors})}"}
          phx-hook="SmokeBackground"
          phx-update="ignore"
          data-shader={@home_bg.mode}
          data-shader-source={@home_bg.source_url}
          data-custom={to_string(@home_bg.custom)}
          data-colors={Enum.join(@home_bg.colors, ",")}
          class="ic-home-bg"
          aria-hidden="true"
        >
          <canvas data-smoke-canvas></canvas>
        </div>
        <div class="relative z-10 flex min-h-0 flex-1 flex-col space-y-8">
          <div class="flex items-stretch gap-4 border-b-2 border-base-content/20 pb-5">
            <div class="shrink-0 space-y-4">
              <div
                id="bc-heading"
                phx-hook="CrtAberration"
                class="ic-scanlines block w-full max-w-[28rem]"
              >
                <img
                  src={~p"/images/brand/buster-claw-heading.png"}
                  alt="Buster Claw"
                  class="block h-auto w-full"
                />
                <img
                  src={~p"/images/brand/buster-claw-heading.png"}
                  alt=""
                  aria-hidden="true"
                  class="ic-crt-focus h-auto w-full"
                />
              </div>
              <div :if={not @setup_status.complete?} class="pt-1">
                <.link
                  navigate={~p"/setup"}
                  class="inline-flex items-center gap-2 rounded bg-primary px-4 py-2 text-sm font-semibold text-primary-content transition hover:opacity-85"
                >
                  <.icon name="hero-sparkles" class="size-4" />
                  <span :if={@setup_status.completed == 0}>Set up Buster Claw</span>
                  <span :if={@setup_status.completed > 0}>
                    Finish setup · {@setup_status.completed} of {@setup_status.total} complete
                  </span>
                </.link>
              </div>
            </div>
            <BusterClawWeb.HomeWidget.corner_widget
              tab={@widget_tab}
              contacts={@comms_contacts}
              activity={@phone_activity}
              show_add={@show_add_contact}
              trusted={@trusted_people}
              entries={@trusted_entries}
              weather={@weather}
              weather_form={@weather_form}
              notifications={@notifications}
              notify_form={@notify_form}
              notify_kind={@notify_kind}
            />
          </div>

          <div class="flex min-h-0 flex-1 flex-col gap-2">
            <%!-- Home sub-tabs: Chat | Calendar. Switching to Calendar hides the
                  chat entirely and mounts the full calendar in its place. --%>
            <div
              class="flex gap-0.5 self-start border-2 border-base-content/20 p-0.5"
              role="tablist"
              aria-label="Home view"
            >
              <button
                :for={
                  {key, label} <- [
                    {"chat", "Chat"},
                    {"calendar", "Calendar"},
                    {"notes", "Notes"},
                    {"trading", "Trading"}
                  ]
                }
                type="button"
                role="tab"
                aria-selected={@home_tab == key}
                phx-click="select_home_tab"
                phx-value-tab={key}
                class={[
                  "rounded-xs px-4 py-1.5 font-mono text-xs font-bold uppercase tracking-wide transition",
                  if(@home_tab == key,
                    do: "bg-primary text-primary-content",
                    else: "text-base-content/60 hover:bg-base-content/10"
                  )
                ]}
              >
                {label}<span
                  :if={key == "trading" and @trading_unread}
                  class="ml-1.5 inline-block size-1.5 rounded-full bg-warning align-middle"
                />
              </button>
            </div>

            <div :if={@home_tab == "chat"} class="flex min-h-0 flex-1 flex-col gap-2">
              <BusterClawWeb.ChatPanel.chat_tabs chats={@chats} active={@active_chat} />
              <BusterClawWeb.ChatPanel.chat_panel
                messages={@streams.chat_messages}
                seq={@chat_seq}
                running={@chat_running}
                thinking={@chat_thinking}
                queue={@chat_queue}
                agent_cli_missing={@agent_cli_missing}
              />
            </div>

            <div
              :if={@home_tab == "trading"}
              class="grid min-h-0 flex-1 grid-cols-1 gap-2 lg:grid-cols-[22rem_minmax(0,1fr)]"
            >
              <div class="flex min-h-0 flex-col gap-2">
                <div class="border-2 border-warning/40 px-3 py-1.5 font-mono text-xs font-bold uppercase tracking-wide text-warning">
                  Robinhood agentic account — real orders execute here
                </div>
                <%!-- First-run setup: the OAuth handshake is interactive by nature
                    (a browser window), so it happens once in a terminal — the
                    keychain tokens are then reused by every headless turn. --%>
                <div
                  :if={@chat_seq == 0}
                  class="space-y-2 border-2 border-base-content/20 p-4 font-mono text-xs"
                >
                  <p class="font-bold uppercase tracking-wide">One-time setup (in a terminal)</p>
                  <pre class="overflow-x-auto bg-base-200 p-2">claude mcp add --transport http --scope user robinhood https://agent.robinhood.com/mcp/trading</pre>
                  <pre class="overflow-x-auto bg-base-200 p-2">claude mcp login robinhood</pre>
                  <p class="text-base-content/70">
                    The login opens Robinhood's OAuth page in your browser; tokens land in the
                    macOS Keychain and every trading turn here reuses them. Known issue
                    (claude-code #65895): if the tools still report unavailable after logging
                    in, run <code class="font-bold">claude mcp logout robinhood</code>
                    and log in again.
                  </p>
                </div>
                <BusterClawWeb.ChatPanel.chat_panel
                  messages={@streams.chat_messages}
                  seq={@chat_seq}
                  running={@chat_running}
                  thinking={@chat_thinking}
                  queue={@chat_queue}
                  agent_cli_missing={@agent_cli_missing}
                />
              </div>

              <.trading_account_card account={@trading_account} />
            </div>

            <div
              :if={@home_tab == "calendar"}
              class="flex min-h-0 flex-1 flex-col overflow-y-auto"
            >
              <.live_component
                module={BusterClawWeb.CalendarComponent}
                id="home-calendar"
                today={@today}
              />
            </div>

            <div :if={@home_tab == "notes"} class="flex min-h-0 flex-1 flex-col">
              <.live_component module={BusterClawWeb.NotesComponent} id="home-notes" />
            </div>
          </div>

          <%!-- Full-screen SVG preview, opened by a message's "View drawing" link. --%>
          <BusterClawWeb.ChatPanel.svg_modal svgs={@chat_svgs} zoomed={@zoomed_id} />
        </div>
      </section>
    </Layouts.app>
    """
  end
end
