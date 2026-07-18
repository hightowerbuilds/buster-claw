# Local Trust Model

Buster Claw runs an AI agent that can take powerful actions on the user's machine and across their connected web services. Application data is stored on the local machine; these boundaries are explicit:

- The Phoenix endpoint binds to `127.0.0.1` only. The HTTP command API (`POST /api/run`) requires the loopback API token; the scoped `:mcp` token is restricted to `:safe`-tier commands.
- Integration webhooks are received at `POST /integrations/:name/webhook` and verified against the integration's configured secret (HMAC / shared secret).
- Secrets are encrypted at rest with AES-256-GCM in the local SQLite database (`BusterClaw.Vault`; Google OAuth tokens via `BusterClaw.Google.Vault`): integration tokens/secrets and Google OAuth tokens.
- Fetched pages and workspace markdown (which can be agent-authored) are treated as untrusted input before display. Markdown rendering goes through the shared sanitizer (`BusterClaw.Markdown`).
- The in-app browser's content webview is sandboxed (no Tauri command access) and restricted to `http(s)` navigation.
- The command surface is trust-tiered: untrusted callers (the scoped `:mcp` token) may run only `:safe`-tier commands. `:restricted` commands (deletes, `document_save`, `gmail_send`, …) are refused, recorded by Sentinel, and not executed.
- Outbound fetches of agent-supplied URLs are SSRF-guarded (`BusterClaw.URLGuard`): scheme check, internal-hostname/IP-literal blocklist, and dual-family (IPv4 + IPv6) DNS resolution with every resolved address vetted. Unresolvable hosts are refused (fail closed). The connection is **pinned to the vetted address** — the hop's URL is rewritten to the resolved IP and the original hostname rides in `connect_options: [hostname: ...]` (Host header, TLS SNI, and certificate verification all use the original name), so a DNS-rebinding server cannot answer public at check time and internal at connect time. Every request hop — including each redirect — is re-validated and re-pinned from a fresh resolution (`URLGuard.attach/2`; note Req does not re-run request steps on redirect hops by itself, so the guard's response step re-arms it per hop).

## Known accepted risks

- **SSRF pinning falls back to validate-only in one narrow case:** when DNS resolution is disabled by config (`:ssrf_resolve_dns` — off only in test). (A second case — the Playwright sidecar, which fetched with its own browser stack — was deleted 07-18.) ~~DNS rebinding (TOCTOU) in the SSRF guard~~ — **closed 07-14** by resolve-once-and-pin, exactly the fix this entry used to describe. The same change closed an unadvertised gap: Req 0.5 does not re-run request steps on redirect hops, so the old per-hop re-validation claim was aspirational — a redirect to an internal address was previously followed. Both paths are now covered by tests (`test/buster_claw/url_guard_test.exs`).
