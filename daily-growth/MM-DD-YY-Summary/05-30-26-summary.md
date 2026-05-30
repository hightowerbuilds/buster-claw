# 05-30-2026 Summary

## Today

### Codebase review

- Ran a fan-out review of the Phoenix codebase (~18.5k lines lib, ~7.4k lines
  test) across three lenses: security attack surface, architecture/code quality,
  and test maturity.
- Headline findings:
  - Secrets (provider API keys, integration/webhook/delivery tokens) were
    serialized in cleartext by the command surface and stored unencrypted at
    rest, exfiltratable via the chat agent's safe-tier tools (prompt injection).
  - `hook_test` was `:safe`, letting the agent run stored shell hooks.
  - Browser/ingest fetchers had no SSRF protection.
  - Architecture is sound; main debt is catalog/impl drift risk in `commands.ex`,
    a god `Integrations` context, an oversized `status_live.ex`, and duplicated
    changeset-error/chunk-collector code.
  - Test suite graded B+: disciplined HTTP mocking, deterministic time, real
    assertions; gaps around `agent_tools.ex` and the agentic loop.

### UML / architecture diagrams

- Added `docs/UML.md`: layered Mermaid diagrams generated from the code —
  system layers, supervision tree, domain model (all 18 schemas + relations),
  command-surface dispatch, provider abstraction, plus functional flows
  (ingest→analyze→deliver, agentic chat loop, HTTP routing/auth tiers).
- Linked it from the README Development Notes section.

### Security hardening pass

- C1 — Secret redaction in `Commands.Result.to_json`: denylist
  (`api_key`, `secret`, `token`, `webhook_secret`, `client_secret`,
  `refresh_token`, `access_token`, `password`) plus any `*_enc` column now
  serialize as `"[REDACTED]"`; unset secrets stay nil. Closes the prompt-injection
  exfiltration path through the agent's safe-tier `*_list`/`*_get` tools.
- C2 — Encryption at rest:
  - Added `BusterClaw.Vault` (app-wide AES-256-GCM) and `BusterClaw.Encrypted`,
    a transparent Ecto type (cast/hold plaintext, encrypt on dump, decrypt on
    load, legacy-plaintext passthrough).
  - Applied to `providers.api_key`, `webhooks.secret`,
    `delivery_destinations.token`, `integrations.token`, and
    `integrations.webhook_secret`. No ripple into contexts — structs still hold
    plaintext after load.
  - Added backfill migration `20260528223000_encrypt_secrets_at_rest`
    (idempotent; skips already-encrypted values).
  - Verified end-to-end against the real dev DB: `api_key` now stored as
    `0x01…` ciphertext, loads back as plaintext.
- H1 — Reclassified `hook_test` as `:restricted` (no longer exposed to the chat
  agent, verified by an `AgentTools` test).
- H2 — Added `BusterClaw.URLGuard`: blocks loopback, link-local/metadata
  (169.254.0.0/16), and RFC1918 hosts (IP literals incl. IPv6/IPv4-mapped, plus
  DNS resolution) at the `Browser.fetch` / `Ingest.Fetcher` entry points, and
  re-validates each redirect hop via a Req request step. DNS resolution is
  config-gated (`:ssrf_resolve_dns`, off in test).
- Residual gaps documented (not fixed): DNS-rebinding TOCTOU, fail-open on
  resolution error, and OS-keychain storage for the vault key.

### Leftovers.md updates

- Added a "Security Hardening (2026-05-28)" section recording C1/C2/H1/H2.
- Corrected the stale "reconfirm encrypted-secret design" line to note
  encryption is now applied to provider/integration/webhook/delivery secrets.
- Reframed the packaging item to "OS keychain support for the vault key" (the
  one remaining piece).

### In-app browser

- Added a dedicated in-app browser at `/browse` (`BusterClawWeb.BrowseLive`)
  rendered inside `Layouts.app`, so the app-nav sidebar + bumper is always
  present to return to the rest of the app.
- Features: URL bar (bare hosts auto-upgrade to `https://`), back/forward/reload
  with in-memory history, and inline links that re-fetch in place so the user
  never leaves the app.
- Added `BusterClaw.Browser.Reader`: tokenizes fetched HTML server-side into a
  safe `{:text, …}` / `{:link, text, url}` stream — no raw HTML, no sanitizer
  dependency, no JS hook. Scripts/styles stripped; anchors resolved to absolute
  http(s) against the page URL; `mailto:`/`#`/`javascript:` degrade to text.
  Links render as `phx-click` buttons.
- Reused the SSRF guard: blocked addresses show a safe inline message.
- Added the `/browse` route and a "Browse" sidebar nav item.
- Rationale: `Content.html_to_markdown` strips all tags, so the existing
  markdown had no links — the reader works from the raw page HTML instead.

### Document reader source link + deep linking

