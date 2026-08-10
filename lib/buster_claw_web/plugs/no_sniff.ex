defmodule BusterClawWeb.NoSniff do
  @moduledoc """
  Sends `X-Content-Type-Options: nosniff` on responses that carry **raw workspace
  bytes** — files a user dropped in or an agent wrote.

  ## Why this is a plug and not nine `put_resp_header` calls

  Nine routes serve workspace bytes, and they are **deliberately pipeline-less**:
  each one either answers a non-HTML `accepts`, or is a media element request, or
  is a long-lived chunked stream. That was the right call for `accepts` and
  sessions, but it also meant none of them got `put_secure_browser_headers`, so
  `X-Content-Type-Options` appeared **nowhere in the codebase** until
  `RangeResponse` started sending it for the three audio routes.

  The remaining routes were fixed one at a time, which is how four of them drifted
  back out of coverage. **A pipeline makes it one invariant instead of nine
  copies**, and a scope that forgets `pipe_through :media` is visible in the
  router next to eight scopes that have it, rather than invisible inside a
  controller.

  This is the same move `:browser_page` made on 08-08 for the in-app browser's own
  pages: take the two headers worth having, leave `accepts`, `fetch_session` and
  `protect_from_forgery` behind. Only the header travels.

  ## What it defends, precisely

  Without `nosniff` a browser may disregard our declared `Content-Type` and sniff
  the bytes instead. A file named `chime.mp3` whose contents are HTML gets
  rendered, and its inline `<script>` runs **from our own origin** — the
  `window.__TAURI__` → `terminal_*` → shell chain that
  `BusterClawWeb.ContentSecurityPolicy` exists to break, reached by a response
  that never passed through it.

  Cheap, and it closes the gap for every route serving bytes with a declared
  non-HTML type: `/ws/image`, `/appearance/image/:slot`, `/notify/sound`,
  `/shaders/:name`, `/pockets/:pocket/:file`, `/browser/agent-view/:run_id`, and
  the three `RangeResponse` audio routes.

  ## What it does NOT fix, so nobody reads more into it

  `/ws/file`'s `:show` serves workspace `.html` **as `text/html` on purpose** — the
  local-trust boundary in `docs/LOCAL_TRUST.md`. `nosniff` changes nothing there,
  because nothing is being sniffed: we declared it HTML. **That route's exposure is
  the missing CSP, not the missing `nosniff`**, and it is still open —
  `ContentSecurityPolicy`'s own moduledoc records it. Closing this gate does not
  close that one.
  """

  @behaviour Plug

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    Plug.Conn.put_resp_header(conn, "x-content-type-options", "nosniff")
  end
end
