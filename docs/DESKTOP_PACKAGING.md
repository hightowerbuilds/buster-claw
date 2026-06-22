# Desktop Packaging

Buster Claw packages as a single macOS `.app` containing the Tauri shell, a Mix release with bundled ERTS, and the Phoenix runtime. The shell spawns the release as a child process on launch and tears it down on quit.

## Build

```bash
./scripts/build_desktop.sh
```

That script:

1. Preflights the toolchain and syncs the version from `VERSION`.
2. Fetches prod dependencies (`MIX_ENV=prod mix deps.get`).
3. Installs JS dependencies (`cd assets && npm ci` — esbuild bundles `@xterm/*` from there).
4. Builds production assets (`MIX_ENV=prod mix assets.deploy` — tailwind, esbuild, digest).
5. Assembles the Mix release (`MIX_ENV=prod mix release --overwrite`).
6. Stages the release into `desktop/tauri/resources/release/` (gitignored).
7. Runs `cargo tauri build` to produce the `.app` and `.dmg`.

See [`../BUILD.md`](../BUILD.md) for prerequisites and a clone-to-`.dmg` walkthrough.

### Voice (STT) model bundle

Voice input transcribes on-device with a bundled whisper.cpp model
(`ggml-base.en.bin`, ~142MB), so the bundle is **~150MB larger** when voice is
built in. The model is fetched, not committed — run `./scripts/fetch_whisper_model.sh`
once before building. It lands in `desktop/tauri/resources/models/` (mapped into
the bundle as `Contents/Resources/models/`), a stable mapping kept separate from
the volatile `resources/release/` staging dir. The shell resolves it at runtime
via `resolve_voice_model` in `main.rs`. Microphone access needs the
`NSMicrophoneUsageDescription` string (`Info.plist`) and the
`com.apple.security.device.audio-input` entitlement (`Entitlements.plist`,
referenced from `tauri.conf.json`); both ride the Apple-signing critical path.

Outputs:

- `desktop/tauri/target/release/bundle/macos/Buster Claw.app`
- `desktop/tauri/target/release/bundle/dmg/Buster Claw_<version>_<arch>.dmg`

## Runtime layout

The Tauri shell (`desktop/tauri/src/main.rs`) performs the following on launch:

1. Resolves the user data directory to `~/Library/Application Support/BusterClaw/`.
2. Ensures the data dir and `logs/` exist. (The workspace library/sources/etc. live under the user-chosen workspace root, not the data dir.)
3. Reads or generates the master key (`SECRET_KEY_BASE`) and the loopback API tokens in the **macOS Keychain** (service `BusterClaw`) — migrating any legacy plaintext files into the Keychain, and adopting a `RESTORE_SECRET_KEY` recovery file if the user dropped one in the data dir.
4. Picks a free TCP port via `portpicker`.
5. Spawns the bundled release at `Contents/Resources/release/bin/buster_claw start` with:
   - `PHX_SERVER=true`
   - `PORT=<chosen port>`
   - `DATABASE_PATH=<data_dir>/buster_claw.db`
   - `BUSTER_CLAW_WORKSPACE_ROOT=<workspace root>`
   - `SECRET_KEY_BASE=<key from Keychain>`
   - `BUSTER_CLAW_API_TOKEN=<token from Keychain>`
   - `BUSTER_CLAW_MCP_API_TOKEN=<token from Keychain>`
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
└── logs/
    ├── release.stdout.log  # BEAM stdout (append-only across launches)
    └── release.stderr.log  # BEAM stderr
```

The master key and API tokens are **not** here — they live in the macOS Keychain
(service `BusterClaw`). Workspace documents live under the user-chosen workspace
root (its own tree of `library/`, `sources/`, `memory/`, etc.), not the data dir.

Deleting the data directory resets app state but leaves the Keychain entries; to
fully reset, also remove the `BusterClaw` Keychain items. Conversely, losing the
Keychain entry without a backed-up recovery key makes encrypted secrets
unrecoverable — back the key up from **Settings → Recovery key**.

## Deferred hardening

- macOS code signing and notarization — planned for the website download channel (see the distribution roadmap, Channel B).
- Windows and Linux installers (the runtime and Tauri config support them; only build/test paths are missing).
- Bundled Playwright browser dependencies.
- Log rotation and crash report collection.
- Auto-update mechanism — intentionally out of scope for v1 (users re-download the latest `.dmg`).
- Dock/app menu customization.
