# Gmail Integration Roadmap

## Purpose

Bring Gmail into Buster Claw as a first-class data source and agent tool, paving the
ground for the rest of Google Workspace (Calendar, Drive) to land in a shared
`lib/buster_claw/google/` family later.

Two use cases drive v1:

1. **Inbox ingest** — Gmail messages matching a per-account search query flow into the
   existing ingest → analysis → delivery pipeline as documents.
2. **Agent tool calls** — the active provider can drive Gmail through Buster Claw's
   canonical command surface (`gmail.search`, `gmail.read`, `gmail.draft`,
   `gmail.send`, etc.), available identically from chat, CLI, HTTP `/api/run`, and MCP.

There is no separate "Gmail Agent API" from Google — the standard Gmail REST API at
`gmail.googleapis.com` is what every agent on Gmail uses. Agentic behavior comes from
how we surface the API, not from a different endpoint.

## Non-Goals

- [ ] Do not ship a shared Buster Claw OAuth client. Users bring their own.
- [ ] Do not implement Gmail `watch` / Pub/Sub push notifications in v1.
- [ ] Do not implement attachment download in v1 (record presence in frontmatter only).
- [ ] Do not support domain-wide delegation / service accounts.
- [ ] Do not request `https://mail.google.com/` (full restricted scope).
- [ ] Do not build a parallel polling GenServer — manual "Sync now" + a `gmail.sync`
      command let the scheduler take over once it's wired (see CUTOVER.md).
- [ ] Do not expose Gmail through a non-loopback interface. Same `127.0.0.1` discipline
      as the rest of Buster Claw.

## Decisions (locked)

| Question                  | Choice                                                  |
| ------------------------- | ------------------------------------------------------- |
| Surface area              | Inbox ingest **+** agent tool calls                     |
| OAuth flow                | Loopback / Installed App (`http://127.0.0.1:<port>`)    |
| Code location             | New context `lib/buster_claw/google/`                   |
| OAuth client provisioning | Bring-your-own (paste `client_id` + `client_secret`)    |
| Scopes                    | `gmail.readonly` + `gmail.compose`                      |
| Accounts                  | Multi-account, single-user                              |
| Ingest trigger            | Manual "Sync now" + `gmail.sync` command (scheduler later) |

## Architecture

```
                   ┌─────────────────────────────────────┐
                   │  BusterClaw.Google                  │  ← shared family namespace
                   │  OAuth + Vault + Client primitives  │
                   └─────────────────────────────────────┘
                       ▲             ▲              ▲
                       │             │              │
              ┌────────┴────┐  ┌─────┴──────┐  ┌────┴─────────────┐
              │  Gmail      │  │ Calendar   │  │ Drive            │
              │  (v1)       │  │ (future)   │  │ (future)         │
              └─────┬───────┘  └────────────┘  └──────────────────┘
                    │
       ┌────────────┴────────────┬─────────────────────────┐
       │                         │                         │
┌──────┴──────────┐    ┌─────────┴─────────┐     ┌─────────┴──────────┐
│ Ingest pipeline │    │ Command surface   │     │ IntegrationsLive   │
│ (creates docs)  │    │ gmail.* commands  │     │ "Google" section   │
└─────────────────┘    └───────────────────┘     └────────────────────┘
```

The `Integrations` behaviour (`lib/buster_claw/integrations/service.ex`) stays as-is —
its read-only static-token contract doesn't fit Gmail's OAuth + send semantics. Gmail
gets its own context; the existing `/integrations` LiveView adds a "Google" panel that
calls into `BusterClaw.Google.*`.

## File layout

