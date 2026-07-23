# Quality

Run these checks before meaningful refactors. `mix precommit` runs the Phoenix
gate and the Tauri gate together.

## Phoenix

```sh
mix format
mix test
```

## Tauri

```sh
./scripts/check_rust.sh
```

Formats (`cargo fmt --check`), lints (`cargo clippy -D warnings`), and tests —
including `tests/acl_lockstep.rs`, which cross-checks `generate_handler!`,
`build.rs`, and `capabilities/*.json` so a command can't silently die in the
packaged app (the 07-17 co-presence bug, the 07-21 speak bug). The same script
runs as the `rust` job in CI. Toolchain pinned by `desktop/tauri/rust-toolchain.toml`.

## JS

```sh
bun test assets/js
```

Pure-logic tests (URL heuristics, ANSI parsing, tab state). Runs as the `js`
job in CI.

## Packaged app (pre-release)

```sh
./scripts/build_desktop.sh && ./scripts/smoke_desktop.sh
```

Launches the real .app (or attaches to a running one) and drives the HTTP API
from outside: health, catalog, auth, a bridge round-trip, and a hidden-webview
live render that returns real page text — the only check that exercises
production ACL resolution end-to-end (`tests/acl_lockstep.rs` is the static
half). `SMOKE_OFFLINE=1` skips the render when there is no network. Manual,
before a release — not per-PR.

For desktop testing, use the single-command launcher (boots Phoenix, waits for `/_health`, then opens the Tauri window):

```sh
./scripts/dev.sh
```

Manual fallback — run Phoenix and the shell in separate terminals:

```sh
mix phx.server
```

```sh
cd desktop/tauri
cargo tauri dev
```

## Notes

- Keep generated Phoenix build artifacts, SQLite files, and Tauri `target/` out of source control.
- Treat `Library/` and root legacy data files as local runtime/migration data, not application source.
