defmodule BusterClawWeb.RequireTrusted do
  @moduledoc """
  Narrows an already-authenticated API route to the **full** token alone.

  `ApiAuth` recognises three tokens and tags the connection with the trust level
  each one carries. That is the right default for `/api/run`, where the tier
  system decides per command what a caller may do. It is not enough for the
  Clinch: `Commands.call/3` never sees these routes, so there is no per-command
  tier to fall back on, and a route that manages credentials must not be
  reachable by the MCP token handed to external agents or the agent-untrusted
  token handed to a headless run working untrusted content.

  So this is deliberately not a tier check with a nice error — it is a floor.
  Anything that is not `:trusted` gets 403 and goes no further.

  ## What this is actually defending

  It is the second of the two independent walls in Clinch Phase 2, and the one
  that holds. The first — a browser with no `window.__TAURI__` cannot invoke the
  desktop shell's management commands — is an *absence*, honest and good for the
  UI, but an absence is one refactor away from being papered over. This is a
  credential check: the full token lives in the macOS Keychain and the shell's
  process environment, and a forwarding-only SSH key reaches neither, because it
  gets no shell and therefore no Keychain.

  A remote session can drive every LiveView in the app and still not reach here.
  """

  import Plug.Conn

  def init(opts), do: opts

  def call(%{assigns: %{caller: :trusted}} = conn, _opts), do: conn

  def call(conn, _opts) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(403, Jason.encode!(%{ok: false, error: "forbidden"}))
    |> halt()
  end
end
