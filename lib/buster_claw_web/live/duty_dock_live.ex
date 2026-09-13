defmodule BusterClawWeb.DutyDockLive do
  @moduledoc """
  The dock's on-duty control — THREE_DOORS Phase 2.

  One control in the persistent bottom bar, in the slot the music player held:
  **Go on duty** when off, **On duty · N queued** with a Stand down button when
  on, and a link to whatever is missing when the shift could not receive
  anything yet. Until 09-13 the only way on duty was a terminal command, and the
  wizard promised a Stand down button down here that did not exist.

  Sticky, like `DockLive`, for the reason written above it in the layout: the
  app layout renders once and is never part of a later diff, so a control that
  changes state has to be its own process. Subscribed to Orchestration (shift
  state), Dispatch (the count), Google and Contacts (readiness). It is
  display-and-verb only: the checks and the audit line live in `BusterClaw.Duty`
  so the Duty page cannot disagree with it.

  Stand down is one click, no confirm — stopping is the safe direction.
  """
  use BusterClawWeb, :live_view

  alias BusterClaw.{Contacts, Dispatch, Duty, Google, Orchestration}

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Orchestration.subscribe()
      Dispatch.subscribe()
      Google.subscribe()
      Contacts.subscribe()
    end

    {:ok, refresh(socket), layout: false}
  end

  @impl true
  def handle_info({:orchestration, _event}, socket), do: {:noreply, refresh(socket)}
  def handle_info({:dispatch, _event, _item}, socket), do: {:noreply, refresh(socket)}
  def handle_info(_message, socket), do: {:noreply, refresh(socket)}

  @impl true
  def handle_event("on_duty", _params, socket) do
    case Duty.go_on_duty(:dock, agent_cli_opts()) do
      {:ok, _shift} -> {:noreply, refresh(socket)}
      {:error, _reason} -> {:noreply, refresh(socket)}
    end
  end

  def handle_event("stand_down", _params, socket) do
    _ = Duty.stand_down(:dock)
    {:noreply, refresh(socket)}
  end

  defp refresh(socket) do
    case Orchestration.active_shift() do
      nil ->
        socket
        |> assign(:shift, nil)
        |> assign(:queued, 0)
        |> assign(:readiness, Duty.readiness(agent_cli_opts()))

      shift ->
        socket
        |> assign(:shift, shift)
        |> assign(:queued, Dispatch.count_open())
        |> assign(:readiness, %{ready?: true, blockers: []})
    end
  end

  # The suite runs on machines with and without `claude` on PATH. StatusLive
  # already reads `:agent_cli` from app env for the same reason; honour it here
  # so a test can pin readiness either way.
  defp agent_cli_opts do
    case Application.get_env(:buster_claw, :agent_cli) do
      nil -> []
      {_backend, _path} -> [agent_cli?: true]
      _other -> []
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div
      id="bc-duty-dock"
      data-state={dock_state(@shift, @readiness)}
      class="flex shrink-0 items-center gap-2 font-mono text-xs"
    >
      <%= cond do %>
        <% @shift -> %>
          <.link
            navigate={~p"/duty"}
            id="bc-dock-duty-link"
            class="flex items-center gap-1.5 text-primary"
            title="Open the Duty page"
          >
            <span class="size-1.5 animate-pulse rounded-full bg-primary" aria-hidden="true"></span>
            <span>On duty</span>
            <span :if={@queued > 0} class="text-base-content/60">· {@queued} queued</span>
          </.link>
          <button
            id="bc-dock-stand-down"
            type="button"
            phx-click="stand_down"
            title="Stops new work at once · a run in progress finishes"
            class="rounded-xs border border-base-content/20 px-2 py-1 text-[11px] font-medium text-base-content/70 transition hover:border-primary/50 hover:text-primary focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-primary"
          >
            Stand down
          </button>
        <% @readiness.ready? -> %>
          <button
            id="bc-dock-on-duty"
            type="button"
            phx-click="on_duty"
            title="Start an unattended shift: watch Gmail and work trusted requests"
            class="rounded-xs border border-primary/60 px-2 py-1 text-[11px] font-medium text-primary transition hover:bg-primary/10 focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-primary"
          >
            Go on duty
          </button>
        <% true -> %>
          <.link
            navigate={hd(@readiness.blockers).href}
            id="bc-dock-on-duty-blocked"
            title={"Before going on duty: " <> hd(@readiness.blockers).label}
            class="flex items-center gap-1.5 rounded-xs border border-base-content/15 px-2 py-1 text-[11px] text-base-content/50 transition hover:border-primary/50 hover:text-primary"
          >
            <span>Go on duty</span>
            <span class="text-base-content/40">· {hd(@readiness.blockers).label} first</span>
          </.link>
      <% end %>
    </div>
    """
  end

  defp dock_state(nil, %{ready?: true}), do: "off"
  defp dock_state(nil, _blocked), do: "blocked"
  defp dock_state(_shift, _readiness), do: "on"
end
