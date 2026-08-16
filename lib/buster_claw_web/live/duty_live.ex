defmodule BusterClawWeb.DutyLive do
  @moduledoc """
  The visible brake: whether an unattended shift is running, and the one control
  that stops it. Gate `G-30`.

  Mounted `sticky: true` in the dock footer (`Layouts.app`) beside `DockNavLive`,
  `MusicPlayerLive` and `DockLive`, and sticky for the reason they are: a Phoenix
  app layout renders once at mount and is never part of a later diff, so a shift
  that started on another page would sit unshown here until the next navigation.
  A nested LiveView has its own process and its own diff.

  ## Why this exists at all

  Until 08-16 the emergency brake was a `STOP` file on disk, and the only way to
  reach it was `./buster-claw off-duty` — a command the app told you about in
  prose, on two screens, in a product whose second step promises "no terminal
  knowledge needed". `IX.3`, the release plan's own first-run test, lists *"stop
  the agent immediately"* among the two tasks it says matter most. It was
  unpassable inside the app.

  ## It renders nothing when nothing is running

  Deliberate. A permanently-present brake showing "idle" trains the eye to skip
  the exact spot the real one appears, and the dock is already the busiest strip
  in the window. Absence here means absence out there.

  ## What the button does, and what it honestly cannot

  `Orchestration.stand_down/1` latches the kill switch *then* stops the shift —
  see its docs for why that order is load-bearing. What it cannot do is cancel a
  run already in flight: the Dispatcher monitors runs, it does not kill them.
  **The template says so next to the button**, because a brake that overstates
  its reach is worse than one that names its limit.

  ## No confirmation, on purpose

  The house idiom for a destructive control is `data-claw-confirm`, and this
  opts out. An emergency brake that asks "are you sure" adds friction at the one
  moment friction is most expensive. The cost of a mis-click is bounded — going
  back on duty clears the latch — and the cost of hesitating in front of a modal
  while an agent does something alarming is not.

  ## Not to be merged with the chat's Stop

  `ChatPanel` has `cut_run`, which stops a running *chat turn*. That is the
  attended path and was never the gap. These two stop different machines and
  live on different surfaces; unifying them would give one button two meanings.
  """
  use BusterClawWeb, :live_view

  require Logger

  alias BusterClaw.Orchestration
  alias BusterClaw.Sentinel

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Orchestration.subscribe()

    {:ok, load_shift(socket), layout: false}
  end

  # Every orchestration event reloads, rather than each one patching an assign.
  # The read is one indexed row and this process is idle otherwise, so the
  # cheaper-looking version would only buy a way for the dock to disagree with
  # the database about whether an agent is running — which is the single thing
  # this surface may never do.
  @impl true
  def handle_info({:orchestration, _event}, socket), do: {:noreply, load_shift(socket)}

  def handle_info(_message, socket), do: {:noreply, socket}

  @impl true
  def handle_event("stand_down", _params, socket) do
    case Orchestration.stand_down("stood down from the dock") do
      {:ok, %{id: id}} ->
        Sentinel.observe(:security_block, "Shift stopped by the operator (dock brake)", %{
          shift_id: id
        })

        {:noreply,
         socket |> load_shift() |> put_flash(:info, "Stood down. No new work will start.")}

      {:ok, :latched} ->
        # The shift ended between render and click. The latch still went down, so
        # this is a real effect and not a no-op — say so rather than claiming a
        # stop that did not happen.
        {:noreply,
         socket
         |> load_shift()
         |> put_flash(:info, "Already finished. The brake is set until you go back on duty.")}

      {:error, reason} ->
        Logger.error("Stand down failed: #{inspect(reason)}")

        {:noreply, put_flash(socket, :error, "Could not stand down. Run ./buster-claw off-duty.")}
    end
  end

  defp load_shift(socket), do: assign(socket, :shift, Orchestration.active_shift())

  @impl true
  def render(assigns) do
    ~H"""
    <div id="bc-duty" class="flex shrink-0 items-center">
      <div
        :if={@shift}
        class="flex items-center gap-2 rounded-xs border-2 border-primary bg-primary/10 px-2 py-1"
      >
        <span class="size-2 shrink-0 animate-pulse rounded-full bg-primary" aria-hidden="true"></span>
        <div class="flex flex-col leading-tight">
          <span class="font-mono text-[0.62rem] uppercase tracking-wider text-primary">
            {status_label(@shift)}
          </span>
          <%!-- The limit, in the sentence rather than in a tooltip. `stand_down`
                closes the door on new work immediately; a run already in flight
                is monitored, not killed. --%>
          <span class="text-[0.62rem] text-base-content/60">
            Stops new work at once · a run in progress finishes
          </span>
        </div>
        <button
          type="button"
          id="bc-duty-stand-down"
          phx-click="stand_down"
          title="Stop unattended work now"
          class="ml-1 rounded-xs border-2 border-primary bg-primary px-2.5 py-1 font-mono text-[0.66rem] font-bold uppercase tracking-wider text-primary-content transition hover:bg-primary/80"
        >
          Stand down
        </button>
      </div>
    </div>
    """
  end

  # An unattended shift is the one the Dispatcher drives with headless runs; an
  # attended one is a human at a terminal working the same queue. Both are
  # stoppable here and the label distinguishes them, because "working on its own"
  # is a claim only the first one earns.
  defp status_label(%{unattended: true}), do: "On duty · working on its own"
  defp status_label(_shift), do: "On duty"
end
