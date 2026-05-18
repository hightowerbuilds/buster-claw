defmodule BusterClawWeb.HealthController do
  use BusterClawWeb, :controller

  def show(conn, _params) do
    json(conn, %{status: "ok"})
  end
end
