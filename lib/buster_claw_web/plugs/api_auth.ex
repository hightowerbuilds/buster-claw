defmodule BusterClawWeb.ApiAuth do
  @moduledoc """
  Verifies the `Authorization: Bearer <token>` header against
  `BusterClaw.ApiToken.value/0`. Halts with 401 on mismatch.
  """

  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    expected = BusterClaw.ApiToken.value()

    with [auth] <- get_req_header(conn, "authorization"),
         "Bearer " <> token <- auth,
         true <- Plug.Crypto.secure_compare(token, expected) do
      conn
    else
      _ ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(401, Jason.encode!(%{ok: false, error: "unauthorized"}))
        |> halt()
    end
  end
end
