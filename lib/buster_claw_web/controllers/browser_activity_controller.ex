defmodule BusterClawWeb.BrowserActivityController do
  @moduledoc "Read-only, bounded activity feed for the in-app browser's graph."
  use BusterClawWeb, :controller

  def index(conn, params) do
    conn
    |> put_resp_header("cache-control", "no-store")
    |> json(BusterClaw.Browser.Activity.snapshot(params))
  end
end
