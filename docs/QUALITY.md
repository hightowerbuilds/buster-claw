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
