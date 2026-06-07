# Desktop Packaging

Buster Claw packages as a single macOS `.app` containing the Tauri shell, a Mix release with bundled ERTS, and the Phoenix runtime. The shell spawns the release as a child process on launch and tears it down on quit.

## Build

```bash
./scripts/build_desktop.sh
```

That script:

1. Fetches prod dependencies (`MIX_ENV=prod mix deps.get`).
2. Builds production assets (`MIX_ENV=prod mix assets.deploy` — tailwind, esbuild, digest).
3. Assembles the Mix release (`MIX_ENV=prod mix release --overwrite`).
4. Stages the release into `desktop/tauri/resources/release/` (gitignored).
5. Runs `cargo tauri build` to produce the `.app` and `.dmg`.

Outputs:

- `desktop/tauri/target/release/bundle/macos/Buster Claw.app`
- `desktop/tauri/target/release/bundle/dmg/Buster Claw_<version>_<arch>.dmg`

## Runtime layout

The Tauri shell (`desktop/tauri/src/main.rs`) performs the following on launch:

1. Resolves the user data directory to `~/Library/Application Support/BusterClaw/`.
2. Ensures `Library/raw/`, `Library/reports/`, and `logs/` exist.
3. Reads or generates `secret_key_base` (64 alphanumeric chars) and persists it.
4. Picks a free TCP port via `portpicker`.
5. Spawns the bundled release at `Contents/Resources/release/bin/buster_claw start` with:
   - `PHX_SERVER=true`
   - `PORT=<chosen port>`
   - `DATABASE_PATH=<data_dir>/buster_claw.db`
   - `BUSTER_CLAW_LIBRARY_ROOT=<data_dir>/Library`
   - `SECRET_KEY_BASE=<persisted key>`
   - `RELEASE_DISTRIBUTION=none`
6. Redirects child stdout/stderr to `<data_dir>/logs/release.{stdout,stderr}.log`.
7. Polls `http://127.0.0.1:<port>/_health` (250 ms interval, 30 s timeout).
8. On healthy: navigates the (initially hidden) webview to the Phoenix URL and shows the window.
9. On timeout: navigates to a bundled `error.html` pointing the user at the log path.
10. On app `RunEvent::Exit`: sends `SIGTERM` to the child, waits up to 5 s, then `SIGKILL`.

The Phoenix release binds to `127.0.0.1` only and uses plain HTTP; SSL is unnecessary because all traffic stays on loopback inside the desktop process.

## User data directory

```
~/Library/Application Support/BusterClaw/
├── buster_claw.db          # SQLite (configuration + workflow state)
├── secret_key_base         # 64 chars, generated once on first launch
├── Library/
│   ├── raw/                # Ingested markdown documents
│   └── reports/            # Generated analysis reports
└── logs/
    ├── release.stdout.log  # BEAM stdout (append-only across launches)
    └── release.stderr.log  # BEAM stderr
```

Deleting this directory resets the app to a fresh-install state.

## Deferred hardening

- macOS code signing and notarization.
- Windows and Linux installers (the runtime and Tauri config support them; only build/test paths are missing).
- Bundled Playwright browser dependencies.
- Log rotation and crash report collection.
- Auto-update mechanism.
- Dock/app menu customization.
