defmodule BusterClawWeb.PaneRoutes do
  @moduledoc "Views that can be mounted inside a joined tab, shared with the tab strip."
  @panes %{
    "/" => {BusterClawWeb.StatusLive, "Home"},
    "/browse" => {BusterClawWeb.BrowseLive, "Browser"},
    "/calendar" => {BusterClawWeb.CalendarLive, "Calendar"},
    "/terminal" => {BusterClawWeb.TerminalLive, "Terminal"},
    "/workspace" => {BusterClawWeb.WorkspaceLive, "Workspace"},
    "/security" => {BusterClawWeb.SecurityLive, "Security"},
    "/settings" => {BusterClawWeb.SettingsLive, "Settings"},
    "/appearance" => {BusterClawWeb.AppearanceLive, "Appearance"},
    "/manual" => {BusterClawWeb.UserGuideLive, "Manual"}
  }
  def paths, do: Map.keys(@panes)
  def fetch(path), do: Map.fetch(@panes, path)

  def browser_surface(params, fallback) do
    case params["surface"] do
      sid when is_binary(sid) ->
        if Regex.match?(~r/\A[A-Za-z0-9]{1,64}\z/, sid), do: sid, else: fallback

      _ ->
        fallback
    end
  end
end
