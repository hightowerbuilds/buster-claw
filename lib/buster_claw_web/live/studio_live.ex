defmodule BusterClawWeb.StudioLive do
  @moduledoc """
  The Studio, at `/studio` — a full-screen surface holding **Mix**.

  It held a second tab, the Voice Library, until 09-19, when the cut-up engine it
  sat on was deleted (`CUTUP_DELETION_ROADMAP`). Recording your own voice did not
  go with it: that is Vox2B, on Home, and shares nothing with what left.

  ## Why it left Home

  It was a Home sub-tab until 08-16, which cost it twice. Home renders every
  panel behind an `:if`, so the Studio's component was destroyed and rebuilt on
  every glance at Chat — and the whole reason `studio_source`, the trim, the
  clipboard and the undo stacks lived up in `StatusLive` was to survive that.
  Second, it made Home eight tabs deep for a surface most operators open
  deliberately and stay in for a while, which is the opposite of a home screen.

  On its own route it is a page you go to, its state lives where it is used, and
  Home is one tab lighter.

  ## The rail is flat, on purpose

  One level. It was three tabs until 09-05 (the Sketch Pad), two until 09-19
  (the Voice Library), and with one tab left `StudioPanel` draws no rail at all.
  The registry and the whitelist stay, so a second tab is still one edit — and
  the rule the rail was built on stands for whoever adds it: **a rail that makes
  you leave a tab to finish a loop is a rail in the way.**

  ## What this owns, and what it deliberately does not

  Every assign the Studio needs is here rather than in a component, and the
  reason has outlived the one usually given for it. `SoundStudioComponent` was
  FROZEN and could not grow to hold its own state; that ended 08-16. **The
  durable reason is `StudioPanel`'s `:if`** — switching sub-tabs removes the
  component from the DOM and discards it, so a selection, a trim or an undo
  stack held inside it would not survive a look at another tab.
  `Studio.MixState` remains the socket-in / socket-out module that does the
  work. It moved surface, not shape — every clause below still delegates one
  line deep, exactly as it did in `StatusLive`.
  """
  use BusterClawWeb, :live_view

  import BusterClawWeb.Studio.MixState

  alias BusterClaw.Notifications.StudioMix

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Studio")
     |> assign_studio_tab()
     # Which source the Studio has open, the in-progress trim, the arranger's
     # selection/clipboard/undo — all still assigns of the LiveView rather than
     # the component, because `StudioPanel` renders it behind an `:if` and a
     # sub-tab switch discards it along with anything it held.
     |> assign(:studio_source, nil)
     |> assign(:studio_trim, nil)
     |> assign(:studio_clip, nil)
     |> assign(:studio_preview, nil)
     |> assign(:studio_clipboard, nil)
     |> assign(:studio_undo, [])
     |> assign(:studio_redo, [])}
  end

  @impl true
  # The Studio's sub-tab rail. Whitelisted through
  # `StudioPanel.tab_keys/0` inside `Studio.MixState.select_studio_tab/2`.
  def handle_event("select_studio_tab", %{"tab" => tab}, socket) do
    {:noreply, select_studio_tab(socket, tab)}
  end

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
        #
        # `offset_ms` joined the same day and for the same reason: a hand-built
        # spec is a list of the fields somebody remembered. Without it, copying
        # a TRIMMED clip pasted the whole source back — the identical silent
        # loss, one field along. Read through `window/1` so a clip predating the
        # field still answers.
        {offset_ms, duration_ms} = StudioMix.window(clip)

        {:noreply,
         assign(socket, :studio_clipboard, %{
           source: clip.source,
           offset_ms: offset_ms,
           duration_ms: duration_ms,
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

  # The selected clip's effect chain. Each is one line into `Studio.MixState`,
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

  @impl true
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

  # Anything else on the subscribed topics is not this surface's business.
  def handle_info(_message, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} socket={@socket}>
      <div class="flex min-h-0 flex-1 flex-col gap-2">
        <%!-- One line of chrome, not three. The eyebrow said "Studio" over a
              heading that said something else, and the right side was an action
              slot the menu bar emptied on 08-16 — so the name moved into the
              heading and the rest went. Everything below this is the surface. --%>
        <h1 class="font-display text-2xl font-black uppercase tracking-tight">Studio</h1>

        <BusterClawWeb.StudioPanel.studio_panel
          tab={@studio_tab}
          studio_source={@studio_source}
          studio_trim={@studio_trim}
          studio_clip={@studio_clip}
          studio_clip_data={selected_clip(assigns)}
          studio_preview={@studio_preview}
          studio_clipboard={@studio_clipboard}
          studio_undo={@studio_undo}
          studio_redo={@studio_redo}
        />
      </div>
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
