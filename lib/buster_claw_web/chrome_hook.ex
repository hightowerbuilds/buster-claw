defmodule BusterClawWeb.ChromeHook do
  @moduledoc """
  LiveView `on_mount` hook that records whether the current view is rendered
  inside a split pane (i.e. embedded via `live_render` with `embedded: true`
  in its session). `BusterClawWeb.Layouts.app/1` reads this flag and renders
  the bare content (no tab strip / dock) for embedded panes.

  The flag lives in the process dictionary: each LiveView runs in its own
  process, and render happens in that same process, so there is no cross-talk
  between the parent split view and its panes.
  """

  def on_mount(:default, _params, session, socket) do
    Process.put(:bc_embedded, session["embedded"] == true)
    {:cont, socket}
  end

  @doc "True when the current process is rendering an embedded split pane."
  def embedded?, do: Process.get(:bc_embedded, false)
end
