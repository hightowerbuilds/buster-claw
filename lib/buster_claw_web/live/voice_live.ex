defmodule BusterClawWeb.VoiceLive do
  @moduledoc """
  The standalone `/voice` page — a deep-link door onto Vox2B, and a `SplitLive`
  pane.

  The surface itself lives in `BusterClawWeb.VoxComponent`; this LiveView is the
  page chrome around it, plus the one subscription and the one mailbox a
  `LiveComponent` cannot hold on its own. The homepage embeds the same component
  under its **Vox** sub-tab, so both surfaces render identical behavior from one
  source (`VOX_TAB_ROADMAP` `D2`).

  The route stays even though the homepage is now the fuller home for it, exactly
  as `/phone` and `/calendar` did when they became Home sub-tabs: `SplitLive` can
  open it in a pane, deep links land somewhere, and deleting a route out from
  under its own suite is an afternoon of guessing which failures were meant.

  **It is no longer a Settings page** (operator, 09-05). Voice was removed from
  `SettingsTabs` and from the tab strip's Settings group, so this renders no
  settings rail — showing one on a page the rail does not list would highlight
  nothing and claim membership of a section this route left.
  """
  use BusterClawWeb, :live_view

  alias BusterClaw.Voice.Renderer
  alias BusterClawWeb.VoxComponent

  @component_id "voice"

  @impl true
  def mount(_params, _session, socket) do
    # The host half of the component contract. A component shares this process,
    # so it must not subscribe for itself — it would double every broadcast on a
    # host that already listens.
    if connected?(socket), do: Renderer.subscribe()

    # Assigned, not read from the attribute in the template: `@component_id`
    # inside HEEx means an assign, and a module attribute of the same name
    # silently is not one.
    {:ok, socket |> assign(:page_title, "Voice") |> assign(:component_id, @component_id)}
  end

  # Relay only. Nothing is interpreted here — which renders matter, and which
  # task refs are the component's own, is the component's business.
  @impl true
  def handle_info({:voice_render, _key, _result} = message, socket) do
    VoxComponent.notify(@component_id, message)
    {:noreply, socket}
  end

  # `Task.async/1` inside the component monitors from THIS process, so its reply
  # and its `:DOWN` land here. The reply is forwarded; the `:DOWN` is swallowed
  # by the clause below, because the component flushes the monitor itself.
  def handle_info({ref, result}, socket) when is_reference(ref) do
    VoxComponent.notify(@component_id, {:task, ref, result})
    {:noreply, socket}
  end

  def handle_info({:DOWN, _ref, :process, _pid, _reason}, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} socket={@socket}>
      <section class="space-y-6">
        <.live_component module={VoxComponent} id={@component_id} />
      </section>
    </Layouts.app>
    """
  end
end
