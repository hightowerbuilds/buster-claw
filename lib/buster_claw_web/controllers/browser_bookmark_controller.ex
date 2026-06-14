defmodule BusterClawWeb.BrowserBookmarkController do
  @moduledoc """
  Saves and removes in-app browser bookmarks (`BusterClaw.Bookmarks`).

  `create` is called (POST, query params) by the native chrome toolbar's
  "+ Bookmark" button. `delete` is posted by the remove form on the browser
  homepage and redirects back to it. Loopback-only, single-user; no CSRF (raw
  scope).
  """
  use BusterClawWeb, :controller

  alias BusterClaw.Bookmarks

  def create(conn, %{"url" => url}) when is_binary(url) and url != "" do
    Bookmarks.add(url, conn.params["label"])
    send_resp(conn, 204, "")
  end

  def create(conn, _params), do: send_resp(conn, 400, "missing url")

  def delete(conn, %{"url" => url}) when is_binary(url) and url != "" do
    Bookmarks.remove(url)
    redirect(conn, to: ~p"/browser/home")
  end

  def delete(conn, _params), do: redirect(conn, to: ~p"/browser/home")
end
