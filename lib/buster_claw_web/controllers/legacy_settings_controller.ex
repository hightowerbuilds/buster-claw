defmodule BusterClawWeb.LegacySettingsController do
  @moduledoc """
  Recovery for saved links to retired Settings pages: the command-list editor
  (`/cmd-list`) and Integrations (`/integrations`, deleted 10-17). The tab
  strip remembers the last Settings subpage it showed and reopens it at boot,
  so a deleted page is a crash page for anyone who had it open — this lands
  them on Appearance instead.
  """
  use BusterClawWeb, :controller

  def index(conn, _params), do: redirect(conn, to: ~p"/appearance")
end
