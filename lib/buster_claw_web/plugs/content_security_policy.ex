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

  `script-src 'self' 'nonce-…'` allows only the bundled `app.js` and our own
  nonce-tagged inline bootstrap; it blocks injected `<script>` tags and inline
  event handlers. `connect-src`/`img-src`/`style-src` are intentionally
  permissive so the LiveView socket, Tauri IPC, reader images, and LiveView
  inline styles keep working — egress tightening is Phase 4's job (URLGuard).

  ## Report-Only vs enforce

  Defaults to **Report-Only** (`:csp_mode` unset): the header is
  `content-security-policy-report-only`, which never blocks anything — violations
  only surface in the webview console. After smoke-testing the desktop app and
  confirming the console is clean, flip to enforcing with:

      config :buster_claw, :csp_mode, :enforce

  No code change is needed to enforce. The per-request nonce is assigned to
  `conn.assigns.csp_nonce` and consumed by the inline `<script>` in
  `root.html.heex`.
  """

  import Plug.Conn

  @report_only_header "content-security-policy-report-only"
  @enforce_header "content-security-policy"

  def init(opts), do: opts

  def call(conn, _opts) do
    nonce = generate_nonce()

    conn
    |> assign(:csp_nonce, nonce)
    |> put_resp_header(header_name(), policy(nonce))
  end

  defp header_name do
    case Application.get_env(:buster_claw, :csp_mode, :report_only) do
      :enforce -> @enforce_header
      _ -> @report_only_header
    end
  end

  defp generate_nonce, do: 16 |> :crypto.strong_rand_bytes() |> Base.encode64()

  defp policy(nonce) do
    [
      "default-src 'self'",
      # The only RCE-relevant directive: own bundle + nonce-tagged inline only.
      "script-src 'self' 'nonce-#{nonce}'",
      # LiveView/daisyUI set inline style attributes; allow them.
      "style-src 'self' 'unsafe-inline'",
      # Reader/in-app browser renders remote images; images aren't an RCE vector.
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
