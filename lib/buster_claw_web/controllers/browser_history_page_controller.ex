defmodule BusterClawWeb.BrowserHistoryPageController do
  @moduledoc """
  The in-app browser's **History** page: everything recorded by
  `BusterClaw.BrowserHistory`, grouped by day, searchable, with per-day and
  clear-all controls. Reached from the browser chrome's History button.

  The markup lives in `BusterClawWeb.Browser.HistoryPage`.
  """
  use BusterClawWeb, :controller

  alias BusterClaw.BrowserHistory
  alias BusterClawWeb.Browser.HistoryPage

  def show(conn, params) do
    q = params["q"] |> to_string() |> String.trim()

    conn
    |> put_resp_content_type("text/html")
    |> send_resp(200, HistoryPage.html(%{query: q, groups: groups(q)}))
  end

  def clear(conn, %{"scope" => "all"}) do
    BrowserHistory.clear()
    redirect(conn, to: "/browser/history")
  end

  def clear(conn, %{"scope" => "day", "date" => iso}) do
    with {:ok, date} <- Date.from_iso8601(iso),
         {:ok, from} <- DateTime.new(date, ~T[00:00:00], "Etc/UTC"),
         {:ok, until} <- DateTime.new(Date.add(date, 1), ~T[00:00:00], "Etc/UTC") do
      BrowserHistory.clear_range(from, until)
    end

    redirect(conn, to: "/browser/history")
  end

  def clear(conn, _params), do: send_resp(conn, 400, "bad clear request")

  defp groups(""), do: BrowserHistory.grouped_by_day()

  defp groups(q) do
    case BrowserHistory.search(q, limit: 200) do
      {:ok, entries} ->
        entries
        |> Enum.group_by(&DateTime.to_date(&1.visited_at))
        |> Enum.sort_by(fn {date, _} -> date end, {:desc, Date})

      _ ->
        []
    end
  end
end
