defmodule BusterClawWeb.BrowserBookmarkController do
  @moduledoc """
  Saves and removes in-app browser bookmarks (`BusterClaw.Bookmarks`).

  `create` is called (POST, query params) by the native chrome toolbar's
  "+ Bookmark" button. `delete` is posted by the remove form on the browser
  homepage and redirects back to it. `index` returns the saved bookmarks as JSON
  for the chrome's bookmark bar. Loopback-only, single-user; no CSRF (raw scope).
  """
  use BusterClawWeb, :controller

  alias BusterClaw.Bookmarks

  @bar_limit 24

  # Bookmarks for the chrome bookmark bar (newest first, capped). Favicons are
  # derived per-URL (local /browser/favicon endpoint), never read from the file.
  def index(conn, _params) do
    items =
      Bookmarks.list()
      |> Enum.take(@bar_limit)
      |> Enum.map(fn e ->
        %{
          "url" => e["url"],
          "label" => e["label"] || e["url"],
          "folder" => Bookmarks.normalize_folder(e["folder"]),
          "favicon_url" => Bookmarks.favicon_url(e["url"])
        }
      end)

    json(conn, items)
  end

  def create(conn, %{"url" => url}) when is_binary(url) and url != "" do
    tags = parse_tags(conn.params["tags"])
    Bookmarks.add(url, conn.params["label"], tags, conn.params["folder"])
    send_resp(conn, 204, "")
  end

  def create(conn, _params), do: send_resp(conn, 400, "missing url")

  defp parse_tags(nil), do: []

  defp parse_tags(tags) when is_binary(tags) do
    tags |> String.split(",") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))
  end

  defp parse_tags(tags) when is_list(tags), do: tags
  defp parse_tags(_), do: []

  def delete(conn, %{"url" => url}) when is_binary(url) and url != "" do
    Bookmarks.remove(url)
    redirect(conn, to: ~p"/browser/home")
  end

  def delete(conn, _params), do: redirect(conn, to: ~p"/browser/home")
end
