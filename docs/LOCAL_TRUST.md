# Local Trust Model

Buster Claw runs an AI agent that can take powerful actions on the user's machine and across their connected web services. Application data is stored on the local machine; these boundaries are explicit:

- The Phoenix endpoint binds to `127.0.0.1` only. The HTTP command API (`POST /api/run`) requires the loopback API token; the scoped `:mcp` token is restricted to `:safe`-tier commands.
- Integration webhooks are received at `POST /integrations/:name/webhook` and verified against the integration's configured secret (HMAC / shared secret).
- Secrets are encrypted at rest with AES-256-GCM in the local SQLite database (`BusterClaw.Vault`; Google OAuth tokens via `BusterClaw.Google.Vault`): integration tokens/secrets and Google OAuth tokens.
- Fetched pages and workspace markdown (which can be agent-authored) are treated as untrusted input before display. Markdown rendering goes through the shared sanitizer (`BusterClaw.Markdown`).
- The in-app browser's content webview is sandboxed (no Tauri command access) and restricted to `http(s)` navigation.
- The command surface is trust-tiered: untrusted callers (the scoped `:mcp` token) may run only `:safe`-tier commands. `:restricted` commands (deletes, `document_save`, `gmail_send`, …) are refused, recorded by Sentinel, and not executed.
- Outbound fetches of agent-supplied URLs are SSRF-guarded (`BusterClaw.URLGuard`): scheme check, internal-hostname/IP-literal blocklist, and dual-family (IPv4 + IPv6) DNS resolution with every resolved address vetted. Unresolvable hosts are refused (fail closed), and every request hop — including redirects — is re-validated.

## Known accepted risks

- **DNS rebinding (TOCTOU) in the SSRF guard.** `URLGuard` resolves a hostname at *check* time, but the HTTP client resolves it again at *connect* time — an attacker-controlled DNS server can answer with a public address for the check and an internal one for the connect. The exposure is bounded: the loopback command API still requires a Bearer token even if reached, the practical window is a single request (`URLGuard.req_step/1` re-validates every hop, so each redirect gets a fresh check), and the softest target is the Playwright sidecar. The full fix is resolve-once-and-pin — vet the address, then force the connection to that exact IP (custom Finch `:transport_opts` / connect hostname) so check-time and connect-time answers cannot diverge. Tracked on the Shortlist; accepted until then.
