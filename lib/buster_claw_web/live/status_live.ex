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
     # Home main view: "chat" (default) or "calendar". The sub-tab toggle swaps
     # the whole panel — the chat is hidden while the calendar is showing.
     |> assign(:home_tab, "chat")
     # Header widget: which sub-tab is showing. Order is Time & Place / Contacts /
     # Notify, and Time & Place leads (its analog clock renders instantly, and
     # `mount_weather/1` fills conditions on connect).
     |> assign(:widget_tab, "place")
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

    if connected?(socket), do: Enum.each(chats, &Chat.subscribe(&1.id))

    socket
    |> assign(:chats, chats)
    |> assign(:active_chat, active)
    |> assign(:chat_running, Chat.running?(active))
    |> assign(:chat_thinking, nil)
    |> assign(:chat_queue, Chat.queue(active))
    |> assign(:zoomed_id, nil)
    |> assign(:svg_viewer_open, false)
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
      when tab in ["chat", "calendar", "notes"] do
    {:noreply, assign(socket, :home_tab, tab)}
  end

  def handle_event("select_widget_tab", %{"tab" => tab}, socket)
      when tab in ["contacts", "place", "notify"] do
    socket = assign(socket, :widget_tab, tab)

    # Selecting Time & Place (re)loads conditions (TTL-cached, so a real fetch at
    # most once per TTL); Notify re-reads its list so it's fresh on open.
    case tab do
      "place" -> {:noreply, load_weather(socket)}
      "notify" -> {:noreply, load_notifications(socket)}
      _ -> {:noreply, socket}
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

  def handle_event("toggle_svg_viewer", _params, socket),
    do: {:noreply, update(socket, :svg_viewer_open, &(!&1))}

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

    # Start the conversation taught the SVG viewer vocabulary (idempotent — the
    # guide is fixed at first start; a no-op once the process exists).
    Chat.ensure_started(conv_id, append_system_prompt: SvgViewer.guide())

    # While a run is in flight send_message/2 queues the text (returns :ok) rather
    # than rejecting it; the queued item arrives back over PubSub as {:queue, …}.
    case Chat.send_message(conv_id, text) do
      :ok ->
        maybe_autotitle(socket, conv_id, text)

      {:error, :no_agent_cli} ->
        socket

      {:error, reason} ->
        push_msg(socket, :error, "Could not start the run: #{inspect(reason)}")
    end
  catch
    :exit, _reason ->
      push_msg(socket, :error, "Chat backend isn't running — restart the server.")
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

    if conv_id == socket.assigns.active_chat do
      socket
      |> assign(:chat_running, status == :running)
      # Start the live timer on :running; clear it on :idle (the finished duration
      # lives on in the transcript's :meta line, so the header chip can disappear).
      |> assign(:chat_thinking, if(status == :running, do: :running, else: nil))
    else
      socket
    end
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

  # Assistant replies may carry ```svg blocks: route those to the SVG viewer
  # sidebar (as real SVGs) and strip them from the spoken/shown bubble text. A
  # reply that was *only* an SVG adds no bubble.
  defp apply_chat(socket, conv_id, {:message, %{role: :assistant, text: text}}) do
    if conv_id == socket.assigns.active_chat do
      {clean, svgs} = SvgViewer.extract(text)
      socket = collect_svgs(socket, svgs)

      if clean == "" do
        socket
      else
        socket |> maybe_speak(:assistant, clean) |> push_msg(:assistant, clean)
      end
    else
      update_tab(socket, conv_id, &%{&1 | unread: true})
    end
  end

  defp apply_chat(socket, conv_id, {:message, %{role: role, text: text}}) do
    if conv_id == socket.assigns.active_chat do
      socket
      |> maybe_speak(role, text)
      |> push_msg(role, text)
    else
      update_tab(socket, conv_id, &%{&1 | unread: true})
    end
  end

  defp apply_chat(socket, _conv_id, _other), do: socket

  # Speak the model's replies aloud (client gates on the Voice toggle + desktop
  # app). Only `:assistant` text — never tool/meta/error lines. A turn emits one
  # `:assistant` message per text block; each is enqueued and spoken in order.
  defp maybe_speak(socket, :assistant, text), do: push_event(socket, "bc:speak", %{text: text})
  defp maybe_speak(socket, _role, _text), do: socket

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

  defp push_msg(socket, role, text) do
    seq = socket.assigns.chat_seq + 1
    msg = %{id: seq, role: role, text: text}

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
    # Built by prepending (appending with ++ inside the reduce is quadratic
    # over the 200-row transcript), then reversed back into reading order.
    {messages, svgs} =
      conv_id
      |> AgentTranscript.recent(limit: 200)
      |> Enum.reduce({[], []}, fn row, {msgs, svgs} ->
        case history_role(row.role) do
          :assistant ->
            {clean, block_svgs} = SvgViewer.extract(row.content)

            svgs =
              Enum.reduce(block_svgs, svgs, fn svg, acc ->
                [svg |> SvgViewer.sanitize() |> SvgViewer.normalize() | acc]
              end)

            msgs = if clean == "", do: msgs, else: [%{role: :assistant, text: clean} | msgs]
            {msgs, svgs}

          role ->
            {[%{role: role, text: row.content} | msgs], svgs}
        end
      end)

    {messages, svgs} = {Enum.reverse(messages), Enum.reverse(svgs)}

    messages = messages |> Enum.with_index(1) |> Enum.map(fn {m, i} -> Map.put(m, :id, i) end)
    svgs = svgs |> Enum.with_index(1) |> Enum.map(fn {svg, i} -> %{id: i, svg: svg} end)

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
    <Layouts.app flash={@flash}>
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
              contacts={@trusted_people}
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
                  {key, label} <- [{"chat", "Chat"}, {"calendar", "Calendar"}, {"notes", "Notes"}]
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
                {label}
              </button>
            </div>

            <div :if={@home_tab == "chat"} class="flex min-h-0 flex-1 flex-col gap-2">
              <BusterClawWeb.ChatPanel.chat_tabs chats={@chats} active={@active_chat} />
              <div class="flex min-h-0 flex-1 gap-4">
                <BusterClawWeb.ChatPanel.svg_viewer
                  svgs={@chat_svgs}
                  zoomed={@zoomed_id}
                  open={@svg_viewer_open}
                />
                <BusterClawWeb.ChatPanel.chat_panel
                  messages={@streams.chat_messages}
                  seq={@chat_seq}
                  running={@chat_running}
                  thinking={@chat_thinking}
                  queue={@chat_queue}
                  agent_cli_missing={@agent_cli_missing}
                />
              </div>
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
        </div>
      </section>
    </Layouts.app>
    """
  end
end
