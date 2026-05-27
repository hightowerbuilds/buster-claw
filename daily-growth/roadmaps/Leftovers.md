# Buster Claw Leftovers

Assessment date: 2026-05-26

This file tracks work intentionally deferred from `master-roadmap.md`. These are
not abandoned; they are parked so the active roadmap can stay focused on cutover
and daily-use hardening.

## Deferred Cutover Options

- [ ] Supervised Playwright browser sidecar.
  - Decision: defer for now.
  - Reason: sample-source smoke showed current HTTP ingestion works for RSS and
    static/server-rendered pages. JS-heavy app/social/authenticated pages still
    need a browser, but they are not required for the current cutover.
  - Revisit when real required sources produce login shells, empty titles, app
    shells, or missing client-rendered content.
- [ ] MCP over SSE and streaming responses.
  - The implemented endpoint is Streamable HTTP-style JSON response at `POST /mcp`.
- [ ] External MCP `tools/call` routing.
  - Current stdio support launches configured servers and discovers tools.
  - Revisit when Buster Claw needs to call tools from consumed local MCP servers,
    not just expose its own tools to external agents.

## Automation And Command Surface

- [ ] OpenAI, Gemini, and Codex provider tool adapters.
  - Anthropic currently has the internal agent/tool loop.
- [ ] CLI install helper / symlink flow.
- [ ] Token rotation UI.
- [ ] Audit remaining `inspect(reason)` paths for user-facing redaction.

## Integrations

- [ ] Manual smoke with real Sentry, GitHub, and Umami credentials.
- [ ] Decide whether integration webhook events should auto-queue analysis.
- [ ] Decide retention policy for raw webhook payload excerpts.
- [ ] Decide whether monitoring briefs should allow provider overrides.
- [ ] Add polling-window/dedup controls if repeated snapshots become noisy.
- [ ] Optionally dispatch generated monitoring briefs through Delivery.

## Gmail / Google Workspace

- [x] New `BusterClaw.Google` context family.
- [x] BYO Google OAuth desktop credentials.
- [x] Loopback OAuth callback route.
- [x] Encrypted token storage for Gmail accounts.
- [x] Simple Home-page GWS connection flow.
- [x] Dedicated GWS tab for account management.
- [x] Gmail labels/search/read commands.
- [x] Gmail sync into Library documents.
- [ ] Gmail draft/send commands.
- [ ] Incremental Gmail history sync beyond query/limit-based pulls.
- [x] Reconfirm encrypted-secret design, because it is broader than Gmail and may
  eventually cover provider keys and integration tokens.

## Packaging And Distribution

- [ ] Real external provider credential smoke testing.
  - Decision: defer for now.
  - Current cutover smoke can use a local Ollama provider or loopback
    OpenAI-compatible provider.
- [ ] Full secrets encryption/keychain support.
- [ ] Windows and Linux desktop packaging paths.
- [ ] Auto-updates, signing, notarization, and log rotation.
