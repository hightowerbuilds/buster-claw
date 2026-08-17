# Buster Claw

**An assistant on your Mac that uses your tools, keeps working, and shows you what it did.**

Ask it in the app's own Chat, email it, or drive it from the built-in terminal. It reads and acts inside the browser tab you're actually looking at, your Gmail, Calendar and Drive, and it works a durable queue that survives a restart — one canonical command surface, 217 commands. Everything it changes lands on an auditable feed you can read afterwards, and restricted actions are refused outright for untrusted callers.

**You bring the intelligence.** There is no LLM inside Buster Claw and it needs no API keys: it runs **Claude Code, Codex, or OpenCode** under the agent subscription you already pay for. The app is the hands, the memory, and the receipts.

It's an Elixir/Phoenix + LiveView application wrapped in a Tauri desktop shell — Phoenix at the repository root, the shell in `desktop/tauri`.

---

## How it actually works

The agent doesn't call a chat API. It works a **queue**.

Trusted inbound requests land in a durable SQLite **Dispatch queue** — today that means mail from a sender on your trusted-senders list, or anything you (or an agent) enqueue by hand. Buster Claw projects that queue into workspace markdown the agent already reads (`Dispatch.md`). The agent pulls an item, does the work, and writes the result back through the `./buster-claw` CLI. The desktop UI gives you the command surface, the audit feed, and the results.

(Integration webhooks do *not* enqueue work — a verified GitHub event becomes a Library snapshot, not an agent task.)

That indirection is the whole design. It means work survives a crash, an agent can be replaced mid-shift, and nothing the agent does is invisible to you.

## Features

- **One command surface.** 217 commands across documents, browser, Google Workspace, integrations, finance, phone, notes, sketches, memory, skills, and orchestration — reachable from the CLI and an HTTP API, with per-caller trust tiers and an audit trail covering everything that changes state.
- **A real browser the agent can drive.** Not a headless scraper: the agent reads and acts inside **the tab you're actually looking at**, logged-in session and all (`browser_read`, `browser_click`, `browser_fill`), plus SSRF-guarded fetch for everything else.
- **Google Workspace.** One-click connect, then sync and act on Gmail, Calendar, Drive, Docs, and Contacts.
- **Integrations.** GitHub — polled on demand (by you or the agent; there is no background poller) or webhook-triggered, with signature verification that fails closed.
- **In-app terminal.** A real PTY where you run Claude Code, Codex, OpenCode, or anything else. Your shell survives tab switches.
- **Unattended shifts.** Go `on-duty` and a supervised Elixir janitor works the queue without you — with a kill switch (a `STOP` file), a crash-loop brake, and a hard budget cap that stops the shift rather than burning tokens.
- **BusterPhone**. An answering machine and SMS relay for your agent. Voice greets callers, records, transcribes, and files the message; signed inbound SMS is archived and trusted-number texts enter `sms-triage`. Gated outbound SMS uses a Twilio Messaging Service with an explicit kill switch and per-recipient daily cap. Voice is live; SMS activation still requires the operator's Messaging Service and A2P 10DLC campaign. Outbound calling is not built and the dialpad remains decorative. See `daily-growth/roadmaps/integrations/BUSTERPHONE_ROADMAP.md`.
- **Sentinel.** The security spine. Mutations are recorded and redacted (by key name *and* value shape — card numbers and API keys don't leak into the log). Untrusted callers can't run restricted commands, and refusals surface on the Security feed rather than being dropped silently. Two limits worth knowing up front: audit writes are **best-effort** — a failed write is logged and the action still proceeds — and a refusal is currently **visible, not approvable**. Reviewing and approving a refused action is not built yet.
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

> **macOS note:** both architectures build natively — `aarch64` (Apple Silicon) and `x86_64` (Intel), each with its own native ERTS. There is no universal binary and there must not be one: a lipo'd ERTS cannot allocate JIT memory on the Intel slice. See `daily-growth/roadmaps/platform/APPLE_ROADMAP.md`.

## Driving Buster Claw

### Authentication

The Phoenix endpoint binds to `127.0.0.1` only; the API token defends against other local users on a shared machine. Where that token lives depends on how you're running:

| Running | Token | How to get it |
|---|---|---|
| **Packaged app**, terminal *inside* the app | macOS Keychain (service `BusterClaw`, account `api_token`) | Already exported as `$BUSTER_CLAW_API_TOKEN` — nothing to look up |
| **Packaged app**, any other shell | same | `security find-generic-password -s BusterClaw -a api_token -w` |
| **Dev** (`mix phx.server`) | a fixed literal in `config/dev.exs` | `dev-token-loopback-only` |

`BUSTER_CLAW_API_TOKEN` overrides all of it.

> There is no `api_token` **file** to read. The desktop shell generates the token straight into the Keychain, and if it finds a plaintext file from an older build it migrates the value and **deletes the file** (`desktop/tauri/src/main.rs`), so secret material never lingers on disk. Dev never writes one either — it uses the literal above.

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
# Inside the app's terminal it's already set; elsewhere, read it from the Keychain:
TOKEN="${BUSTER_CLAW_API_TOKEN:-$(security find-generic-password -s BusterClaw -a api_token -w)}"

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

`mix precommit` must pass. It runs eight gates: compile with warnings-as-errors, `deps.unlock --unused`, format, `credo --strict`, the full test suite, and the `check_cycles.sh` / `check_file_sizes.sh` / `check_rust.sh` scripts. The JS tests (`bun test assets/js`) run separately — see [docs/QUALITY.md](docs/QUALITY.md). Contributions ship under the repository license (PolyForm Shield 1.0.0) — no CLA, no copyright assignment.

## License

**[PolyForm Shield 1.0.0](LICENSE)** — source-available, not open source.

**Use it for anything, including commercial work.** Read it, audit it, run it at your company, change it, build on it. There is nothing to buy and no account to create. The source is readable so the runtime can be *audited* rather than trusted on faith — which is the whole point of a tool that drives a browser and reads your email.

**The one thing you may not do is compete with it** — ship Buster Claw, or a product built from its source, as a substitute for Buster Claw.

The **name, wordmark, and logo** are reserved separately; rename your fork. See **[TRADEMARK.md](TRADEMARK.md)**.

> **Relicensed 2026-08-10, and the earlier grant still stands.** Buster Claw was MIT-licensed from April until this date. **An MIT grant cannot be withdrawn**: every commit released under it remains MIT for anyone who has it, with all the rights MIT gives, permanently. This license governs the code from here forward. If you rely on the MIT terms, pin a commit from before 2026-08-10.
