defmodule BusterClawWeb.PhoneLive do
  @moduledoc """
  The standalone `/phone` page (also opened in a split pane by `SplitLive`).

  The Message Machine itself lives in `BusterClawWeb.PhoneComponent`; this
  LiveView is the page chrome around it, plus the two subscriptions the component
  cannot hold — a `LiveComponent` has no process of its own. The homepage embeds
  the same component under its "Phone" sub-tab, so both surfaces render identical
  behavior from one source.

  Phone left the dock on 08-08 (operator): a normal user has no provisioned
  number, so a top-level destination for it overstated what the app can do. The
  route stays for deep links and split panes, exactly as `/calendar` did when it
  became a Home sub-tab.
  """
  use BusterClawWeb, :live_view

  alias BusterClaw.Contacts
  alias BusterClaw.Telephony
  alias BusterClawWeb.PhoneComponent

  @component_id "phone"

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Telephony.subscribe()
      Contacts.subscribe()
    end

    # Assigned, not read from the attribute in the template: `@component_id`
    # inside HEEx means an assign, and a module attribute of the same name
    # silently is not one.
    {:ok, socket |> assign(:page_title, "Phone") |> assign(:component_id, @component_id)}
  end

  # The host half of `PhoneComponent`'s contract: subscribe, then relay. Nothing
  # is interpreted here — which broadcasts matter is the component's business.
  @impl true
  def handle_info({PhoneComponent, :reload, id}, socket) do
    PhoneComponent.notify(id, :reload)
    {:noreply, socket}
  end

  def handle_info(message, socket) do
    PhoneComponent.notify(@component_id, message)
    {:noreply, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} socket={@socket} fit_viewport>
      <.live_component module={PhoneComponent} id={@component_id} />
    </Layouts.app>
    """
  end
end
