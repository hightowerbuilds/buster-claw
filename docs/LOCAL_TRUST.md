# Local Trust Model

Buster Claw runs an AI agent that can take powerful actions on the user's machine and across their connected web services. Application data is stored on the local machine; these boundaries are explicit:

- Webhooks bind to `127.0.0.1:9090`. A configured secret is enforced with `X-Buster-Claw-Secret` or `Authorization: Bearer ...`.
- Shell hooks run local commands through `bash -c`. They receive event JSON on stdin, time out, and record bounded stdout/stderr diagnostics in memory.
- Secrets are encrypted at rest with AES-256-GCM in the local SQLite database (`BusterClaw.Vault`; Google OAuth tokens via `BusterClaw.Google.Vault`): delivery tokens, webhook secrets, and integration tokens/secrets. Other stored config — MCP server command/env — is not encrypted, so only configure servers you trust.
- Fetched pages and workspace markdown (which can be agent-authored) are treated as untrusted input before display. Markdown rendering goes through the shared sanitizer (`BusterClaw.Markdown`).
- MCP servers are local processes configured by the user. Only configure servers whose command and working directory you trust.
- The command surface is trust-tiered: untrusted callers (the MCP server, headless agents) may run only `:safe`-tier commands. `:restricted` commands (deletes, `delivery_dispatch_all`, …) are refused, recorded by Sentinel, and not executed.