```
lib/buster_claw/google/
  vault.ex              # AES-256-GCM encrypt/decrypt, keyed off secret_key_base
  account.ex            # Ecto schema; virtual plaintext fields + encrypted persistence
  oauth.ex              # build_auth_url/2, exchange_code/3, refresh!/1
  callback_server.ex    # One-shot Bandit/Plug server on ephemeral 127.0.0.1 port
  auth.ex               # Orchestrates browser-open → callback capture → token persist
  client.ex             # Req wrapper, auto-refresh on 401 or near-expiry
  gmail.ex              # search, get_message, parse, to_document, labels, draft, send
  gmail/
    message.ex          # Header extraction, base64url body decode, html→text
    ingest.ex           # sync(account_id, opts) — dedupe by Gmail message id

priv/repo/migrations/
  <ts>_create_google_accounts.exs

lib/buster_claw_web/live/integrations_live.ex
  # adds "Google" panel + Connect Gmail modal

lib/buster_claw/commands.ex
  # adds gmail.* command handlers

docs/rewrite/COMMAND_SURFACE.md
  # documents new gmail.* commands
```

## Data model

`google_accounts` table:

| Column                      | Type      | Notes                                       |
| --------------------------- | --------- | ------------------------------------------- |
| `id`                        | integer   |                                             |
| `email`                     | text      | unique                                      |
| `client_id`                 | text      | per-account; BYO desktop OAuth client       |
| `client_secret_enc`         | binary    | encrypted at rest                           |
| `refresh_token_enc`         | binary    | encrypted at rest                           |
| `access_token_enc`          | binary    | encrypted at rest                           |
| `access_token_expires_at`   | utc_datetime |                                          |
| `scopes`                    | text      | space-joined granted scopes                 |
| `default_query`             | text      | e.g. `newer_than:7d -category:promotions`   |
| `last_synced_at`            | utc_datetime |                                          |
| `last_seen_history_id`      | text      | for future incremental sync via history API |
| `enabled`                   | boolean   | default true                                |
| `inserted_at`, `updated_at` | utc_datetime |                                          |

## OAuth flow (loopback)

1. UI: user pastes `client_id`, `client_secret`, optional `default_query`, clicks **Authorize**.
2. `Google.Auth.start_flow/1`:
   a. Generates a `state` nonce, picks a free 127.0.0.1 port.
   b. Starts a one-shot Bandit/Plug callback server on that port.
   c. Builds the Google auth URL with `redirect_uri=http://127.0.0.1:<port>/oauth/callback`,
      `scope="gmail.readonly gmail.compose"`, `access_type=offline`, `prompt=consent`.
   d. Opens the URL in the system browser (macOS `open`, with a Tauri command later).
3. User consents; Google redirects to the loopback URL with `?code=…&state=…`.
4. Callback server validates `state`, exchanges code via `Google.OAuth.exchange_code/3`,
   persists encrypted tokens via `Google.Account`, broadcasts success over PubSub,
   shuts itself down. The HTML response says "You can close this tab."
5. LiveView subscribed to the PubSub topic updates and closes the modal.

Refresh: `Google.Client` checks `access_token_expires_at` before each call; if within
60 seconds of expiry (or on 401), it refreshes using the stored refresh token and
persists the new access token + expiry.

## Inbox ingest

`BusterClaw.Google.Gmail.Ingest.sync(account_id, opts)` does:

1. Run the account's `default_query` via `users.messages.list` (paginated; capped at
   N per run, configurable, default 50).
2. For each message id not already present (dedupe by Gmail message id stored in
   document metadata), fetch full payload.
3. Parse to a `snapshot_item`-compatible map:
   - `name`: `Subject — From`
   - `source_url`: `https://mail.google.com/mail/u/0/#inbox/<id>`
   - `tags`: `["gmail", "<label-name>", …]`
   - `content`: markdown with `## From / To / Date / Subject / Labels` frontmatter
     and the decoded text body
4. Insert documents idempotently. Update `last_synced_at`.

Trigger: a **Sync now** button in the Google panel and a `gmail.sync` command. When
the scheduler stub closes, cron jobs can call `gmail.sync` directly — no new pathway
required.

## Command surface additions

| Command             | Args                                         | Returns                          |
| ------------------- | -------------------------------------------- | -------------------------------- |
| `gmail.accounts`    | —                                            | list of accounts + status        |
| `gmail.connect`     | `client_id`, `client_secret`, `default_query?` | auth URL + pending flow id     |
| `gmail.disconnect`  | `account`                                    | ok                               |
| `gmail.sync`        | `account?`, `limit?`                         | `{fetched, created, skipped}`    |
| `gmail.search`      | `account?`, `q`, `limit?`                    | list of message previews         |
| `gmail.read`        | `account?`, `id`                             | parsed message (markdown body)   |
| `gmail.labels`      | `account?`                                   | list of labels                   |
| `gmail.draft`       | `account?`, `to`, `subject`, `body`          | draft id + url                   |
| `gmail.send`        | `account?`, `to`, `subject`, `body`          | message id + url                 |