- Added `handle_params/3` to `BrowseLive` so `/browse?url=…` auto-loads (browse
  pages are now bookmarkable/deep-linkable).
- Repointed the Documents reader's source link from a bare external `<a href>`
  (which hijacked the whole Tauri webview) to a `<.link navigate={~p"/browse?…"}>`
  ("Open Source") that opens the source page inside the in-app browser.
- Net result: every route into external content — address bar, in-page links,
  and the document source link — now stays inside the app.

### Library tab group + sidebar slimming

- Added `BusterClawWeb.LibraryTabs` (a shared tab row in the same style as the
  Advanced tabs) and grouped Documents, Sources, and Analysis as sibling tabs.
- Removed Sources and Analysis from the sidebar; Documents is the single entry
  point into the group. Both stay routable.
- Renamed the first Library tab's label from "Documents" to "Library".
- Deleted the local Library data folder at
  `/Users/lukehightower/Desktop/websites/Library` (regenerated on next ingest).

### Tabbed window shell (sidebar → bottom dock, browser-style top tabs)

- Moved the navigation from the left sidebar to a horizontal **dock across the
  bottom** of the window.
- Added a browser-style **tab strip across the top** (`TabStrip` hook in
  `app.js`): each open route is a tab with its name and an × to close. Open tabs
  persist in `localStorage` (`bc:tabs`); the active tab tracks the URL.
- Updated `status_live_test` to assert the new `#tab-strip` / `#app-dock` shell.

### Multiple browser tabs

- Tabs are keyed by full path incl. query, so several `/browse` tabs coexist.
- A **"+"** at the end of the tab strip opens a fresh independent browser tab
  (`/browse?t=<id>`), each with its own URL bar and history.

### Split-view tab joining

- Drag a tab onto another (**Alt+drop**) to join them into a side-by-side
  **split tab** at `/split?left=…&right=…`; plain drag **reorders** tabs.
- `BusterClawWeb.SplitLive` renders each pane via nested `live_render`, mounted
  `embedded: true`; `BusterClawWeb.ChromeHook` (an `on_mount` added to the
  `:live_view` macro) makes embedded panes render **bare** (no tab strip/dock).
- Split panes have **Swap panes** and **Open as tab (unjoin)** controls.
- **URL-carry**: a joined Browse pane keeps its current page — the join link
  carries the url, `SplitLive` passes it via `session["url"]`, and `BrowseLive`
  loads from params **or** session (its `?url=` handling moved from
  `handle_params` to `mount` so it can be embedded).
- **Tab titles**: `BrowseLive` pushes `bc:tab_meta` (title + url) on load; the
  tab strip shows the page title instead of "Browse".
- The last two were built by **dispatching two parallel agents** over disjoint
  file sets (SplitLive vs. `app.js`/`BrowseLive`) with a shared contract, then
  integrated and verified centrally.

## Verification

- `mix compile --warnings-as-errors`: clean.
- New tests: `vault_test`, `url_guard_test`, `security_hardening_test`,
  `browser/reader_test`, `browse_live_test`, `split_live_test`, plus extended
  `documents_live_test`, `automation_routes_test`, `status_live_test`.
- `mix ecto.migrate` (dev): secret-encryption backfill applied; provider keys
  encrypted at rest and verified to decrypt on load.
- `mix precommit`: final run passed with **298 tests, 0 failures**.
- Live app verified end-to-end (tabbed shell, multiple browser tabs, split view,
  url-carry, swap/unjoin) against the running dev server + Tauri window.

## Where we left off

- Security review C1/C2/H1/H2 fixed, tested, and reflected in `Leftovers.md`;
  secrets encrypted at rest via `BusterClaw.Vault` + `BusterClaw.Encrypted`.
- `docs/UML.md` documents the current structure and functional flows.
- The UI is now a browser-style tabbed shell: bottom dock nav, top tab strip
  (name + ×), multiple independent browser tabs ("+"), and drag-to-join split
  view (Alt+drop) with swap/unjoin and url-carry. Plain drag reorders tabs.
- Library surfaces (Library/Sources/Analysis) are grouped under one tab row.
- Open follow-ups:
  - The README advertises a `/browse <url>` chat slash command that does not
    exist — wire chat's `/browse` to the view or correct the README.
  - True multi-view tab state (kept-alive views per tab) remains deferred;
    split panes start fresh except for the carried Browse url.
  - UX polish: choice of which drag gesture is join vs reorder (currently
    Alt+drop = join); split→unsplit shortcuts; nested splits.
  - Architecture/quality refactors from the review (catalog drift guard,
    `finalize_run/3`, route changeset errors through `ErrorFormatter`, break up
    `status_live.ex`, decide on chat streaming).
  - Remaining `Leftovers.md` items: provider tool adapters (OpenAI/Gemini/Codex),
    MCP SSE/streaming + external `tools/call`, OS keychain for the vault key,
    and packaging/distribution work.
