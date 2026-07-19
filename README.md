# Buster Claw

**A desktop runtime that gives an AI agent hands — and a full audit trail of what it did with them.**

You run **Claude Code or Codex in the built-in terminal**. The agent drives the app through one canonical command surface (~157 commands) covering your browser, Gmail, Calendar, Drive, GitHub, and a durable work queue. Every command, every outbound send, and every untrusted fetch lands on an auditable security feed, and restricted actions are refused outright for untrusted callers.

**There is no LLM inside Buster Claw and it needs no API keys.** The intelligence is the agent you already pay for; the app is the body, the memory, and the receipts.

It's an Elixir/Phoenix + LiveView application wrapped in a Tauri desktop shell — Phoenix at the repository root, the shell in `desktop/tauri`.

---

## How it actually works

The agent doesn't call a chat API. It works a **queue**.

Trusted inbound requests land in a durable SQLite **Dispatch queue** — today that means mail from a sender on your trusted-senders list, or anything you (or an agent) enqueue by hand. Buster Claw projects that queue into workspace markdown the agent already reads (`shift/Dispatch.md`). The agent pulls an item, does the work, and writes the result back through the `./buster-claw` CLI. The desktop UI gives you the command surface, the audit feed, and the results.

(Integration webhooks do *not* enqueue work — a verified GitHub or Sentry event becomes a Library snapshot, not an agent task.)

That indirection is the whole design. It means work survives a crash, an agent can be replaced mid-shift, and nothing the agent does is invisible to you.

## Features

- **One command surface.** ~157 commands across documents, browser, Google Workspace, integrations, finance, memory, skills, and orchestration — reachable from the CLI and an HTTP API, with per-caller trust tiers and a full audit trail.
- **A real browser the agent can drive.** Not a headless scraper: the agent reads and acts inside **the tab you're actually looking at**, logged-in session and all (`browser_read`, `browser_click`, `browser_fill`), plus SSRF-guarded fetch for everything else.
- **Google Workspace.** One-click connect, then sync and act on Gmail, Calendar, Drive, Docs, and Contacts.
- **Integrations.** GitHub, Sentry, and Umami — polled on demand (by you or the agent; there is no background poller) or webhook-triggered, with signature verification that fails closed.
- **In-app terminal.** A real PTY where you run Claude Code, Codex, or anything else. Your shell survives tab switches.
- **Unattended shifts.** Go `on-duty` and a supervised Elixir janitor works the queue without you — with a kill switch (a `STOP` file), a crash-loop brake, and a hard budget cap that stops the shift rather than burning tokens.
- **BusterPhone**. An answering machine and SMS relay for your agent. Voice greets callers, records, transcribes, and files the message; signed inbound SMS is archived and trusted-number texts enter `sms-triage`. Gated outbound SMS uses a Twilio Messaging Service with an explicit kill switch and per-recipient daily cap. Voice is live; SMS activation still requires the operator's Messaging Service and A2P 10DLC campaign. Outbound calling is not built and the dialpad remains decorative. See `daily-growth/roadmaps/phone-maps/BUSTERPHONE_ROADMAP.md`.
- **Sentinel.** The security spine. Every mutation is recorded and redacted (by key name *and* value shape — card numbers and API keys don't leak into the log). Untrusted callers can't run restricted commands, and refusals are queued for you, not silently dropped.
- **A workspace you own.** Everything is markdown on your disk. No lock-in; `grep` works.
- **WebGPU shaders.** The homepage runs a live WGSL background. Drop a `.wgsl` file into your workspace and it compiles at runtime — no rebuild.

## Quick Start

Requirements (exact versions pinned in [`.tool-versions`](.tool-versions); `asdf install` matches them):

- Elixir/Erlang
- Node.js (assets: `cd assets && npm ci`)
- Rust/Cargo
- `cargo-tauri` (`cargo install tauri-cli`)

The single-command launcher boots Phoenix, waits for `/_health`, then opens the desktop window (and tears down on Ctrl-C):

```bash
./scripts/dev.sh
```

To build a distributable desktop app (`.app` + `.dmg`) from a clone, see **[BUILD.md](BUILD.md)**:

```bash
./scripts/build_desktop.sh
```

Manual fallback — Phoenix and the shell in separate terminals:

```bash
mix phx.server
```

```bash
cd desktop/tauri
cargo tauri dev
```

Phoenix serves at `http://127.0.0.1:4000/`; the Tauri shell opens the same app in a native window. Override the endpoint with `BUSTER_CLAW_PHOENIX_URL`.

> **macOS note:** the current build is **x86_64 only**. An Apple-Silicon-native build is in progress — see `daily-growth/roadmaps/DISTRIBUTION_ROADMAP.md`.

## Driving Buster Claw

### Authentication

A loopback API token is generated on first launch at `~/Library/Application Support/BusterClaw/api_token`. The Phoenix endpoint binds to `127.0.0.1` only; the token defends against other local users on a shared machine. Override with `BUSTER_CLAW_API_TOKEN`.

Three tokens exist, and **the trust tier is derived from which one you present** — not from the route:

| Caller | May run |
|---|---|
| `trusted` (you, your CLI) | anything |
| `agent_untrusted` (a run that has touched untrusted content) | anything *except* gated commands (sends, deletes, shares) |
| `agent` / `mcp` | safe-tier reads only |

### CLI

```bash
mix escript.build                                   # build once

./buster-claw commands                              # list the catalog
./buster-claw document list                         # noun-verb shorthand
./buster-claw run web_search --json '{"query": "phoenix liveview"}'
./buster-claw on-duty                               # go on duty; work the queue unattended
```

### The Dispatch queue (how a terminal agent works)

```bash
./buster-claw dispatch list                         # see open items
./buster-claw dispatch claim --job mail-triage      # pull the next item
./buster-claw dispatch reply <id> --body "…"        # write a result back
./buster-claw dispatch done <id>                    # close it out (or: block <id>)
```

### HTTP API

```bash
TOKEN=$(cat ~/Library/Application\ Support/BusterClaw/api_token)

curl http://127.0.0.1:4000/api/commands             # catalog (no auth)

curl -X POST http://127.0.0.1:4000/api/run \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"command":"document_list","args":{}}'
```

## Documentation

- [Architecture](docs/ARCHITECTURE.md) — runtime shape, contexts, persisted files
- [Command surface](docs/COMMAND_SURFACE.md) — the catalog and its trust tiers
- [Local trust model](docs/LOCAL_TRUST.md) — shell hooks, webhooks, stored secrets, fetched markdown
- [UML diagrams](docs/UML.md) — supervision tree, domain model, HTTP routing
- [Build & packaging](BUILD.md) · [Desktop packaging notes](docs/DESKTOP_PACKAGING.md)
- [Quality checks](docs/QUALITY.md) — run before refactors

## Contributing

`mix precommit` (compile with warnings-as-errors, format, `credo --strict`, and the full test suite) must pass. Contributions ship under the MIT license — no CLA, no copyright assignment.

## License

**[MIT](LICENSE)** — including the WGSL shaders and the CSS design system. Fork it, sell it, build on it.

The **name, wordmark, and logo** are reserved; rename your fork. See **[TRADEMARK.md](TRADEMARK.md)** — it's short, and the only ask is that you don't ship under our badge.