`account?` defaults to the single connected account when only one exists. All commands
flow through `BusterClaw.Commands` and are therefore reachable from chat slash commands,
CLI escript, HTTP `/api/run`, and MCP without additional wiring.

## Phases

### Phase 1 — Storage & crypto
- Migration `*_create_google_accounts.exs`.
- `BusterClaw.Google.Vault` (AES-256-GCM, key from `secret_key_base`).
- `BusterClaw.Google.Account` schema with encrypted-at-rest secret fields.

### Phase 2 — OAuth flow
- `Google.OAuth`: `build_auth_url/2`, `exchange_code/3`, `refresh!/1`.
- `Google.CallbackServer`: one-shot Bandit/Plug server, CSRF-checked state.
- `Google.Auth`: orchestration + PubSub success broadcast.

### Phase 3 — Authenticated client + Gmail API
- `Google.Client`: Req wrapper with auto-refresh.
- `Google.Gmail`: search / get / parse / to_document / labels / draft / send.
- `Google.Gmail.Message`: payload decoding (base64url, multipart, html→text fallback).

### Phase 4 — Inbox ingest
- `Google.Gmail.Ingest.sync/2` with dedupe by message id.
- Document tags + markdown shape per spec above.

### Phase 5 — LiveView UI
- "Google" panel inside `IntegrationsLive` with per-account rows.
- "Connect Gmail" modal: client_id / client_secret / default_query → Authorize.
- Per-account: status, scopes, last synced, **Sync now**, **Disconnect**.

### Phase 6 — Command surface
- Add `gmail.*` handlers to `BusterClaw.Commands`.
- Document each in `docs/rewrite/COMMAND_SURFACE.md`.

### Phase 7 — Tests
- OAuth exchange + refresh (mocked via `Req.Test`).
- Vault round-trip.
- Message parser fixtures: plain, multipart-alternative, html-only, base64url edge cases.
- Command dispatch happy paths.
- Ingest dedupe + idempotent insert.

## Tradeoffs accepted

- **Polling, not push** — matches the manual-sync choice; revisit if real-time matters.
- **Plain-text preference for body** — HTML emails get a basic strip; upgrade to a
  real HTML→Markdown converter later if quality is poor.
- **No attachments in v1** — note their presence in document frontmatter only.
- **macOS `open` for browser launch** — works inside Tauri without a new Tauri
  command; can be promoted to a Tauri command for cross-platform later.
- **BYO OAuth client** — users pay a 3-minute Google Cloud setup fee, but Buster Claw
  avoids Google's verification process and shared-quota responsibility.

## Out of scope (v1)

- `gmail watch` push notifications via Cloud Pub/Sub.
- Attachment ingest.
- Domain-wide delegation / service accounts.
- Workspace admin features.
- Calendar / Drive (directory named `google/` so they slot in trivially later).
- MIME attachment composition for `gmail.send`.

## Dependencies

No new hex packages required. `req`, `jason`, and `bandit` (or `plug_cowboy`) are
already in the dependency tree. The callback server reuses whichever HTTP server
Phoenix ships with; if neither is appropriate for a one-shot listener, fall back to
a small `:gen_tcp` accept loop — single-request HTTP is trivial.

## Success criteria

- A user can paste their desktop OAuth client credentials, click Authorize, complete
  the browser flow, and see their account listed as **Connected** within 30 seconds.
- `gmail.sync` for an account with ~50 matching messages completes in under 10s and
  creates documents idempotent across repeated runs.
- The active provider, called from chat, can run `gmail.search "from:me"` and
  `gmail.read <id>` and receive parsed markdown back.
- Tests pass without hitting the real Gmail API (all HTTP mocked).
