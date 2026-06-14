# Local Trust Model

Buster Claw runs an AI agent that can take powerful actions on the user's machine and across their connected web services. Application data is stored on the local machine; these boundaries are explicit:

- The Phoenix endpoint binds to `127.0.0.1` only. The HTTP command API (`POST /api/run`) requires the loopback API token; the scoped `:mcp` token is restricted to `:safe`-tier commands.
- Integration webhooks are received at `POST /integrations/:name/webhook` and verified against the integration's configured secret (HMAC / shared secret).
- Secrets are encrypted at rest with AES-256-GCM in the local SQLite database (`BusterClaw.Vault`; Google OAuth tokens via `BusterClaw.Google.Vault`): integration tokens/secrets and Google OAuth tokens.
- Fetched pages and workspace markdown (which can be agent-authored) are treated as untrusted input before display. Markdown rendering goes through the shared sanitizer (`BusterClaw.Markdown`).
- The in-app browser's content webview is sandboxed (no Tauri command access) and restricted to `http(s)` navigation.
- The command surface is trust-tiered: untrusted callers (the scoped `:mcp` token) may run only `:safe`-tier commands. `:restricted` commands (deletes, `document_save`, `gmail_send`, …) are refused, recorded by Sentinel, and not executed.
