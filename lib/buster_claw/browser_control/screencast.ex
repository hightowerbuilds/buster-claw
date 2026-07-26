defmodule BusterClaw.BrowserControl.Screencast do
  @moduledoc """
  The mirror's capture half (BROWSER_ENGINE_ROADMAP Phase 7).

  Agent Mode runs headful in the user's own Chromium, which is correct — real
  popups, real profile, a human who can take the wheel — but it means watching
  the agent meant alt-tabbing to another application. The 07-25 field test's own
  conclusion was that the single most effective safety property in the run was
  that a human could see it; that supervision was *available* but not
  *practical*.

  This process makes it practical. `Page.startScreencast` has the engine push
  JPEG frames of the page viewport as `Page.screencastFrame` events, over the
  pipe we already own, through the `CDP` client that already fans events out.
  The mirror is just another subscriber. Nothing new is trusted and no new
  transport exists.

  ## What this is not

  It is **not** the Chromium window embedded in ours. macOS has no supported
  cross-process view reparenting, and the approaches that get close produce a
  window floating *above* ours that will not clip, loses z-order on a click, and
  does not follow Spaces. Ruled out on the merits; see the roadmap's Deferred.

  So this is a mirror, with a mirror's honest limits: it shows the page viewport
  only. No tab bar, no basic-auth dialog, no file picker, no permission prompt,
  no native `<select>` popup — those are OS widgets outside the compositor. The
  real window is always one click away and that is part of the design, not an
  apology for it.

  ## Lifecycle

  Frames cost CPU in the engine, so capture is **on demand**: `watch/2`
  starts-or-reuses a caster for a session and monitors the caller, and the
  caster stops once the last watcher goes away (`@linger_ms` grace, so a page
  refresh does not tear down and restart the engine's encoder). Nobody watching
  means no screencast running.

  ## Backpressure

  Chromium will not send the next frame until the current one is acked
  (`Page.screencastFrameAck`), which makes the protocol self-throttling — an ack
  per frame is not optional bookkeeping, it *is* the flow control. We ack on
  receipt and keep only the newest frame: a slow viewer falls behind by dropping
  frames, never by growing a queue.
  """
  # `:temporary` is load-bearing, not a default worth skipping. A caster stops
  # normally whenever the last watcher leaves — under the default `:permanent`
  # the supervisor reads that as a failure and restarts it, which immediately
  # stops again for the same reason. The loop trips max_restarts, takes the
  # DynamicSupervisor down, and cascades into the application supervisor: the
  # entire app dies because somebody closed a browser tab. Same reason `Session`
  # is temporary.
  use GenServer, restart: :temporary

  require Logger

  alias BusterClaw.BrowserControl.Session
  alias Phoenix.PubSub

  @registry BusterClaw.BrowserControl.ScreencastRegistry
  @supervisor BusterClaw.BrowserControl.ScreencastSupervisor
  @topic_prefix "browser_screencast:"

  # Viewport-sized, not retina: the mirror is for watching, not for reading fine
  # print, and every pixel is JPEG-encoded by the engine then pushed over a pipe.
  @default_max_width 1280
  @default_max_height 900
  @default_quality 60
  @linger_ms 5_000

  # ── Public API ──────────────────────────────────────────────────────────────

  @doc "PubSub topic carrying `{:screencast_frame, run_id, jpeg_base64}`."
  def topic(run_id), do: @topic_prefix <> to_string(run_id)

  @doc "Subscribe the caller to a run's frames."
  def subscribe(run_id), do: PubSub.subscribe(BusterClaw.PubSub, topic(run_id))

  @doc """
  Start (or join) the caster for `run_id` against `session`, and register the
  calling process as a watcher. The caster stops shortly after the last watcher
  exits. Returns `{:ok, pid}` or `{:error, reason}`.
  """
  def watch(run_id, session, opts \\ []) do
    case start_caster(run_id, session, opts) do
      {:ok, pid} -> add_watcher(pid)
      {:error, {:already_started, pid}} -> add_watcher(pid)
      other -> other
    end
  end

  @doc "The most recent frame as base64 JPEG, or nil if none has arrived yet."
  def latest(run_id) do
    case whereis(run_id) do
      nil -> nil
      pid -> GenServer.call(pid, :latest)
    end
  catch
    :exit, _ -> nil
  end

  @doc "The caster pid for a run, or nil."
  def whereis(run_id) do
    case Registry.lookup(@registry, to_string(run_id)) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  @doc "Stop a run's caster (idempotent)."
  def stop(run_id) do
    case whereis(run_id) do
      nil -> :ok
      pid -> GenServer.stop(pid, :normal, 2_000)
    end
  catch
    :exit, _ -> :ok
  end

  @doc false
  def start_link(opts) do
    run_id = Keyword.fetch!(opts, :run_id)
    GenServer.start_link(__MODULE__, opts, name: via(run_id))
  end

  defp via(run_id), do: {:via, Registry, {@registry, to_string(run_id)}}

  defp start_caster(run_id, session, opts) do
    DynamicSupervisor.start_child(
      @supervisor,
      {__MODULE__, Keyword.merge(opts, run_id: run_id, session: session)}
    )
  catch
    # The supervisor is missing — in practice a long-running dev node started
    # before the mirror's children were added to the tree, since code reload
    # recompiles modules but never adds supervision children. A viewer should
    # get a legible message, not an unhandled exit rendered as a 500.
    :exit, _ -> {:error, :screencast_unavailable}
  end

  defp add_watcher(pid) do
    GenServer.call(pid, :watch)
    {:ok, pid}
  catch
    :exit, _ -> {:error, :screencast_gone}
  end

  # ── GenServer ───────────────────────────────────────────────────────────────

  @impl true
  def init(opts) do
    session = Keyword.fetch!(opts, :session)
    session_mod = Keyword.get(opts, :session_mod, Session)

    case session_mod.handles(session) do
      {:ok, cdp, cdp_session_id} ->
        {:ok,
         %{
           run_id: Keyword.fetch!(opts, :run_id),
           cdp: cdp,
           cdp_session_id: cdp_session_id,
           cdp_mod: Keyword.get(opts, :cdp_mod, BusterClaw.BrowserControl.CDP),
           quality: Keyword.get(opts, :quality, @default_quality),
           max_width: Keyword.get(opts, :max_width, @default_max_width),
           max_height: Keyword.get(opts, :max_height, @default_max_height),
           linger_ms: Keyword.get(opts, :linger_ms, @linger_ms),
           frame: nil,
           frames: 0,
           watchers: %{},
           stop_timer: nil
         }, {:continue, :start_cast}}

      other ->
        {:stop, {:no_session_handles, other}}
    end
  end

  @impl true
  def handle_continue(:start_cast, state) do
    # Only the frame event: this subscription is precisely the one that would
    # flood every other subscriber if CDP had no filter.
    state.cdp_mod.subscribe(state.cdp, methods: ["Page.screencastFrame"])

    cmd(state, "Page.enable", %{})

    cmd(state, "Page.startScreencast", %{
      "format" => "jpeg",
      "quality" => state.quality,
      "maxWidth" => state.max_width,
      "maxHeight" => state.max_height,
      "everyNthFrame" => 1
    })

    {:noreply, seed_frame(state)}
  end

  # A screencast only emits on *new* compositor frames, so a page that has
  # finished painting produces nothing at all — which is the common case, since
  # the agent usually pauses on a settled page. Without a seed the panel opens
  # black and stays black until something happens to move, which reads as "the
  # mirror is broken" rather than "the page is still".
  #
  # One screenshot at startup fixes it: `Page.captureScreenshot` renders on
  # demand instead of waiting for the compositor. Live frames take over from
  # there.
  defp seed_frame(state) do
    case cmd(state, "Page.captureScreenshot", %{
           "format" => "jpeg",
           "quality" => state.quality
         }) do
      {:ok, %{"data" => data}} when is_binary(data) ->
        publish(state, data)

      _unavailable ->
        state
    end
  end

  defp publish(state, data) do
    PubSub.broadcast(
      BusterClaw.PubSub,
      topic(state.run_id),
      {:screencast_frame, state.run_id, data}
    )

    %{state | frame: data, frames: state.frames + 1}
  end

  @impl true
  def handle_call(:latest, _from, state), do: {:reply, state.frame, state}

  def handle_call(:watch, {pid, _tag}, state) do
    ref = Process.monitor(pid)
    {:reply, :ok, cancel_stop(%{state | watchers: Map.put(state.watchers, ref, pid)})}
  end

  def handle_call(:stats, _from, state) do
    {:reply, %{frames: state.frames, watchers: map_size(state.watchers), run_id: state.run_id},
     state}
  end

  @impl true
  def handle_info({:browser_control_event, "Page.screencastFrame", params, _sid}, state) do
    # Ack FIRST. The engine gates the next frame on this, so a slow or failed
    # ack does not "lose a frame", it stops the stream entirely.
    if ack_id = params["sessionId"] do
      cmd(state, "Page.screencastFrameAck", %{"sessionId" => ack_id})
    end

    data = params["data"]

    if is_binary(data), do: {:noreply, publish(state, data)}, else: {:noreply, state}
  end

  def handle_info({:browser_control_exit, _status}, state), do: {:stop, :normal, state}

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    watchers = Map.delete(state.watchers, ref)
    state = %{state | watchers: watchers}

    if map_size(watchers) == 0 do
      # Linger rather than stop dead: a page reload drops and re-adds a watcher
      # within milliseconds, and restarting the engine's encoder each time is
      # both slow and visible as a stutter.
      {:noreply, %{state | stop_timer: Process.send_after(self(), :no_watchers, state.linger_ms)}}
    else
      {:noreply, state}
    end
  end

  def handle_info(:no_watchers, state) do
    if map_size(state.watchers) == 0 do
      {:stop, :normal, state}
    else
      {:noreply, %{state | stop_timer: nil}}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    # Best-effort: a dead engine makes this a no-op, which is fine — the point
    # is not to leave a live engine encoding frames nobody reads.
    cmd(state, "Page.stopScreencast", %{})
    :ok
  end

  # ── internals ───────────────────────────────────────────────────────────────

  defp cmd(state, method, params) do
    state.cdp_mod.command(state.cdp, method, params, session_id: state.cdp_session_id)
  catch
    :exit, _ -> {:error, :browser_exited}
  end

  defp cancel_stop(%{stop_timer: nil} = state), do: state

  defp cancel_stop(%{stop_timer: ref} = state) do
    Process.cancel_timer(ref)
    %{state | stop_timer: nil}
  end
end
