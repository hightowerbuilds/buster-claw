defmodule BusterClawWeb.LegacyVoiceController do
  @moduledoc "Keep saved speech-settings bookmarks useful after synthesis removal."
  use BusterClawWeb, :controller

  def index(conn, _params), do: redirect(conn, to: ~p"/settings?tab=speech")
end
