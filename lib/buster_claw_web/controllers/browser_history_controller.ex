defmodule BusterClawWeb.BrowserHistoryController do
  @moduledoc """
  Records a visited URL into `BusterClaw.BrowserHistory` for the browser homepage.
  Called (POST, query params) by the native chrome toolbar on each navigation.
  Loopback-only, single-user; no CSRF (raw scope).
  """
  use BusterClawWeb, :controller

  alias BusterClaw.BrowserHistory

  def create(conn, %{"url" => url}) when is_binary(url) and url != "" do
    BrowserHistory.record(url, conn.params["label"])
    send_resp(conn, 204, "")
  end

  def create(conn, _params), do: send_resp(conn, 400, "missing url")
end
