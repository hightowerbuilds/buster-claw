# Quality

Run these checks before meaningful refactors.

## Phoenix

```sh
mix format
mix test
```

## Tauri

```sh
cd desktop/tauri
cargo check
```

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
