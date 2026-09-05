defmodule BusterClawWeb.StatusLive do
  use BusterClawWeb, :live_view

  # The chat surface — a third of this file until 08-08 — imported rather than
  # aliased so every call site below reads as it did before the split.
  import BusterClawWeb.Status.Chat
  import BusterClawWeb.Status.Comms
  import BusterClawWeb.Status.Weather

  require Logger

  alias BusterClaw.Agent.Chat
  alias BusterClaw.Appearance
  alias BusterClaw.Contacts
  alias BusterClaw.LocalTime
  alias BusterClaw.Notifications
  alias BusterClaw.Notifications.Schedule
  alias BusterClaw.Runtime.Status
  alias BusterClaw.Setup
  alias BusterClaw.Telephony
  alias BusterClaw.TrustedSenders
  alias BusterClaw.Weather
  alias BusterClawWeb.Status.ChatAttachments

  # How many files may sit in the composer at once. The per-file byte cap is the
  # store's (`Attachments.limits/0`) and is read at mount rather than restated
  # here — two numbers that must agree are one number too many.
  @attach_max_entries 5

  # How often the homepage sky (weather-shader background) re-checks real
  # conditions. Matches Weather's cache TTL, so each tick is at most one fetch.
  @sky_refresh_ms :timer.minutes(10)

  # The Phone sub-tab's component id. Named here because this LiveView is the
  # host half of `PhoneComponent`'s contract and relays broadcasts to it.
  @phone_component_id "home-phone"

  # Same again for Vox, whose host contract is wider: a `Voice.Renderer`
  # broadcast AND the replies from the two `Task`s the component starts. See
  # `VoxComponent`'s moduledoc for why a component cannot receive either itself.
  @vox_component_id "home-vox"

  # The Home sub-tabs, in display order — ONE list, feeding both the rail and the
  # `select_home_tab` guard. They were two lists until 08-08, which is how Phone
  # arrived as a button the server then refused: the rail offered it, the guard
  # had never heard of it, and the click raised.
  @home_tabs [
    {"chat", "Chat"},
    # The KEY is the surface (`VoxComponent`, rendered at `home-vox`); the LABEL
    # is the model doing the talking. Every other row here is a downcased label,
    # so the divergence is stated rather than left to look like a typo.
    {"vox", "Vox2B"},
    {"notes", "Notes"},
    {"pockets", "Pockets"},
    {"calendar", "Calendar"},
    {"phone", "Phone"},
    {"explained", "Explained"},
    {"activity", "Activity"}
  ]
  @home_tab_keys Enum.map(@home_tabs, &elem(&1, 0))

  # The corner widget's sub-tabs, owned by the component that renders the rail.
  # A guard cannot call a remote function, so this is read at compile time —
  # which is the whole point: the two lists can no longer drift apart.
  @widget_tab_keys BusterClawWeb.HomeWidget.widget_tab_keys()

  @doc "The Home sub-tabs, in display order. The rail and the guard share this."
  def home_tabs, do: @home_tabs

  @impl true
  def mount(_params, _session, socket) do
    today = LocalTime.today()

    if connected?(socket) do
      Phoenix.PubSub.subscribe(BusterClaw.PubSub, Appearance.home_topic())
      Phoenix.PubSub.subscribe(BusterClaw.PubSub, Appearance.topic(:widget))
      subscribe_chat_look()
      Notifications.subscribe()
      # Keep the corner-widget's "Recent activity" live as calls/texts land.
      Telephony.subscribe()
      # The Phone sub-tab's component cannot subscribe for itself — it has no
      # process. This host subscribes and relays; see `PhoneComponent`.
      BusterClaw.Contacts.subscribe()
      # Keep the Activity tab's BC Minutes live as the agent appends entries.
      BusterClaw.Journal.subscribe()
      # Same relay for the Notes vault: a `note_*` command run in the terminal
      # must show up in an open rail without a tab switch.
      BusterClaw.Notes.subscribe()
      # The Music tab renders transport it does not own — the player is the
      # sticky dock LiveView, so its state arrives over PubSub.
      BusterClaw.Music.Player.subscribe_state()
      # And the Vox tab: a render started here can take tens of minutes, so its
      # completion has to find whichever surface is still open. Subscribed by the
      # host for the usual reason — a component shares this process, and would
      # double every broadcast if it subscribed too.
      BusterClaw.Voice.Renderer.subscribe()
      Process.send_after(self(), :sky_refresh, @sky_refresh_ms)
    end

    {:ok,
     socket
     |> assign(:page_title, "Home")
     |> assign(:home_bg, Appearance.home_background_state())
     |> assign(:widget_bg, Appearance.background(:widget))
     |> assign_chat_look()
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
     # Which Explained sub-tab is showing. Owned here for the usual reason —
     # the tab's `:if` discards the panel on every switch — so a half-read
     # tutorial survives a glance at Chat. The key list belongs to ExplainedPanel.
     |> assign(:explained_tab, "intro")
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
     # The HTML5 half of the dropzone. It is the DEV half: WKWebView does not
     # hand the DOM file contents on an OS drop, so in the packaged app this
     # never fires and the `attach_paths` event below is the only live path.
     # Both are declared because the `ChatDropzone` hook picks one per
     # environment, exactly as `WorkspaceDropzone` already does.
     # `max_file_size` refuses on the CLIENT, before a byte is uploaded — the
     # refusal-at-the-drop the roadmap asks for rather than one after an upload
     # that appeared to succeed. `accept: :any` is deliberate: the store decides
     # what a file is (an `.ex` or a `.log` is a perfectly good text attachment)
     # and a browser-side extension whitelist would refuse those before the store
     # ever saw them.
     |> allow_upload(:chat_attachments,
       accept: :any,
       max_entries: @attach_max_entries,
       max_file_size: BusterClaw.Agent.Attachments.limits().max_file_bytes,
       # Staged on drop, not on submit: a chip the user cannot see and cancel
       # before sending is worse than no attachment at all.
       auto_upload: true,
       progress: &handle_attach_progress/3
     )
     |> then(fn s -> if connected?(s), do: mount_weather(s), else: s end)}
  end

  # An upload only becomes an attachment once its bytes have arrived. LiveView
  # hands us a temp file it will delete as soon as this returns, so the store
  # copies during the consume — there is no later moment to do it in.
  defp handle_attach_progress(:chat_attachments, entry, socket) do
    if entry.done? do
      socket =
        consume_uploaded_entry(socket, entry, fn %{path: path} ->
          {:ok, ChatAttachments.stage_upload(socket, path, entry.client_name)}
        end)

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  # --- Notify widget ---------------------------------------------------------

  defp load_notifications(socket), do: assign(socket, :notifications, Notifications.upcoming())

  defp notify_form, do: to_form(%{"label" => "", "minutes" => "", "at" => ""}, as: :notify)

  defp assign_notify_error(socket, params, field, message) do
    assign(socket, :notify_form, to_form(params, as: :notify, errors: [{field, {message, []}}]))
  end

  # Timer/alarm/reminder wall-clock arithmetic lives in
  # `BusterClaw.Notifications.Schedule` — pure, and extracted 08-03 so the
  # next-occurrence and DST cases can be asserted without driving a mount.

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
      when tab in @home_tab_keys do
    {:noreply, switch_home_tab(socket, tab)}
  end

  # The Explained rail's key list is owned by ExplainedPanel (one registry feeds the
  # rail, this whitelist, and the panel dispatch); an unknown key is refused, not
  # crashed on — same posture as the guarded tab handlers around it.
  def handle_event("select_explained_tab", %{"tab" => tab}, socket) do
    if tab in BusterClawWeb.ExplainedPanel.tab_keys() do
      {:noreply, assign(socket, :explained_tab, tab)}
    else
      {:noreply, socket}
    end
  end

  # A tutorial's "Try in Chat" button. It **prefills and stops** — same
  # `bc:chat_prefill` path the corner widget's Email button uses, and for the
  # same reason: staging an ask is not making one. This is the whole safety
  # story for Explained's runnable demos. Opening a tutorial, or clicking every
  # button on it, must never execute a command; the operator still presses send,
  # which is also where the agent's own gates get their chance to fire.
  #
  # The text is bounded rather than trusted for length: it arrives from a
  # phx-value on the operator's own page, so it is not a trust problem, but an
  # unbounded string pushed into the composer is a denial-of-usability one.
  def handle_event("explained_try_in_chat", %{"text" => text}, socket)
      when is_binary(text) and byte_size(text) in 1..2000 do
    {:noreply,
     socket
     |> switch_home_tab("chat")
     |> push_event("bc:chat_prefill", %{text: text})}
  end

  def handle_event("explained_try_in_chat", _params, socket), do: {:noreply, socket}

  def handle_event("select_widget_tab", %{"tab" => tab}, socket)
      when tab in @widget_tab_keys do
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
    label = params |> Map.get("label", "") |> String.trim() |> Schedule.default_label(kind)

    with :ok <- if(label == "", do: {:error, :label, "add a label"}, else: :ok),
         {:ok, fire_at} <- Schedule.fire_at(kind, params) do
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

  def handle_event("chat_send", %{"message" => text} = params, socket) do
    # Sending barges in on any reply still being spoken.
    socket = push_event(socket, "bc:stop_speak", %{})
    trimmed = String.trim(text)

    # An attachment-only message is a real message — "here, look at this" is how
    # every chat this is compared to behaves — so empty text alone is no longer
    # what makes a submit a no-op.
    if trimmed == "" and ChatAttachments.pending(socket) == [] do
      {:noreply, socket}
    else
      case ChatAttachments.gate(socket) do
        {:ok, socket} -> {:noreply, dispatch_chat(socket, trimmed, delivery_param(params))}
        {:blocked, socket} -> {:noreply, socket}
      end
    end
  end

  # --- chat attachments ------------------------------------------------------
  #
  # Two ways in, one per environment. `attach_paths` is the packaged app: the
  # Tauri native drag-drop event delivers absolute PATHS and the server reads
  # them. The browser (dev) path is `allow_upload` + `phx-drop-target`, declared
  # in `mount/3` — `allow_upload` alone is not enough in the packaged app, which
  # is the entire reason the path route exists.

  def handle_event("attach_paths", %{"paths" => paths}, socket) do
    {:noreply, ChatAttachments.stage_paths(socket, List.wrap(paths))}
  end

  # A refusal the hook made for itself (wrong type, too big, unreadable) still
  # has to reach the user — a drop that silently does nothing is the false
  # affordance this feature exists to remove.
  def handle_event("attach_error", %{"reason" => reason} = params, socket) do
    {:noreply, ChatAttachments.refuse(socket, reason, Map.get(params, "filename"))}
  end

  def handle_event("remove_attachment", %{"id" => id}, socket) do
    {:noreply, ChatAttachments.remove(socket, id)}
  end

  def handle_event("dismiss_attach_error", _params, socket) do
    {:noreply, ChatAttachments.dismiss_error(socket)}
  end

  # An upload LiveView itself refused (too large, too many). Cancelling is what
  # clears it out of `@uploads`, so the banner it renders has a way to go away.
  def handle_event("cancel_attach_upload", %{"ref" => ref}, socket) do
    {:noreply, cancel_upload(socket, :chat_attachments, ref)}
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
    {:noreply, open_new_chat(socket)}
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
    {:noreply, close_chat(socket, id)}
  end

  @impl true
  def handle_info({:agent_chat, conv_id, payload}, socket),
    do: {:noreply, apply_chat(socket, conv_id, payload)}

  # The homepage background changed in settings — re-render it live. Switching
  # onto the weather shader also feeds it the real sky right away (from the
  # already-loaded conditions, or a fresh fetch).
  # The corner widget's Time & Place panel. Its own topic and its own assign —
  # the homepage's background and the card's are two surfaces that happen to
  # share a page.
  def handle_info({:widget_background, state}, socket) do
    {:noreply, assign(socket, :widget_bg, state)}
  end

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

  # The chat's skin or text size changed in Settings → Appearance. One assign
  # restyles the whole transcript, messages already on screen included — both axes
  # are CSS-only by contract. See `apply_chat_look/3`.
  def handle_info({axis, value}, socket) when axis in [:chat_skin, :chat_text_size],
    do: {:noreply, apply_chat_look(socket, axis, value)}

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
  # Two consumers of the same broadcast: the corner widget's activity list, and
  # the Phone sub-tab's component. The component decides what each message means
  # (`PhoneComponent.handle_notify/2`); this only relays.
  def handle_info({:telephony_event, _event} = message, socket) do
    BusterClawWeb.PhoneComponent.notify(@phone_component_id, message)
    {:noreply, load_comms(socket)}
  end

  def handle_info(:telephony_costs_updated = message, socket) do
    BusterClawWeb.PhoneComponent.notify(@phone_component_id, message)
    {:noreply, socket}
  end

  def handle_info(message, socket)
      when message in [:telephony_contacts_changed, :contacts_changed] do
    BusterClawWeb.PhoneComponent.notify(@phone_component_id, message)
    {:noreply, load_comms(socket)}
  end

  def handle_info({BusterClawWeb.PhoneComponent, :reload, id}, socket) do
    BusterClawWeb.PhoneComponent.notify(id, :reload)
    {:noreply, socket}
  end

  # A speech render landed. Relayed whether or not the Vox tab is showing: the
  # renders that matter here are the slow ones, and an operator who started a
  # forty-minute chime set and went back to Chat should not lose the result.
  # `send_update` to a component that is not currently rendered is a no-op, which
  # is what makes relaying unconditionally safe (`PhoneComponent` has relied on
  # this since 08-08).
  def handle_info({:voice_render, _key, _result} = message, socket) do
    BusterClawWeb.VoxComponent.notify(@vox_component_id, message)
    {:noreply, socket}
  end

  # `Task.async/1` inside `VoxComponent` monitors from THIS process, so the reply
  # lands in this mailbox with nothing to say who it belongs to. Forwarded as-is;
  # the component matches the ref against the two it started and drops the rest,
  # which is what keeps this relay honest if StatusLive ever runs a task of its
  # own. The `:DOWN` that follows is swallowed by the catch-all below — the
  # component flushes the monitor itself.
  def handle_info({ref, result}, socket) when is_reference(ref) do
    BusterClawWeb.VoxComponent.notify(@vox_component_id, {:task, ref, result})
    {:noreply, socket}
  end

  # An entry (agent or another session) landed in the day's Notes — ping the
  # Relay journal broadcasts to the read-only Activity component. `send_update`
  # is safe while another tab is mounted; the next Activity mount reads disk.
  def handle_info({:journal_appended, _date}, socket) do
    send_update(BusterClawWeb.ActivityComponent,
      id: "home-activity",
      refresh: System.unique_integer()
    )

    {:noreply, socket}
  end

  # A note changed under us — an agent command, or another window. The component
  # re-reads the vault and reconciles the open note; a draft in flight turns this
  # into the conflict banner rather than a silent replacement.
  def handle_info({:notes, _event}, socket) do
    send_update(BusterClawWeb.NotesComponent,
      id: "home-notes",
      refresh: System.unique_integer()
    )

    {:noreply, socket}
  end

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

  defp switch_home_tab(socket, tab), do: assign(socket, :home_tab, tab)

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} socket={@socket} fit_viewport>
      <section class="ic-home relative isolate flex min-h-0 flex-1 flex-col">
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
        <BusterClawWeb.ShaderCanvas.shader_canvas bg={@home_bg} prefix="home" class="ic-home-bg" />
        <div class="relative z-10 flex min-h-0 flex-1 flex-col space-y-8">
          <div class="flex items-stretch gap-4 border-b-2 border-base-content/20 pb-5">
            <div class="shrink-0 space-y-4">
              <BusterClawWeb.BrandArt.banner url={@banner_url} />
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
              widget_bg={@widget_bg}
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
                  chat entirely and mounts the full calendar in its place. The
                  right side of this row was the active tab's action slot; the
                  Studio was its only claimant and moved to /studio on 08-16, so
                  nothing claims it today. --%>
            <div class="flex flex-wrap items-center justify-between gap-2">
              <div
                class="flex gap-0.5 border-2 border-base-content/20 p-0.5"
                role="tablist"
                aria-label="Home view"
              >
                <button
                  :for={{key, label} <- home_tabs()}
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
            </div>

            <div :if={@home_tab == "chat"} class="flex min-h-0 flex-1 flex-col gap-2">
              <BusterClawWeb.ChatPanel.chat_tabs chats={@chats} active={@active_chat} />
              <BusterClawWeb.ChatPanel.chat_panel
                messages={@streams.chat_messages}
                seq={@chat_seq}
                running={@chat_running}
                steerable={@chat_steerable}
                announcement={@chat_announcement}
                thinking={@chat_thinking}
                queue={@chat_queue}
                agent_cli_missing={@agent_cli_missing}
                attachments={@chat_attachments}
                attach_error={@chat_attach_error}
                upload={@uploads.chat_attachments}
                skin={@chat_skin}
                text_size={@chat_text_size}
              />
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

            <%!-- Phone left the dock on 08-08: a normal user has no provisioned
                  number, so a top-level destination overstated the app. Same
                  component the `/phone` route renders — see `PhoneComponent`. --%>
            <div :if={@home_tab == "phone"} class="flex min-h-0 flex-1 flex-col overflow-y-auto">
              <.live_component module={BusterClawWeb.PhoneComponent} id="home-phone" />
            </div>

            <%!-- The same component the `/voice` route renders — see `VoxComponent`.
                  It scrolls: nine panels is taller than the pane, and unlike Notes
                  it owns no scroll region of its own. --%>
            <div :if={@home_tab == "vox"} class="flex min-h-0 flex-1 flex-col overflow-y-auto">
              <%!-- Literal, not `@vox_component_id`: inside HEEx that would mean an
                    assign, and the module attribute of the same name silently is
                    not one. Same trap `PhoneLive` documents. --%>
              <.live_component module={BusterClawWeb.VoxComponent} id="home-vox" />
            </div>

            <div :if={@home_tab == "notes"} class="flex min-h-0 flex-1 flex-col">
              <.live_component module={BusterClawWeb.NotesComponent} id="home-notes" />
            </div>
            <div :if={@home_tab == "pockets"} class="flex min-h-0 flex-1 flex-col">
              <.live_component module={BusterClawWeb.PocketsPanel} id="home-pockets" />
            </div>

            <div :if={@home_tab == "explained"} class="flex min-h-0 flex-1 flex-col">
              <BusterClawWeb.ExplainedPanel.explained_panel tab={@explained_tab} />
            </div>

            <div :if={@home_tab == "activity"} class="flex min-h-0 flex-1 flex-col">
              <.live_component module={BusterClawWeb.ActivityComponent} id="home-activity" />
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
