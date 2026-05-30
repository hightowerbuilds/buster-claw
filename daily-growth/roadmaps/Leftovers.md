# Buster Claw Leftovers

Assessment date: 2026-05-26 (security pass added 2026-05-28)

This file tracks work intentionally deferred from the completed master roadmap,
now archived at `daily-growth/old-maps/master-roadmap.md`. These are not
abandoned; they are parked for future hardening or feature passes.

## Security Hardening (2026-05-28)

Closes findings from the codebase security review. All landed with tests.

- [x] Redact secrets in the command-surface serializer (`Commands.Result.to_json`).
  - Field denylist (`api_key`, `secret`, `token`, `webhook_secret`,
    `client_secret`, `refresh_token`, `access_token`, `password`) plus any
    `*_enc` column now serialize as `"[REDACTED]"`; unset secrets stay nil.
  - Closes the prompt-injection exfiltration path: the chat agent's safe-tier
    `*_list`/`*_get` tools can no longer leak provider keys / webhook secrets.
- [x] Encrypt provider/integration/webhook/delivery secrets at rest.
  - New app-wide `BusterClaw.Vault` (AES-256-GCM) + transparent
    `BusterClaw.Encrypted` Ecto type applied to `providers.api_key`,
    `webhooks.secret`, `delivery_destinations.token`, `integrations.token`,
    and `integrations.webhook_secret`.
  - Backfill migration `20260528223000_encrypt_secrets_at_rest` re-encrypts
    existing rows (idempotent; skips already-encrypted values).
- [x] Reclassify `hook_test` as `:restricted`.
  - It runs a hook's stored shell `target`; it is no longer exposed to the
    chat agent (verified by an `AgentTools` test).
- [x] SSRF guard on outbound fetches (`BusterClaw.URLGuard`).
  - Blocks loopback, link-local/metadata (169.254.0.0/16), and RFC1918 hosts
    (literals + DNS resolution) at the `Browser.fetch` / `Ingest.Fetcher`
    entry points, and re-validates each redirect hop via a Req request step.
  - Residual gaps (deferred): DNS-rebinding TOCTOU and fail-open on resolution
    error are not addressed; DNS resolution is config-gated
    (`:ssrf_resolve_dns`, off in test).

## Deferred Cutover Options

- [x] Supervised Playwright browser sidecar.
  - Completed as an opt-in supervised Node sidecar with a local HTTP `/fetch`
    boundary and `/health` endpoint.
  - `BusterClaw.Browser.fetch/2` now uses a configured/supervised sidecar when
    available and falls back to direct `Req` HTTP fetching otherwise.
  - `browser` sources now ingest through the browser boundary instead of the
    plain article fetcher.
- [ ] MCP over SSE and streaming responses.
  - The implemented endpoint is Streamable HTTP-style JSON response at `POST /mcp`.
- [ ] External MCP `tools/call` routing.
  - Current stdio support launches configured servers and discovers tools.
  - Revisit when Buster Claw needs to call tools from consumed local MCP servers,
    not just expose its own tools to external agents.

## Automation And Command Surface

- [ ] OpenAI, Gemini, and Codex provider tool adapters.
  - Priority: next candidate after the integration smoke.
  - Anthropic currently has the internal agent/tool loop.
- [ ] CLI install helper / symlink flow.
- [ ] Token rotation UI.
- [ ] Audit remaining `inspect(reason)` paths for user-facing redaction.

## Integrations

- [ ] Sentry API smoke with real credentials.
  - Decision: defer for now.
  - Current attempt: `hightowerbuilds/notes-that-float` returned 403.
  - Revisit when an auth token with Sentry issue/event read access is available.
- [ ] Umami API smoke with real credentials.
  - Decision: defer for now.
  - Revisit when an Umami base URL, website ID, and API token are available.
- [ ] Optionally dispatch generated monitoring briefs through Delivery.
  - Decision: defer for now.

## Gmail / Google Workspace

- [x] New `BusterClaw.Google` context family.
- [x] BYO Google OAuth desktop credentials.
- [x] Loopback OAuth callback route.
- [x] Encrypted token storage for Gmail accounts.
- [x] Simple Home-page GWS connection flow.
- [x] Dedicated GWS tab for account management.
- [x] Gmail labels/search/read commands.
- [x] Gmail sync into Library documents.
- [x] Google Calendar one-way sync into app calendar events.
- [x] Gmail draft-create command.
- [x] Gmail send command.
- [x] Incremental Gmail history sync beyond query/limit-based pulls.
- [x] Incremental Google Calendar sync tokens beyond query/window-based pulls.
- [x] Reconfirm encrypted-secret design, because it is broader than Gmail and may
  eventually cover provider keys and integration tokens.
  - Done and now applied: the 2026-05-28 security pass extended encryption at rest
    to provider keys, integration/webhook secrets, and delivery tokens via
    `BusterClaw.Vault` + `BusterClaw.Encrypted`. See the Security Hardening section.

## Packaging And Distribution

- [ ] Real external provider credential smoke testing.
  - Decision: defer for now.
  - Current cutover smoke can use a local Ollama provider or loopback
    OpenAI-compatible provider.
- [ ] Bundle/install Playwright npm dependency and browser binaries for packaged
  desktop releases.
  - The sidecar boundary is implemented, but distribution still needs an
    explicit Node/Playwright packaging strategy.
- [ ] OS keychain support for the vault key.
  - App-level secrets are now encrypted at rest (see Security Hardening), but the
    vault key is still derived from `secret_key_base`. Remaining work: store the
    key (or `secret_key_base`) in the OS keychain rather than env/config.
- [ ] Windows and Linux desktop packaging paths.
- [ ] Auto-updates, signing, notarization, and log rotation.
