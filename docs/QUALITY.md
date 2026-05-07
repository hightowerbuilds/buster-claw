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

For manual desktop testing:

```sh
mix phx.server
```

Then in another terminal:

```sh
cd desktop/tauri
cargo tauri dev
```

## Notes

- Keep generated Phoenix build artifacts, SQLite files, and Tauri `target/` out of source control.
- Treat `Library/` and root legacy data files as local runtime/migration data, not application source.
