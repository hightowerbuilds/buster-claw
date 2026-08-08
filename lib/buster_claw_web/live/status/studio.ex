defmodule BusterClawWeb.Status.Studio do
  @moduledoc """
  The Sound Studio's arranger state, as socket-in / socket-out functions.

  Every one of these assigns lives in `StatusLive` rather than in
  `SoundStudioComponent`, and that is deliberate: home panels render behind
  `:if`, so the component — and any state it held — is discarded on every tab
  switch. An undo stack that empties when you glance at Chat does not read as a
  tab switch; it reads as the feature being broken.

  So the component renders, and the ownership of what must outlive a glance —
  the open source, the in-progress trim, the selected clip, the clipboard, and
  the undo/redo stacks — lives here.

  `mutate_open_mix/2` is the single path every keyboard-driven arrangement
  change goes through: load, apply, save, record the previous state for undo,
  and tell the component to re-read.
  """
  import Phoenix.Component
  import Phoenix.LiveView

  alias BusterClaw.Notifications.StudioMix

  # ---------------------------------------------------------------------------
  # Arranger history
  # ---------------------------------------------------------------------------

  # Deep enough for a working session, bounded because these are whole
  # arrangements and this LiveView is long-lived.
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

  def selected_clip(socket) do
    with id when is_binary(id) <- socket.assigns.studio_clip,
         {:ok, mix} <- open_mix(socket) do
      mix |> StudioMix.clips() |> Enum.find_value(fn {_t, c} -> if c.id == id, do: c end)
    else
      _ -> nil
    end
  end
end
