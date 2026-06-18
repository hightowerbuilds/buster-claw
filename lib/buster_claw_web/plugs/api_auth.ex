defmodule BusterClawWeb.ApiAuth do
  @moduledoc """
  Verifies the `Authorization: Bearer <token>` header and tags the connection
  with the authenticated caller's trust level in `conn.assigns.caller`:

  - the full API token (`BusterClaw.ApiToken.value/0`) → `:trusted`
    (the user's own CLI / `/api/run`; may run any command)
  - the scoped MCP token (`BusterClaw.ApiToken.mcp_value/0`) → `:mcp`
    (handed to external agents; may only run safe-tier commands, enforced
    centrally in `BusterClaw.Commands.call/3`)
  - the agent-untrusted token (`BusterClaw.ApiToken.agent_value/0`) →
    `:agent_untrusted` (handed by the Dispatcher to a headless run working
    untrusted-origin content; may do a lot but is refused the `gated`
    outbound/irreversible commands)

  The trust boundary is therefore *token-derived*, not route-derived: an agent
  holding only the MCP token is restricted on every route, including `/api/run`.

  Halts with 401 on a missing/unrecognized token.
  """

  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    with [auth] <- get_req_header(conn, "authorization"),
         "Bearer " <> token <- auth,
         {:ok, caller} <- classify(token) do
      assign(conn, :caller, caller)
    else
      _ ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(401, Jason.encode!(%{ok: false, error: "unauthorized"}))
        |> halt()
    end
  end

  # Compare against both tokens with timing-safe comparison. The full token
  # wins if (mis)configured to equal the MCP token.
  defp classify(token) do
    cond do
      Plug.Crypto.secure_compare(token, BusterClaw.ApiToken.value()) ->
        {:ok, :trusted}

      Plug.Crypto.secure_compare(token, BusterClaw.ApiToken.agent_value()) ->
        {:ok, :agent_untrusted}

      Plug.Crypto.secure_compare(token, BusterClaw.ApiToken.mcp_value()) ->
        {:ok, :mcp}

      true ->
        :error
    end
  end
end
