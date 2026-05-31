# Orchestration — Follow-ups / Leftovers (2026-05-31)

Phases 2–4 of the orchestration plan
(`05-31-26-orchestration-plan.md`) were implemented in one fan-out. Everything
compiles (Elixir suite 382/0; `cargo check` clean). The items below are
deliberately deferred or need a real-world pass.

## Resilience (Phase 2)

- **Crash-loop brake test** — the brake (stop shift after N consecutive raised
  ticks) is implemented and code-reviewed, but the unit test only covers the
  healthy path. Testing the trip path cleanly needs an **injectable failure
  seam** in `Orchestrator` (the DB-revocation approach fought the Ecto sandbox).
  Add a seam (e.g. an optional `tick_fun` in state) and assert the shift is
  stopped + a `:security_block` Sentinel event is written.
- **Real-mode agent tests are environment-dependent** — `agent_runner_test`'s
  timeout case uses `sleep`/`kill` and self-skips if absent. Fine on macOS/Linux
  CI; note for other environments.
- **Streaming vs. timeout** — the Port loop re-checks the wall-clock deadline on
  each heartbeat window, so a process emitting a continuous fast stream could
  delay the kill until output pauses. Intended trade-off (hung/runaway processes
  go quiet); revisit if a hard interrupt-regardless-of-output is wanted.
- **Sentinel double-count** — `Delivery` already emits an `:outbound_send` event
  per send; the `Reporter` adds its own alert-level `:outbound_send`. If
  duplicate audit rows are undesirable when destinations exist, drop the
  Reporter's explicit `Sentinel.observe`.

## Packaging / uptime (Phase 3)

- **No-sleep is app-lifetime, not shift-scoped** — the Tauri shell spawns
  `caffeinate -dimsu` for the whole app run. Tie it to shift start/stop (expose
  a Tauri command the home panel invokes on Start/Emergency-stop) so the machine
  can sleep when no shift is active.
- **launchd KeepAlive is unconditional** — `scripts/install_launchd.sh` installs
  a RunAtLoad + KeepAlive agent that always relaunches the app. Per the plan,
  install/load on shift start and unload on shift end (wire the install/uninstall
  halves from the Elixir side).
- **Respawn breaker assumes the release exits** — the Tauri respawn-on-exit
  monitor handles a release that *crashes*; a release that *hangs* is covered by
  the agent heartbeat/timeout layer, not this monitor.
- **`cargo tauri build` in a restricted sandbox** — `tauri-build`'s resource
  scan needs unrestricted filesystem access (it failed under the agent sandbox
  but `cargo check` passes locally). Run the full bundle build in a normal shell.
- **Real 12-hour dry-run** — not yet done. Build the `.app`
  (`scripts/build_desktop.sh`), install the launchd agent, start a shift, and
  confirm: survives a forced release kill, survives an app kill (relaunched by
  launchd), the machine stays awake, and the morning report lands.

## Panel / polish (Phase 4)

- **Vitals are present** (concurrency, runs/hour, done/failed today) in the home
  panel. Possible additions: token/$ budget tracking + cap (config key exists in
  spirit; not yet enforced), and a richer shift history / morning-report link in
  the panel.
- **Budget caps** — only concurrency and runs/hour are enforced today. A
  token/$ budget per shift (pause + alert on breach) is still open.
