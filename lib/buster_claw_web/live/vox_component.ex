defmodule BusterClawWeb.VoxComponent do
  @moduledoc """
  Vox — everything the app's voice is made of, in one embeddable surface.

  Nine panels in three acts: **train** it (the engine, its settings, and a
  recording of your own voice), **make** phrases with it, and **assign** those
  phrases to the places they will be heard — the notification chimes and the
  phone greeting.

  ## An embeddable component, and why

  This renders inline with no layout of its own, so a host page provides the
  chrome. Two hosts use it: `BusterClawWeb.VoiceLive` (the `/voice` route, kept for
  deep links and split panes — it left the Settings rail on 09-05) and `BusterClawWeb.StatusLive` (the homepage "Vox"
  sub-tab). Keeping the behavior here means both surfaces stay in sync — the same
  reason `PhoneComponent` and `CalendarComponent` exist, and the shape
  `VOX_TAB_ROADMAP` `D2` asks for by name.

  ## The host contract

  A `LiveComponent` has no process, so it cannot subscribe and it cannot receive
  a message. **The host subscribes and forwards**, through `notify/2` so no host
  has to hand-roll the message shapes. Two things arrive that way:

    * `{:voice_render, key, result}` — a `Voice.Renderer` job landed. The host
      holds the `Renderer.subscribe/0`.
    * `{:task, ref, result}` — a reply from one of the two long operations below.

  Hosts deliberately subscribe rather than having this component call
  `Renderer.subscribe/0` in `update/2`: a component shares its host's process, so
  a host that already subscribes would receive every broadcast twice.

  ## Why the task replies need forwarding too

  `chime-render-all` is tens of minutes of work, so it runs in a `Task`. A
  component shares its host's process, which means `Task.async/1` here monitors
  from the **host**, and the `{ref, result}` reply lands in the *host's* mailbox
  rather than anywhere this module can see. Hence the second forwarded shape.

  A host may run tasks of its own, so this never assumes an unrecognised ref is
  ours: `handle_notify/2` checks the ref against the one we started and silently
  drops anything else.
  """
  use BusterClawWeb, :live_component

  alias BusterClaw.Notifications.Sound
  alias BusterClaw.Voice.Chimes
  alias BusterClaw.Voice.Clips
  alias BusterClaw.Voice.Config
  alias BusterClaw.Voice.Engine
  alias BusterClaw.Voice.Greeting
  alias BusterClaw.Voice.Messages
  alias BusterClaw.Voice.Reference
  alias BusterClaw.Voice.Renderer
  alias BusterClawWeb.Vox.Chimes, as: ChimePanel
  alias BusterClawWeb.Vox.Create
  alias BusterClawWeb.Vox.EngineProbe
  alias BusterClawWeb.Vox.EngineSettings
  alias BusterClawWeb.Vox.Files
  alias BusterClawWeb.Vox.Greeting, as: GreetingPanel
  alias BusterClawWeb.Vox.Messages, as: MessagePanel
  alias BusterClawWeb.Vox.Quality
  alias BusterClawWeb.Vox.Reading

  # The sidebar's tabs, in order — ONE list, feeding both the rail and the
  # `select_vox_tab` guard. Two lists is how Home once shipped a button the
  # server refused, and it is the third surface in two days to be built this way
  # on purpose.
  #
  # The split is the operator's (09-05): *"the audio creation, audio files, and
  # the rest of what is there."* Create MAKES audio, Files holds what was made,
  # Alerts decides where it is heard, Engine is the machinery, and Reading aloud
  # is a different synthesizer entirely.
  @vox_tabs [
    {"create", "Create"},
    {"files", "Files"},
    {"alerts", "Alerts"},
    {"engine", "Engine"},
    {"reading", "Reading aloud"}
  ]
  @vox_tab_keys Enum.map(@vox_tabs, &elem(&1, 0))

  @doc "The Vox2B sidebar tabs, in order. The rail and the guard share this."
  def vox_tabs, do: @vox_tabs

  @doc """
  Forward a host's `Voice.Renderer` broadcast, or a `Task` reply. See the
  moduledoc: the host owns the subscription and the mailbox, this component owns
  the response.
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

  # Every read here touches the disk (the recordings dir, the clip manifest, the
  # chime cache), so it runs once on first update rather than on every parent
  # re-render. That matters more on the homepage than it did on a settings route:
  # StatusLive re-renders on every streamed chat token.
  defp load_initial(socket) do
    socket
    |> assign(:vox_tab, "create")
    |> assign(:engine, Engine.probe())
    # render key -> chime key, so a finished render knows which chime it is.
    # The renderer addresses work by content hash and has no idea these are
    # notification lines; this map is the only thing that does.
    |> assign(:chime_jobs, %{})
    |> assign(:chime_task, nil)
    # Monotonic ms from when each slow job started, so the render chip's clock
    # survives the homepage discarding this panel on a tab switch. nil means
    # nothing is in flight — which is also what hides each chip.
    |> assign(:chime_since, nil)
    |> assign(:chime_note, nil)
    # The render key of a greeting being made, so its completion knows to
    # publish rather than just sit in the cache.
    |> assign(:greeting_job, nil)
    |> assign(:greeting_since, nil)
    |> assign(:greeting_note, nil)
    |> assign(:config_note, nil)
    |> load_chimes()
    |> load_greeting()
    |> load_engine_config()
    # The recorder's capability report, the recordings, and the typed clips.
    # `clip_jobs` maps a render key back to the text that asked for it, for the
    # same reason `chime_jobs` does: the renderer addresses work by content hash
    # and has no idea what it is for.
    |> assign(:mic_state, nil)
    |> assign(:ref_note, nil)
    |> assign(:clip_text, "")
    |> assign(:clip_quote, nil)
    |> assign(:clip_jobs, %{})
    |> assign(:clip_note, nil)
    # Spoken messages, moved here from Settings → Notify on 09-05. No job map
    # like `clip_jobs`: readiness is read off DISK on each re-list, so a render
    # broadcast is only a cue to look again — nothing here tracks which render
    # was ours, and nothing needs to.
    |> assign(:message_note, nil)
    |> assign(:message_form, %{"name" => "", "text" => ""})
    |> load_reference()
    |> load_clips()
    |> load_messages()
  end

  # Ready messages are installed into the sound library on the way past, so the
  # preview button and a fired notification both find `message-<name>.wav`
  # without a separate step the operator has to know about.
  defp load_messages(socket) do
    messages = Messages.list()

    for %{ready?: true, installed?: false, name: name} <- messages,
        do: Messages.ensure_installed(name)

    assign(socket, :messages, Messages.list())
  end

  # The recordings, plus the length and grade of the one in use — see
  # `Vox.Quality`, which owns both and the quote they feed.
  defp load_reference(socket) do
    socket
    |> assign(:references, Reference.list())
    |> Quality.assign_reference(Config.get().reference_audio)
    |> assign_quote()
  end

  defp assign_quote(socket), do: Quality.assign_quote(socket)

  defp failed(what, reason), do: "#{what} — #{Renderer.describe_error(reason)}"

  defp load_clips(socket), do: assign(socket, :clips, Clips.list())

  # The stored knobs plus the one number they change: how many chimes are already
  # made under them. The cache is keyed on the argv, so a new device or a
  # reference clip turns every made chime into a miss, and the page says so in
  # numbers rather than letting the operator find out at the button.
  defp load_engine_config(socket) do
    socket
    |> assign(:engine_config, Config.get())
    |> assign(:chimes_made, Chimes.made_count())
    |> assign_quote()
  end

  defp load_greeting(socket) do
    socket
    |> assign(:greeting_text, Greeting.text())
    |> assign(:greeting_status, Greeting.status())
  end

  defp load_chimes(socket) do
    assign(socket, :chimes, Enum.map(Chimes.keys(), &chime_row/1))
  end

  defp chime_row(key) do
    %{
      key: key,
      label: Sound.route_label(key),
      line: Chimes.line(key),
      installed?: Chimes.installed?(key)
    }
  end

  @impl true
  def handle_event("select_vox_tab", %{"tab" => tab}, socket)
      when tab in @vox_tab_keys do
    {:noreply, assign(socket, :vox_tab, tab)}
  end

  def handle_event("engine-recheck", _params, socket) do
    {:noreply, assign(socket, :engine, Engine.refresh())}
  end

  def handle_event("chime-lines-save", %{"lines" => lines}, socket) do
    Enum.each(lines, fn {key, text} -> Chimes.put_line(key, text) end)

    {:noreply, socket |> load_chimes() |> assign(:chime_note, "Lines saved.")}
  end

  def handle_event("chime-lines-reset", _params, socket) do
    Chimes.reset_all()
    {:noreply, socket |> load_chimes() |> assign(:chime_note, "Back to the seeded lines.")}
  end

  # One engine invocation for the whole set, in a task.
  #
  # The obvious alternative — one Renderer job per line — reports progress as each
  # lands, which is nicer, and costs the model load sixteen times. Measured on
  # this machine that is 2 min 29 s of warm-up each, so the pretty version takes
  # roughly twice as long as the whole job needs to. For a forty-minute grind the
  # operator runs whenever they change the voice, halving it beats watching a
  # progress line.
  def handle_event("chime-render-all", _params, socket) do
    if socket.assigns.chime_task do
      {:noreply, assign(socket, :chime_note, "Already making them.")}
    else
      task = Task.async(fn -> Chimes.render_set() end)

      {:noreply,
       socket
       |> assign(:chime_task, task.ref)
       |> assign(:chime_since, System.monotonic_time(:millisecond))
       |> assign(
         :chime_note,
         "Making all #{length(Chimes.keys())} — one model load for the set. " <>
           "Expect tens of minutes; you can leave this tab."
       )}
    end
  end

  def handle_event("engine-config-save", %{"config" => attrs}, socket) do
    case Config.put(attrs) do
      :ok ->
        # A new engine path changes what `probe/0` finds; a new device or clip
        # changes which chimes count as made and whether the published greeting
        # still matches. All three re-read, because all three may have moved.
        socket =
          socket
          |> assign(:engine, Engine.refresh())
          |> load_engine_config()
          |> load_greeting()

        {made, total} = socket.assigns.chimes_made

        note =
          cond do
            made == total ->
              "Saved. Every chime is already made with these settings."

            made == 0 ->
              "Saved. These settings change the voice — all #{total} chimes need making again."

            true ->
              "Saved. #{total - made} of #{total} chimes need making again."
          end

        {:noreply, assign(socket, :config_note, note)}

      {:error, {field, :not_found}} ->
        {:noreply, assign(socket, :config_note, "#{humanize(field)}: no file there.")}

      {:error, {field, value}} ->
        {:noreply,
         assign(
           socket,
           :config_note,
           "#{humanize(field)}: #{inspect(value)} is not a value the engine accepts."
         )}
    end
  end

  def handle_event("engine-config-reset", _params, socket) do
    Config.reset()

    {:noreply,
     socket
     |> assign(:engine, Engine.refresh())
     |> load_engine_config()
     |> load_greeting()
     |> assign(:config_note, "Back to the engine's own defaults.")}
  end

  # --- the reference clip -------------------------------------------------------

  # The recorder reports what the browser found — ready, denied, unsupported —
  # rather than the page assuming. Kept as a state the markup can read.
  def handle_event("reference_report", %{"do" => "capability", "state" => state} = params, socket) do
    {:noreply, assign(socket, :mic_state, {state, Map.get(params, "detail")})}
  end

  def handle_event("reference_report", _params, socket), do: {:noreply, socket}

  def handle_event("reference_take", %{"pcm" => pcm, "sample_rate" => rate}, socket) do
    note =
      case Reference.save(pcm, rate) do
        {:ok, %{duration_ms: ms, peak: peak, clipped?: clipped?}} ->
          seconds = Float.round(ms / 1000, 1)
          base = "Saved #{seconds}s. This is your voice now — every render clones it."

          if clipped?,
            do: base <> " It clipped; a quieter take will clone cleaner.",
            else: base <> peak_hint(peak)

        {:error, :too_short} ->
          "Too short — the engine needs a few seconds to clone from. Ten is comfortable."

        {:error, :silent_take} ->
          "Nothing but silence came through. Check the input in System Settings → Sound."

        {:error, reason} ->
          "Could not save it: #{inspect(reason)}"
      end

    # A new reference makes every made chime a miss and the published greeting
    # stale, so both counts re-read alongside the recordings list.
    {:noreply,
     socket
     |> load_reference()
     |> load_engine_config()
     |> load_greeting()
     |> assign(:ref_note, note)}
  end

  def handle_event("reference_use", %{"name" => name}, socket) do
    note =
      case Reference.use(name) do
        :ok -> "Using that one."
        {:error, reason} -> "Could not: #{inspect(reason)}"
      end

    {:noreply,
     socket
     |> load_reference()
     |> load_engine_config()
     |> load_greeting()
     |> assign(:ref_note, note)}
  end

  def handle_event("reference_delete", %{"name" => name}, socket) do
    Reference.delete(name)

    {:noreply,
     socket
     |> load_reference()
     |> load_engine_config()
     |> load_greeting()
     |> assign(:ref_note, "Deleted.")}
  end

  # --- say anything ----------------------------------------------------------

  # Only the quote. The text is already in the box; this exists so the price
  # beside the button is the price of THAT line.
  @impl true
  def handle_event("clip_draft", %{"clip" => %{"text" => text}}, socket) do
    {:noreply, socket |> assign(:clip_text, text) |> assign_quote()}
  end

  def handle_event("clip_draft", _params, socket), do: {:noreply, socket}

  def handle_event("clip_make", %{"clip" => %{"text" => text}}, socket) do
    case Clips.make(text) do
      {:ok, _path} ->
        {:noreply,
         socket
         |> load_clips()
         |> assign(:clip_text, "")
         |> assign(:clip_note, "Already made — it is in the list.")}

      {:queued, key} ->
        job = %{text: String.trim(text), since: System.monotonic_time(:millisecond)}

        {:noreply,
         socket
         |> update(:clip_jobs, &Map.put(&1, key, job))
         |> assign(:clip_text, "")
         # The note is gone: the pending row below now says the same thing with a
         # clock attached, and two places describing one job disagree eventually.
         |> assign(:clip_note, nil)}

      {:error, :empty_text} ->
        {:noreply, assign(socket, :clip_note, "Type something first.")}

      {:error, :engine_unavailable} ->
        {:noreply, assign(socket, :clip_note, "No engine — install it above.")}

      {:error, :reference_missing} ->
        {:noreply,
         assign(
           socket,
           :clip_note,
           "The reference clip is gone. Record a new one, or clear it in the engine settings."
         )}

      {:error, reason} ->
        {:noreply, assign(socket, :clip_note, "Could not make it: #{inspect(reason)}")}
    end
  end

  # The bridge to Settings → Notify, and the reason that page needed no change:
  # its routing menu is `Sound.list/0`, which cannot see the render cache.
  def handle_event("clip_install", %{"path" => path}, socket) do
    note =
      case Clips.install(path) do
        {:ok, name} -> "Added #{name} to the sound library — pick it in Settings → Notify."
        {:error, reason} -> "Could not add it: #{inspect(reason)}"
      end

    {:noreply, assign(socket, :clip_note, note)}
  end

  def handle_event("clip_forget", %{"path" => path}, socket) do
    Clips.forget(path)
    {:noreply, socket |> load_clips() |> assign(:clip_note, nil)}
  end

  # --- notes to yourself ------------------------------------------------------

  def handle_event("message_create", %{"message" => %{"name" => name, "text" => text}}, socket) do
    blank = %{"name" => "", "text" => ""}

    case Messages.create(name, text) do
      {:ok, %{ready?: true}} ->
        {:noreply,
         socket
         |> assign(:message_form, blank)
         |> load_messages()
         |> assign(:message_note, "Already made — it was in the cache.")}

      {:ok, %{name: slug}} ->
        {:noreply,
         socket
         |> assign(:message_form, blank)
         |> load_messages()
         |> assign(
           :message_note,
           "Making “#{slug}”. Minutes on this machine; it will appear ready on its own."
         )}

      {:error, :engine_unavailable} ->
        {:noreply, assign(socket, :message_note, "No speech engine — install it above.")}

      {:error, :invalid_name} ->
        {:noreply, assign(socket, :message_note, "Name it with letters, digits or dashes.")}

      {:error, :empty_text} ->
        {:noreply, assign(socket, :message_note, "Type what it should say.")}

      {:error, reason} ->
        {:noreply, assign(socket, :message_note, "Could not: #{inspect(reason)}")}
    end
  end

  def handle_event("message_fire", %{"name" => name} = params, socket) do
    note =
      case Messages.fire(name, Map.take(params, ["in_seconds"])) do
        {:ok, %{kind: "reminder"}} ->
          "Fired."

        {:ok, %{kind: "timer", fire_at: at}} ->
          "Set for #{Calendar.strftime(at, "%H:%M:%S")} UTC."

        {:error, :not_ready} ->
          "Not made yet — give it a minute."

        {:error, reason} ->
          "Could not: #{inspect(reason)}"
      end

    {:noreply, assign(socket, :message_note, note)}
  end

  def handle_event("message_delete", %{"name" => name}, socket) do
    Messages.delete(name)
    {:noreply, socket |> load_messages() |> assign(:message_note, "Deleted.")}
  end

  def handle_event("greeting-save", %{"greeting" => text}, socket) do
    Greeting.put_text(text)

    note =
      if Greeting.status().stale?,
        do: "Saved — but callers still hear the old recording until you publish.",
        else: "Saved."

    {:noreply, socket |> load_greeting() |> assign(:greeting_note, note)}
  end

  # Render, then publish when it lands. Two steps rather than one because the
  # render can take minutes and publishing is the part that changes what
  # strangers hear.
  def handle_event("greeting-publish", _params, socket) do
    case Greeting.render() do
      {:ok, path} ->
        {:noreply, socket |> publish_greeting(path) |> load_greeting()}

      {:queued, key} ->
        {:noreply,
         socket
         |> assign(:greeting_job, key)
         |> assign(:greeting_since, System.monotonic_time(:millisecond))
         |> assign(:greeting_note, nil)}

      {:error, reason} ->
        {:noreply, assign(socket, :greeting_note, "Could not record it: #{inspect(reason)}")}
    end
  end

  def handle_event("greeting-unpublish", _params, socket) do
    note =
      case Greeting.unpublish() do
        :ok -> "Taken down. Callers hear the synthesized voice again."
        {:error, reason} -> "Could not take it down: #{inspect(reason)}"
      end

    {:noreply, socket |> load_greeting() |> assign(:greeting_note, note)}
  end

  # --- what the host forwards --------------------------------------------------

  # A Renderer job landed. Which of the three things it was is decided by the
  # bookkeeping maps, not by the renderer, which addresses everything by content
  # hash and knows nothing about greetings, clips or chimes.
  defp handle_notify({:voice_render, render_key, result}, socket) when is_binary(render_key) do
    cond do
      render_key == socket.assigns.greeting_job ->
        socket = socket |> assign(:greeting_job, nil) |> assign(:greeting_since, nil)

        case result do
          {:ok, path} ->
            socket |> publish_greeting(path) |> load_greeting()

          {:error, reason} ->
            assign(socket, :greeting_note, failed("Recording failed", reason))
        end

      Map.has_key?(socket.assigns.clip_jobs, render_key) ->
        {%{text: text}, jobs} = Map.pop(socket.assigns.clip_jobs, render_key)
        socket = assign(socket, :clip_jobs, jobs)

        case result do
          {:ok, path} ->
            Clips.record(text, path)
            socket |> load_clips() |> assign(:clip_note, "Made: “#{text}”")

          {:error, reason} ->
            assign(socket, :clip_note, failed("“#{text}” failed", reason))
        end

      true ->
        # Not ours by key — but a landed render may have made a spoken message
        # ready, and that is only knowable by re-listing. Cheap, and the
        # alternative is a message that stays "making…" until the next click.
        socket |> load_messages() |> then(&chime_render(render_key, result, &1))
    end
  end

  # A `Task` we started replied. `Process.demonitor/2` is correct here even though
  # this is a component: a component runs *in* its host's process, so the monitor
  # being flushed is the one `Task.async/1` installed a few lines above.
  #
  # An unrecognised ref belongs to the host, not to us. Dropping it is the whole
  # reason both refs are tracked explicitly.
  defp handle_notify({:task, ref, result}, socket) when is_reference(ref) do
    if ref == socket.assigns.chime_task do
      Process.demonitor(ref, [:flush])
      socket = socket |> assign(:chime_task, nil) |> assign(:chime_since, nil)

      case result do
        {:ok, results} -> install_set(socket, results)
        {:error, reason} -> assign(socket, :chime_note, "Failed: #{inspect(reason)}")
      end
    else
      socket
    end
  end

  defp handle_notify(_message, socket), do: socket

  defp chime_render(render_key, result, socket) do
    case Map.pop(socket.assigns.chime_jobs, render_key) do
      {nil, _jobs} ->
        # Somebody else's render. The topic is shared.
        socket

      {chime_key, jobs} ->
        note =
          case result do
            {:ok, path} ->
              Chimes.install(chime_key, path)
              "Installed #{Sound.route_label(chime_key)}."

            {:error, reason} ->
              failed("#{Sound.route_label(chime_key)} failed", reason)
          end

        socket |> assign(:chime_jobs, jobs) |> assign(:chime_note, note) |> load_chimes()
    end
  end

  # Installing is fast and local — it is a copy and a settings write — so the
  # whole set goes in at once rather than trickling.
  defp install_set(socket, results) do
    installed =
      Enum.count(results, fn {key, result} ->
        match?({:ok, _}, result) and match?({:ok, _}, Chimes.install(key, elem(result, 1)))
      end)

    failed = length(results) - installed

    note =
      if failed == 0,
        do: "All #{installed} installed. That is what your notifications say now.",
        else: "#{installed} installed, #{failed} failed — the rest are unchanged."

    socket |> assign(:chime_note, note) |> load_chimes()
  end

  defp publish_greeting(socket, path) do
    case Greeting.publish(path) do
      :ok ->
        assign(socket, :greeting_note, "Published. That is what callers hear now.")

      {:error, reason} ->
        assign(socket, :greeting_note, "Recorded, but publishing failed: #{inspect(reason)}")
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="ic-vox ic-panel flex min-h-0 flex-1 gap-0">
      <%!-- The sidebar. Nine panels in one column was "quite busy and rough on
            the eyes" (operator, 09-05) — and it was, because the surface holds
            four unrelated jobs and showed all of them at once. One list feeds the
            rail and the `select_vox_tab` guard, which is the shape both Home and
            the Workspace page arrived at the hard way. --%>
      <nav
        class="flex w-36 shrink-0 flex-col gap-0.5 border-r border-base-content/12 p-2"
        role="tablist"
        aria-label="Vox2B"
      >
        <button
          :for={{key, label} <- vox_tabs()}
          type="button"
          role="tab"
          aria-selected={@vox_tab == key}
          phx-click="select_vox_tab"
          phx-value-tab={key}
          phx-target={@myself}
          class={[
            "rounded-sm px-2.5 py-1.5 text-left font-mono text-[0.6875rem] uppercase tracking-wider transition",
            if(@vox_tab == key,
              do: "bg-primary text-primary-content",
              else: "text-base-content/55 hover:bg-base-200 hover:text-base-content"
            )
          ]}
        >
          {label}
        </button>
      </nav>

      <div class="min-h-0 flex-1 overflow-y-auto">
        <div :if={@vox_tab == "create"}>
          <Create.panel
            engine={@engine}
            mic_state={@mic_state}
            ref_note={@ref_note}
            clip_text={@clip_text}
            clip_jobs={@clip_jobs}
            clip_note={@clip_note}
            quality={@reference_quality}
            quote={@clip_quote}
            id={@id}
            target={@myself}
          />
        </div>

        <div :if={@vox_tab == "files"}>
          <Files.panel
            references={@references}
            clips={@clips}
            ref_note={@ref_note}
            clip_note={@clip_note}
            target={@myself}
          />
        </div>

        <div :if={@vox_tab == "alerts"}>
          <ChimePanel.panel
            chimes={@chimes}
            engine={@engine}
            note={@chime_note}
            since={@chime_since}
            target={@myself}
          />
          <MessagePanel.panel
            messages={@messages}
            form={@message_form}
            note={@message_note}
            id={@id}
            target={@myself}
          />
          <GreetingPanel.panel
            text={@greeting_text}
            status={@greeting_status}
            engine={@engine}
            note={@greeting_note}
            since={@greeting_since}
            id={@id}
            target={@myself}
          />
        </div>

        <div :if={@vox_tab == "engine"}>
          <EngineProbe.panel engine={@engine} target={@myself} />
          <EngineSettings.panel
            config={@engine_config}
            note={@config_note}
            made={@chimes_made}
            target={@myself}
          />
        </div>

        <div :if={@vox_tab == "reading"}>
          <Reading.panel id={@id} />
        </div>
      </div>
    </div>
    """
  end

  defp peak_hint(peak) when peak < 0.1, do: " It is quiet — closer to the mic next time."
  defp peak_hint(_peak), do: ""

  defp humanize(:reference_audio), do: "Reference clip"
  defp humanize(:inference_timesteps), do: "Steps"
  defp humanize(:cfg_value), do: "Guidance"
  defp humanize(:engine_path), do: "Engine path"
  defp humanize(field), do: field |> to_string() |> String.capitalize()
end
