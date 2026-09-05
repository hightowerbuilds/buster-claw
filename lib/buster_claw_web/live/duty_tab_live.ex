defmodule BusterClawWeb.DutyTabLive do
  @moduledoc "Keeps the conditional duty tab in sync across page navigation."
  use BusterClawWeb, :live_view

  alias BusterClaw.Orchestration

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Orchestration.subscribe()
    {:ok, refresh(socket), layout: false}
  end

  @impl true
  def handle_info({:orchestration, _event}, socket), do: {:noreply, refresh(socket)}
  def handle_info(_message, socket), do: {:noreply, socket}

  defp refresh(socket), do: assign(socket, :active, Orchestration.shift_active?())

  @impl true
  def render(assigns) do
    ~H"""
    <div id="duty-tab-state" phx-hook="DutyTab" data-active={to_string(@active)} hidden></div>
    """
  end
end
