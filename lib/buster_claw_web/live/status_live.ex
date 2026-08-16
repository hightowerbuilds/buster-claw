defmodule BusterClawWeb.StatusLive do
  use BusterClawWeb, :live_view

  # The chat surface — a third of this file until 08-08 — imported rather than
  # aliased so every call site below reads as it did before the split.
  import BusterClawWeb.Status.Chat
  import BusterClawWeb.Status.Comms
  import BusterClawWeb.Status.Studio
  import BusterClawWeb.Status.Weather

  require Logger

  alias BusterClaw.Agent.Chat
  alias BusterClaw.Appearance
  alias BusterClaw.Contacts
  alias BusterClaw.LocalTime
  alias BusterClaw.Notifications
  alias BusterClaw.Notifications.Schedule
  alias BusterClaw.Notifications.StudioMix
  alias BusterClaw.Runtime.Status
  alias BusterClaw.Setup
  alias BusterClaw.Telephony
  alias BusterClaw.TrustedSenders
  alias BusterClaw.Weather
  alias BusterClawWeb.Status.ChatAttachments
  alias BusterClawWeb.Status.Recorder
  alias BusterClawWeb.Status.Voice

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

  # The Home sub-tabs, in display order — ONE list, feeding both the rail and the
  # `select_home_tab` guard. They were two lists until 08-08, which is how Phone
  # arrived as a button the server then refused: the rail offered it, the guard
  # had never heard of it, and the click raised.
  @home_tabs [
    {"chat", "Chat"},
    {"notes", "Notes"},
    {"pockets", "Pockets"},
    {"calendar", "Calendar"},
    {"phone", "Phone"},
    {"studio", "Studio"},
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
     # Which Studio sub-tab is showing (Mix | Voice) — owned here for the same
     # reason as the arranger state below it. See `Status.Studio`.
     |> assign_studio_tab()
     |> Voice.assign_voice()
     |> Recorder.assign_recorder()
     # Transport for the Studio's music library. nil until the dock player
     # announces — it renders a library with no transport rather than guessing.
     |> assign(:music_player, nil)
     # Which source the Studio has open. Owned here rather than in the component
     # because the tab's `:if` discards the component (and its state) on every
     # tab switch; an in-progress selection must outlive that.
     |> assign(:studio_source, nil)
     # The in-progress trim, in milliseconds. Same ownership reasoning as
     # :studio_source — an edit must outlive a glance at Chat.
     |> assign(:studio_trim, nil)
     # Arranger keyboard state: which clip is selected, what was copied, and the
     # undo/redo stacks. Held here rather than in the component for the usual
     # reason — `:if` discards the component — and because losing an undo stack
     # on a tab switch is the kind of thing that reads as the feature being
     # broken.
     |> assign(:studio_clip, nil)
     |> assign(:studio_preview, nil)
     |> assign(:studio_clipboard, nil)
     |> assign(:studio_undo, [])
     |> assign(:studio_redo, [])
     # Which sidebar groups are folded shut, by group key. Held here for the
     # same reason as everything above it — a sidebar that re-expands every time
     # you glance at Chat is not collapsible, it is briefly tidy — and read from
     # Settings, because one that re-expands on restart is a preference the app
     # keeps forgetting.
     |> assign(:studio_collapsed, BusterClawWeb.SoundStudioComponent.collapsed_groups())
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

  # The Studio's sub-tab rail (Mix | Voice). Whitelisted through
  # `StudioPanel.tab_keys/0` inside `Status.Studio.select_studio_tab/2`.
  def handle_event("select_studio_tab", %{"tab" => tab}, socket) do
    {:noreply, select_studio_tab(socket, tab)}
  end

  # Voice (Ramshackle). Every clause delegates in full to `Status.Voice`; the
  # corpus read is lazy, so opening the tab is what loads it and switching away
  # and back does not re-read ten files.
  def handle_event("voice_search", %{"query" => query}, socket),
    do: {:noreply, Voice.put_query(socket, query)}

  def handle_event("voice_sentence", %{"sentence" => text}, socket),
    do: {:noreply, Voice.put_sentence(socket, text)}

  def handle_event("voice_refresh", _params, socket),
    do: {:noreply, Voice.load_report(socket)}

  # The Voice Library's own navigation, and the recorder inside it. ONE clause
  # for the recorder's six sub-actions rather than six clauses: they share a
  # shape, `Status.Recorder` owns the dispatch, and this file is at its cap for a
  # reason. The take arrives separately because it carries audio.
  def handle_event("voice_section", %{"section" => section}, socket),
    do: {:noreply, Voice.put_section(socket, section)}

  def handle_event("voice_select", %{"word" => word}, socket),
    do: {:noreply, Voice.select_word(socket, word)}

  def handle_event("voice_preview", _params, socket),
    do: {:noreply, Voice.build_preview(socket)}

  def handle_event("voice_prefer", %{"source" => source, "start" => start}, socket),
    do: {:noreply, Voice.prefer_take(socket, source, start)}

  def handle_event("voice_unprefer", _params, socket),
    do: {:noreply, Voice.unprefer_take(socket)}

  def handle_event("voice_delete", %{"source" => source, "start" => start}, socket),
    do: {:noreply, Voice.delete_take(socket, source, start)}

  # A sentence chip leads somewhere: a word that exists opens in Words, a word
  # that does not arms the recorder for it.
  def handle_event("voice_open_word", %{"word" => word}, socket),
    do: {:noreply, Voice.open_word(socket, word)}

  def handle_event("voice_record_word", %{"word" => word}, socket),
    do: {:noreply, socket |> Recorder.put_word(word) |> Voice.put_section("record")}

  def handle_event("contribute", %{"do" => action} = params, socket),
    do: {:noreply, Recorder.handle(action, params, socket)}

  def handle_event("contribute_take", params, socket),
    do: {:noreply, Recorder.save_take(socket, params)}

  # The Studio's selection is owned HERE, not by the component: home tabs render
  # behind `:if`, which removes the DOM and discards the live_component with it,
  # so a selection held in the component would not survive a glance at Chat.
  # Re-selecting what is already open is a no-op. Without this guard, clicking
  # the open mix in the sidebar — or landing back on it after a tab switch —
  # would silently throw away its undo stack and any trim in progress.
  def handle_event("select_studio_source", %{"id" => id}, socket)
      when id == :erlang.map_get(:studio_source, socket.assigns) do
    {:noreply, socket}
  end

  def handle_event("select_studio_source", %{"id" => id}, socket) do
    # A trim belongs to the file it was drawn on. Carrying it to another source
    # would apply one file's in/out points to another's waveform. The undo stack
    # goes with it for the same reason: undoing into an arrangement you are no
    # longer looking at is not undo, it is vandalism.
    {:noreply,
     socket
     |> assign(:studio_source, id)
     |> assign(:studio_trim, nil)
     |> reset_studio_history()}
  end

  # Fold a sidebar group shut, or open it. The list is the collapsed set, so a
  # group the app adds later starts open — the right default for something new
  # appearing, and it means this never needs to know the full group roster.
  # Persisted on every toggle rather than on some later "save": there is no
  # moment in this UI that would mean "commit my folds".
  def handle_event("toggle_studio_group", %{"key" => key}, socket) when is_binary(key) do
    collapsed = socket.assigns.studio_collapsed
    next = if key in collapsed, do: List.delete(collapsed, key), else: [key | collapsed]

    BusterClawWeb.SoundStudioComponent.put_collapsed(next)
    {:noreply, assign(socket, :studio_collapsed, next)}
  end

  # ---------------------------------------------------------------------------
  # Arranger: selection, clipboard, undo/redo
  # ---------------------------------------------------------------------------

  def handle_event("studio_copy", _params, socket) do
    case selected_clip(socket) do
      nil ->
        {:noreply, socket}

      clip ->
        # The clipboard holds a spec, not the clip: pasting makes a NEW clip
        # with its own id, so a pasted copy can be moved and deleted on its own.
        #
        # `effects` joined the spec on 08-16. Without it, copying a clip you had
        # shaped pasted it DRY — silently, and only audible on render, which is
        # the worst place to discover it. Effects arrived that morning and this
        # spec was written before they existed.
        {:noreply,
         assign(socket, :studio_clipboard, %{
           source: clip.source,
           duration_ms: clip.duration_ms,
           effects: StudioMix.chain(clip)
         })}
    end
  end

  # Paste lands on the selected clip's track, so a copy sits beside its
  # original; with nothing selected it falls to the first track rather than
  # refusing. (This comment had drifted to the far end of the file, above an
  # unrelated function, until the 08-08 split walked past it.)
  def handle_event("studio_paste", _params, socket) do
    case socket.assigns.studio_clipboard do
      nil ->
        {:noreply, socket}

      %{} = spec ->
        {:noreply,
         mutate_open_mix(socket, fn mix ->
           track = StudioMix.paste_track(mix, socket.assigns.studio_clip)
           StudioMix.place_copy(mix, spec, track.id, StudioMix.track_end_ms(track))
         end)}
    end
  end

  def handle_event("studio_delete_clip", _params, socket) do
    case socket.assigns.studio_clip do
      nil ->
        {:noreply, socket}

      id ->
        socket = mutate_open_mix(socket, &StudioMix.remove_clip(&1, id))
        {:noreply, assign(socket, :studio_clip, nil)}
    end
  end

  # The selected clip's effect chain. Each is one line into `Status.Studio`,
  # which routes through `mutate_open_mix/2` so every one of them is undoable.
  # A hook's `pushEvent` reaches the LIVEVIEW, not the component — `pushEventTo`
  # is what targets a component, which is why `move_clip` two lines below it in
  # `track_arrange.js` uses that instead. Without this clause every click on a
  # clip was a FunctionClauseError: the LiveView crashed, the client reconnected,
  # and the remount put the operator back on Chat. Reported twice before it was
  # found, because no server test reproduced it — `render_hook(element(...))`
  # routes to the component and only `render_hook(view, ...)` routes here.
  def handle_event("select_clip", %{"id" => id}, socket) when is_binary(id),
    do: {:noreply, assign(socket, :studio_clip, id)}

  # A payload without an id costs a no-op, never a crash-and-remount. The whole
  # bug above was one unmatched clause; a second one is not the way to end it.
  def handle_event("select_clip", _params, socket), do: {:noreply, socket}

  def handle_event("studio_add_effect", %{"type" => type}, socket),
    do: {:noreply, effect_change(socket, &StudioMix.add_effect(&1, &2, type))}

  def handle_event("studio_remove_effect", %{"position" => position}, socket),
    do: {:noreply, effect_change(socket, &StudioMix.remove_effect(&1, &2, to_int(position)))}

  def handle_event("studio_set_effect_param", params, socket) do
    %{"position" => position, "key" => key, "value" => value} = params

    {:noreply,
     effect_change(
       socket,
       &StudioMix.put_effect_param(&1, &2, to_int(position), key, value)
     )}
  end

  def handle_event("studio_preview_clip", _params, socket),
    do: {:noreply, preview_clip(socket)}

  def handle_event("studio_undo", _params, socket) do
    {:noreply, step_history(socket, :studio_undo, :studio_redo)}
  end

  def handle_event("studio_redo", _params, socket) do
    {:noreply, step_history(socket, :studio_redo, :studio_undo)}
  end

  # Pushed by the WaveTrim hook on pointerup. Held here, not in the component,
  # for the same reason the source selection is: `:if` discards the component.
  def handle_event("trim_select", %{"from_ms" => from, "to_ms" => to}, socket)
      when is_number(from) and is_number(to) and to > from do
    {:noreply, assign(socket, :studio_trim, %{from_ms: from * 1.0, to_ms: to * 1.0})}
  end

  def handle_event("trim_select", _params, socket), do: {:noreply, socket}

  def handle_event("trim_clear", _params, socket) do
    # The hook clears its own overlay on a click; this also answers the Clear
    # button, whose overlay has not been touched yet.
    {:noreply,
     socket
     |> assign(:studio_trim, nil)
     |> push_event("studio:trim", %{from_ms: nil, to_ms: nil})}
  end

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

  # An entry (agent or another session) landed in the day's Notes — ping the
  # The dock player announced new transport state; the Music tab renders it.
  def handle_info({:music_state, player}, socket) do
    {:noreply, assign(socket, :music_player, player)}
  end

  # The Studio finished an edit and wants the result opened. The component does
  # the work; only the parent can change the selection, because only the parent
  # holds it. The trim clears with it — its in/out points describe the source,
  # not the file just made from it.
  def handle_info({:studio_select, id}, socket) do
    {:noreply,
     socket
     |> assign(:studio_source, id)
     |> assign(:studio_trim, nil)
     |> reset_studio_history()
     |> push_event("studio:trim", %{from_ms: nil, to_ms: nil})}
  end

  # The component mutates the open arrangement itself (buttons and forms); it
  # hands the PREVIOUS state up so undo has something to go back to. Sending the
  # old state rather than having the parent re-read it avoids a race where the
  # component has already written the new one to disk.
  def handle_info({:studio_history, %StudioMix{} = previous}, socket) do
    {:noreply, push_studio_history(socket, previous)}
  end

  # Forwarded by the component, which receives the click because the arranger
  # hook is `phx-target`-bound to it. The selection belongs here, beside the
  # clipboard and undo stacks that consume it.
  def handle_info({:studio_select_clip, id}, socket) do
    {:noreply, assign(socket, :studio_clip, id)}
  end

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
                  right side of this row is the active tab's action slot —
                  today only the Studio claims it. --%>
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

              <BusterClawWeb.SoundStudioComponent.toolbar :if={
                @home_tab == "studio" and @studio_tab == "mix"
              } />
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

            <div :if={@home_tab == "notes"} class="flex min-h-0 flex-1 flex-col">
              <.live_component module={BusterClawWeb.NotesComponent} id="home-notes" />
            </div>
            <div :if={@home_tab == "pockets"} class="flex min-h-0 flex-1 flex-col">
              <.live_component module={BusterClawWeb.PocketsPanel} id="home-pockets" />
            </div>

            <%!-- Two sub-tabs: Mix (this studio) and Voice. The rail is in
                  StudioPanel, above the FROZEN component, which Mix renders
                  unchanged with the assigns it always had. --%>
            <div :if={@home_tab == "studio"} class="flex min-h-0 flex-1 flex-col">
              <BusterClawWeb.StudioPanel.studio_panel
                tab={@studio_tab}
                player={@music_player}
                studio_source={@studio_source}
                studio_trim={@studio_trim}
                studio_clip={@studio_clip}
                studio_clip_data={selected_clip(assigns)}
                studio_preview={@studio_preview}
                studio_clipboard={@studio_clipboard}
                studio_undo={@studio_undo}
                studio_redo={@studio_redo}
                studio_collapsed={@studio_collapsed}
                voice_report={@voice_report}
                voice_error={@voice_error}
                voice_query={@voice_query}
                voice_sentence={@voice_sentence}
                voice_rows={Voice.vocabulary(assigns, @voice_query)}
                voice_check={Voice.sentence_check(assigns, @voice_sentence)}
                voice_section={@voice_section}
                voice_selected={@voice_selected}
                voice_takes={@voice_takes}
                voice_preview={@voice_preview}
                voice_preview_error={@voice_preview_error}
                voice_notice={@voice_notice}
                recorder={@recorder}
              />
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

  # `phx-value-*` arrives as a string; the mix API wants an index.
  defp to_int(value) when is_integer(value), do: value

  defp to_int(value) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, _rest} -> parsed
      :error -> -1
    end
  end

  defp to_int(_value), do: -1
end
