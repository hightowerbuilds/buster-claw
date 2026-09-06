# scripts/

One line per script: what it does and who runs it. "Who runs it" is the part
that matters — a script with no named runner looks like litter and gets deleted
by mistake (the 09-05 review found six such scripts; the two steering smokes
among them are the ones that caught four defects the unit suite could not).
If you add a script, add its line here; if you delete one, delete its line.

Runner key: **CI** = a workflow step in `.github/workflows/`; **precommit** =
the `mix precommit` alias in `mix.exs`; **build** = called by another script;
**human** = run by hand when the situation calls for it; **manual smoke** =
opt-in acceptance run against something CI cannot supply — a running server, the
packaged `.app`, or the operator's real logged-in agent CLI (that last kind costs
money) — run it before touching the thing it names.

## Gates (assert, never repair)

| Script | What it does | Who runs it |
|---|---|---|
| `check_cycles.sh` | Asserts the inventory of accepted `mix xref` dependency cycles (each named with its reason); any new cycle, or a broken accepted one, fails. | precommit |
| `check_docs_drift.sh` | Every `./buster-claw <verb>` in the live docs (README, docs/, user-guide/, introduction/) must be a verb the CLI dispatches or a command the catalog carries. | CI (`ci.yml` "Docs drift check"); the `mix lint` alias; human, before pushing doc edits — it is NOT in `mix precommit` |
| `check_file_sizes.sh` | File-size gate: holds the line-count inventory so decomposed files cannot silently regrow. | precommit |
| `check_macos_floor.sh` | Asserts the advertised `minimumSystemVersion` is one every Mach-O in the bundle (shell + bundled ERTS) can actually load on. | CI (`release-desktop.yml`), after `build_desktop.sh` |
| `check_rust.sh` | The Rust gate for the desktop shell: `cargo fmt --check`, `clippy -D warnings`, `cargo test` (incl. the ACL lockstep guard). | precommit. CI's `rust` job re-types the same three commands rather than calling this script, so the two can drift — check both when you change either |

## Build and release

| Script | What it does | Who runs it |
|---|---|---|
| `build_desktop.sh` | Builds the desktop bundle: Phoenix release + Tauri shell → `Buster Claw.app` / `.dmg`. Pins `MIX_ENV=prod`, preflights the toolchain, and calls `sync_version.sh` and `codesign_release.sh` (those two only — it asserts the bundle carries a runnable release itself, and leaves the Rust gate and the boot smoke to their own runners). | CI (`release-desktop.yml`); human for a local release build |
| `build_update_feed.sh` | Assembles the updater feed (`latest.json`) from the per-architecture bundles for the `latest` GitHub Release. | CI (`release-desktop.yml`) |
| `codesign_release.sh` | Signs every Mach-O inside the staged Elixir/OTP release — Tauri's bundler does not sign `Resources/`, and notarization rejects each unsigned Erlang binary. | build (`build_desktop.sh`) |
| `sync_version.sh` | Propagates the repo-root `VERSION` into `tauri.conf.json` and `Cargo.toml`. Idempotent. | build (`build_desktop.sh`); `mix.exs` reads `VERSION` directly |
| `smoke_release_boot.sh` | Proves the PACKAGED release boots headless (no GUI, no network) — the artifact test that would have caught the six days of empty `Resources/release` DMGs. | CI (`release-desktop.yml`, the step right after `build_desktop.sh`); human, after a local release build — `build_desktop.sh` does NOT call it |
| `install_launchd.sh` | Installs the KeepAlive LaunchAgent for the packaged app on macOS: renders `desktop/tauri/launchd/lol.busterclaw.desktop.plist`, drops it in `~/Library/LaunchAgents`, loads it, so launchd restarts the app across crashes, force-quits, and reboots — the outermost watchdog for an unattended shift. Uninstall recipe in its header. | human, on a machine that runs unattended shifts. No CI or code referrer; the plist it renders is its only cross-reference |

## Development

| Script | What it does | Who runs it |
|---|---|---|
| `dev.sh` | Starts Phoenix (or reuses a running one whose env still matches `.env`), waits for :4000, then opens the Tauri window. Ctrl-C tears down what it started. | human, daily |
| `gen_sounds.exs` | Regenerates the bundled default chime set into `priv/static/sounds/` (`mix run scripts/gen_sounds.exs`). The output is COMMITTED — this is the recipe, the repo holds the dish, because libm's `sin` differs across machines in the last ulp. Deterministic on one machine. | human, only when `BusterClaw.Notifications.SoundGen` changes. Referenced from `.gitignore` and `sound.ex`/`sound_gen.ex` comments, nothing runs it |

## Manual smokes and probes (opt-in, never in CI)

| Script | What it does | Who runs it |
|---|---|---|
| `smoke_command_surface.sh` | End-to-end smoke of the HTTP command surface against a running server on :4000 (dev server or bundled release). Token from env → Keychain → legacy file. | manual smoke — run before touching `BusterClaw.Commands` dispatch, the API token path, or the router |
| `smoke_desktop.sh` | Packaged-app smoke: with the real `.app` running (real Keychain, real data dir), drives the HTTP API from outside and forces one agent round-trip through the native bridge. A command that is ACL-dead in the packaged build fails here and nowhere else. | manual smoke — run before a release and before touching `build.rs`, `capabilities/*.json`, or the screenshot bridge |
| `probe_claude_duplex.exs` | CHAT_LIVE_STEERING Phase 0, probes 1–2: can a long-lived `claude -p --input-format stream-json` accept a second user message into the running turn? Plain `elixir`, no app boot. Also the prototype for `AgentRunner.open_port/4`'s duplex opener. | manual smoke — run before touching `ChatTransport.Claude`/`ClaudeDuplex`, `AgentRunner.open_port`, or the `</dev/null` redirect |
| `probe_codex_appserver.exs` | CHAT_LIVE_STEERING Phase 0, probes 3–4: does `codex app-server` steer mid-turn, reject a stale turn id, and confine like `codex exec -s read-only`? Protocol shapes read from codex's own generated JSON schema. Plain `elixir`. | manual smoke — run before touching `ChatTransport.Codex` or `CodexAppServer`, or after a `codex` upgrade |
| `probe_opencode_server.exs` | CHAT_LIVE_STEERING Phase 0, probes 5–6: does `opencode serve` accept a prompt into a busy session, and can its API be trusted to report the fail-open agent fallback? Uses BOTH live API generations on purpose. Plain `elixir`. | manual smoke — run before touching `ChatTransport.Opencode` or `OpenCodeServer`, or after an `opencode` upgrade |
| `smoke_chat_steering.exs` | CHAT_LIVE_STEERING Phase 2 acceptance: an operator correction via `Chat.submit/3` reaches the SAME active Claude turn and changes the next model action, no process restart. `mix run`. | manual smoke — run before touching `BusterClaw.Agent.Chat` steering, turn references, or delivery modes |
| `smoke_chat_steering_codex.exs` | Phase 3 acceptance, the Codex counterpart: mid-turn steering AND conversation continuity through `Chat.submit/3`. The parity check the operator asked for. `mix run`. | manual smoke — run before touching the Codex chat path; it is one of the two real-CLI smokes that caught four defects the fakes could not |
| `smoke_chat_steering_opencode.exs` | Phase 4 acceptance, the OpenCode counterpart. Note: `prompt_async` returns an empty body, so `{:ok, :sent}` is a PASS for steering with a note about the receipt — read the tool calls to see whether the run changed course. `mix run`. | manual smoke — run before touching the OpenCode chat path; the other real-CLI smoke that caught defects the fakes could not |
