defmodule BusterClawWeb.CalendarLive do
  @moduledoc """
  The standalone `/calendar` page (also opened in a split pane by `SplitLive`).

  The calendar itself lives in `BusterClawWeb.CalendarComponent`; this LiveView is
  just the page chrome around it. The homepage embeds the same component under its
  "Calendar" sub-tab, so both surfaces render identical calendar behavior from one
  source.
  """
  use BusterClawWeb, :live_view

  alias BusterClaw.LocalTime

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Calendar")
     |> assign(:today, LocalTime.today())}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} wide>
      <.live_component module={BusterClawWeb.CalendarComponent} id="calendar" today={@today} />
    </Layouts.app>
    """
  end
end
