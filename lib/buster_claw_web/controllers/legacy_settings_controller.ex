defmodule BusterClawWeb.LegacySettingsController do
  @moduledoc "Recovery for saved links to retired Settings pages."
  use BusterClawWeb, :controller

  def index(conn, _params), do: redirect(conn, to: ~p"/appearance")
end
