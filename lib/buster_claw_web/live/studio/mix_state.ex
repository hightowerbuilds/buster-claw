defmodule BusterClawWeb.Studio.MixState do
  @moduledoc """
  The Sound Studio's arranger state, as socket-in / socket-out functions.

  Every one of these assigns lives in the **LiveView** rather than in
  `SoundStudioComponent`, and that is deliberate: sub-tabs render behind `:if`,
  so the component — and any state it held — is discarded on every tab switch.
  An undo stack that empties when you look at the Voice Library does not read as
  a tab switch; it reads as the feature being broken.

  So the component renders, and the ownership of what must outlive a switch —
  the open source, the in-progress trim, the selected clip, the clipboard, and
  the undo/redo stacks — lives here.

  ## Why this is `Studio.MixState` when its LiveView is `StudioLive`

  It was `StatusLive`'s: the Studio was a Home sub-tab until 08-16, when it
  became its own route and took every assign with it. `StatusLive` now holds
  none of them.

  **The name is a leftover, and it is left deliberately rather than swept.** A
  rename here is nine references across three sibling modules and their tests —
  mechanical, but a sweep, and this repo has paid for a rename that looked
  mechanical and severed a contract the suite could not see. It deserves its own
  commit and its own verification, not a paragraph's worth of collateral in a
  drift fix. Until then this line is the answer to "why is Studio state under
  `status/`?" — because it used to be, and moving the file is a separate change
  from moving the feature.

  `mutate_open_mix/2` is the single path every keyboard-driven arrangement
  change goes through: load, apply, save, record the previous state for undo,
  and tell the component to re-read.

  The Studio's own sub-tab (`Mix` | `Voice Library` | `Sketch Pad`) is assigned
  here too, and for the same reason as everything above — plus a second one: the
  LiveView keeps only the mount assign, one `handle_event` clause and one
  condition, so the wiring a sub-tab needs lands in this module.
  """
  import Phoenix.Component
  import Phoenix.LiveView

  alias BusterClaw.Notifications.Studio.Render
  alias BusterClaw.Notifications.StudioMix
  alias BusterClawWeb.SoundStudio.Catalog
  alias BusterClawWeb.Studio.Preview
  alias BusterClawWeb.Studio.RecorderState, as: Recorder
  alias BusterClawWeb.Studio.VoiceState, as: Voice
  alias BusterClawWeb.StudioPanel

  # ---------------------------------------------------------------------------
  # The sub-tab rail
  # ---------------------------------------------------------------------------

  @doc """
  Default the Studio's sub-tab at mount. `Mix` leads because it is the studio
  that exists; `Voice` is a placeholder until Parts V and VI land.
  """
  def assign_studio_tab(socket), do: assign(socket, :studio_tab, "mix")

  @doc """
  Switch sub-tabs, refusing a key the rail never offered.

  The whitelist is `StudioPanel.tab_keys/0`, which reads the same registry the
  rail and the panel dispatch read — so a real key can never be missing from one
  of the three, and a forged one is a no-op rather than a crash. Same posture as
  the Explained rail's handler.
  """
  def select_studio_tab(socket, tab) do
    if tab in StudioPanel.tab_keys() do
      socket |> assign(:studio_tab, tab) |> arriving_at(tab)
    else
      socket
    end
  end

  # Voice reads the corpus from disk, so it loads when the tab is opened rather
  # than at mount — a homepage that never visits Voice should not pay for ten
  # file reads. `ensure_report/1` is idempotent, so switching away and back is
  # free. Dispatching on the key here rather than in `StatusLive` keeps the
  # LiveView's clause one line, which is the point of this module.
  # The Voice Library needs both halves: the corpus for its word list, and the
  # device list for its recorder. Both are lazy and idempotent.
  defp arriving_at(socket, "voice"),
    do: socket |> Voice.ensure_report() |> Recorder.ensure_loaded()

  defp arriving_at(socket, _tab), do: socket

  # ---------------------------------------------------------------------------
  # Arranger history
  # ---------------------------------------------------------------------------

  # Deep enough for a working session, bounded because these are whole
  # arrangements and this LiveView is long-lived.
  # One name, overwritten. A clip preview is scratch — not a take, not a render,
  # and forty numbered files in `studio/` would turn the source list into a junk
  # drawer within an afternoon.
  @preview_name "clip-preview.wav"

  @studio_history_limit 50

  def reset_studio_history(socket) do
    socket
    |> assign(:studio_clip, nil)
    |> assign(:studio_undo, [])
    |> assign(:studio_redo, [])
  end

  def push_studio_history(socket, %StudioMix{} = previous) do
    socket
    |> assign(
      :studio_undo,
      Enum.take([previous | socket.assigns.studio_undo], @studio_history_limit)
    )
    # A new edit after undoing abandons the redo branch — the standard contract,
    # and the alternative (keeping it) lets redo overwrite work done since.
    |> assign(:studio_redo, [])
  end

  # Undo and redo are the same move in opposite directions: pop the source
  # stack, put the CURRENT state on the other one, write the popped state back.
  def step_history(socket, from_key, to_key) do
    with [previous | rest] <- socket.assigns[from_key],
         {:ok, current} <- open_mix(socket) do
      StudioMix.save(previous)
      send_update(BusterClawWeb.SoundStudioComponent, id: "home-studio")

      socket
      |> assign(from_key, rest)
      |> assign(to_key, Enum.take([current | socket.assigns[to_key]], @studio_history_limit))
      # The selected clip may not exist in the state just restored.
      |> assign(:studio_clip, nil)
    else
      _ -> socket
    end
  end

  def open_mix(socket) do
    case socket.assigns.studio_source do
      "mix:" <> name -> StudioMix.load(name)
      _ -> {:error, :no_mix}
    end
  end

  # Load, apply, save, and record the previous state for undo — the one path
  # every keyboard-driven arrangement change goes through.
  def mutate_open_mix(socket, fun) do
    case open_mix(socket) do
      {:ok, mix} ->
        updated = fun.(mix)

        if updated == mix do
          socket
        else
          StudioMix.save(updated)
          send_update(BusterClawWeb.SoundStudioComponent, id: "home-studio")
          push_studio_history(socket, mix)
        end

      {:error, _reason} ->
        socket
    end
  end

  # ---------------------------------------------------------------------------
  # The selected clip: effects, and hearing them
  # ---------------------------------------------------------------------------

  @doc """
  Apply a change to the selected clip's effect chain.

  Every one of these goes through `mutate_open_mix/2`, which is what gives them
  ⌘Z. That is the reason the inspector's buttons carry no `phx-target` and reach
  the LiveView instead of the component: an effect that could not be undone would
  have been the first arrangement change in the Studio that could not.
  """
  def effect_change(socket, fun) do
    case socket.assigns.studio_clip do
      nil -> socket
      clip_id -> socket |> mutate_open_mix(&fun.(&1, clip_id)) |> expire_preview()
    end
  end

  @doc """
  Render the selected clip through its chain and make it playable.

  The same `Studio.Render` the mixdown uses, so a preview cannot disagree with
  the render about what an effect does — which is the whole reason effects are
  not approximated in WebAudio. Written under one fixed name and versioned, for
  the reason the Voice Library's sentence preview is: the browser caches by URL
  and would otherwise replay the previous chain.
  """
  # One clip, so ONE catalog read — `resolve_source/1` is the right call here and
  # the wrong one inside a walk. `render_mix/1` learned that difference the
  # expensive way; see its comment.
  #
  # It reaches `SoundStudio.Catalog` directly rather than through the frozen
  # component, which owned the catalogue until 08-16 and no longer does.
  def preview_clip(socket) do
    with clip when is_map(clip) <- selected_clip(socket),
         {:ok, audio} <- Render.preview(clip, &Catalog.resolve_source/1),
         {:ok, preview} <- Preview.write(audio, @preview_name, socket.assigns[:studio_preview]) do
      assign(socket, :studio_preview, preview)
    else
      _other -> assign(socket, :studio_preview, nil)
    end
  end

  # A rendered preview describes the chain it was rendered from. Changing the
  # chain must retire it, or "Hear it" plays the version before the edit — real
  # audio of a real chain, which is the convincing way to be wrong.
  defp expire_preview(socket), do: assign(socket, :studio_preview, nil)

  @doc """
  The selected clip's map, from a socket OR from bare assigns.

  Both, because the arranger's handlers hold a socket and the template holds
  `assigns` — and the inspector needs the clip itself, not its id. One function
  with two entry shapes beats the same traversal written twice.
  """
  def selected_clip(%{assigns: _} = socket), do: find_selected(socket)
  def selected_clip(assigns) when is_map(assigns), do: find_selected(%{assigns: assigns})
  def selected_clip(_other), do: nil

  defp find_selected(socket) do
    with id when is_binary(id) <- socket.assigns.studio_clip,
         {:ok, mix} <- open_mix(socket) do
      mix |> StudioMix.clips() |> Enum.find_value(fn {_t, c} -> if c.id == id, do: c end)
    else
      _ -> nil
    end
  end
end
