defmodule BusterClawWeb.ContentSecurityPolicy do
  @moduledoc """
  Adds a Content-Security-Policy header to browser responses.

  ## Why this exists (Phase 5 — desktop RCE hardening)

  The app runs inside a Tauri webview that exposes `terminal_*` invoke handlers
  spawning the user's `$SHELL`. Any JavaScript that executes in the webview
  (e.g. stored-XSS in a LiveView, or hostile content rendered by the in-app
  browser/reader) could reach `window.__TAURI__` and obtain a shell. The webview
  loads the app from Phoenix over loopback HTTP, so the effective control is the
  CSP **response header Phoenix sends** — a strict `script-src` stops injected
  inline/remote scripts from executing in the first place.

  ## script-src is the real control

  `script-src 'self'` allows only our own bundles and **nothing inline at all** —
  no injected `<script>` tag, no inline event handler, no nonce to guess or
  leak. `connect-src`/`img-src`/`style-src` are intentionally permissive so the
  LiveView socket, Tauri IPC, reader images, and LiveView inline styles keep
  working — egress tightening is Phase 4's job (URLGuard).

  ## The nonce is gone (08-03)

  This used to be `script-src 'self' 'nonce-…'`, with a per-request nonce
  assigned to `conn.assigns.csp_nonce`. It had exactly **one** consumer app-wide:
  the theme bootstrap inline in `root.html.heex`. Moving that to
  `assets/js/theme.js` — its own render-blocking bundle, so the theme still
  cannot flash — left the nonce with nothing to authorize, and a policy carrying
  an unused escape hatch is strictly weaker than one without it.

  This matters more than tidiness. The webview exposes `terminal_*` invoke
  handlers, and this policy is the backstop the model-authored SVG channel is
  trusted on (`SvgViewer` sanitizes; the CSP is what catches what sanitizing
  misses). Its strongest form is the one where no inline script can run, full
  stop.

  ## Report-Only vs enforce

  Enforced in **prod** (`config/prod.exs` sets `config :buster_claw, :csp_mode,
  :enforce`) so the shipped desktop app actually blocks injected scripts. Dev and
  test default to **Report-Only** (`:csp_mode` unset) so Phoenix LiveReload's
  injected inline `<script>` keeps working — in dev, violations only surface in
  the webview console. LiveReload is not present in prod, which is why dropping
  the nonce costs nothing there.

  ## What this header does NOT cover

  The `/browser/*` scope (the in-app browser's own chrome, home, pages,
  workspace and history views) has **no `pipe_through`**, so it receives no CSP
  header at all. Those pages are built from our own strings and escape every
  interpolation through `Phoenix.HTML.html_escape/1`, so this is a
  defence-in-depth gap rather than a live hole — but it is a gap, and it is
  recorded in `LEFTOVERS.md` rather than left to be rediscovered.
  """

  import Plug.Conn

  @report_only_header "content-security-policy-report-only"
  @enforce_header "content-security-policy"

  def init(opts), do: opts

  def call(conn, _opts), do: put_resp_header(conn, header_name(), policy())

  defp header_name do
    case Application.get_env(:buster_claw, :csp_mode, :report_only) do
      :enforce -> @enforce_header
      _ -> @report_only_header
    end
  end

  defp policy do
    [
      "default-src 'self'",
      # The only RCE-relevant directive: our own bundles, nothing inline.
      "script-src 'self'",
      # LiveView/daisyUI set inline style attributes; allow them.
      "style-src 'self' 'unsafe-inline'",
      # In-app browser pages (home, bookmarks) render remote favicons/images;
      # images aren't an RCE vector.
      "img-src 'self' data: blob: https: http:",
      "font-src 'self' data:",
      # LiveView socket (ws/wss) + Tauri IPC custom origins. 'self' covers the
      # loopback HTTP origin (longpoll fallback).
      "connect-src 'self' ws: wss: ipc: http://ipc.localhost http://tauri.localhost",
      "object-src 'none'",
      "base-uri 'self'",
      "frame-ancestors 'self'",
      "form-action 'self'"
    ]
    |> Enum.join("; ")
  end
end
