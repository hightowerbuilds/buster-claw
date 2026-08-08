defmodule BusterClawWeb.BrowserHomeController do
  @moduledoc """
  The embedded browser's homepage — shown in the content webview when no URL is
  loaded. Dark-themed to match the app; server-renders the saved **bookmarks**
  (from `BusterClaw.Bookmarks`) above the **recent-URL** list (from
  `BusterClaw.BrowserHistory`), including workspace HTML/MD files. Clicking an
  entry navigates the content webview directly (plain links; allowed by the
  webview's http(s) nav guard); a bookmark's "×" posts a remove form back here.

  The markup lives in `BusterClawWeb.Browser.HomePage`.
  """
  use BusterClawWeb, :controller

  alias BusterClaw.{Bookmarks, BrowserHistory}
  alias BusterClawWeb.Browser.HomePage

  def show(conn, _params) do
    page = HomePage.html(%{bookmarks: Bookmarks.list(), history: BrowserHistory.recent()})

    conn
    |> put_resp_content_type("text/html")
    |> send_resp(200, page)
  end
end
