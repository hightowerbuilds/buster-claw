# Building Buster Claw from source

Buster Claw packages as a macOS `.app`/`.dmg`: a Tauri (Rust) shell wrapping a
Phoenix release with bundled ERTS. This page builds it locally from a clone.

The result is **unsigned** — fine for running on your own machine (see
[Opening an unsigned build](#opening-an-unsigned-build)). Signed, notarized
downloads for non-developers are a separate distribution channel.

## Prerequisites

macOS only (the bundle targets `.app`/`.dmg`). Xcode Command Line Tools are
needed for the Rust/Tauri build:

```bash
xcode-select --install
```

Known-good toolchain versions are pinned in [`.tool-versions`](.tool-versions).
With [asdf](https://asdf-vm.com), `asdf install` from the repo root matches them.
Rust is managed by [rustup](https://rustup.rs).

| Tool | Version | Install |
|------|---------|---------|
| Erlang/OTP | 28.4.2 | `asdf install` |
| Elixir | 1.19.5 (OTP 28) | `asdf install` |
| Node.js | 26.x | `asdf install` |
| Rust | 1.94+ | https://rustup.rs |
| Tauri CLI | 2.x | `cargo install tauri-cli` |

## Build

```bash
git clone <repo-url> buster-claw
cd buster-claw
./scripts/build_desktop.sh
```

`build_desktop.sh` preflights your toolchain (failing early with install hints if
anything is missing), syncs the version, installs JS deps (`npm ci`), builds the
Phoenix release + production assets, and runs `cargo tauri build`. The first
build compiles the Rust shell and bundles ERTS — expect several minutes.

## Output

| Artifact | Path |
|----------|------|
| App | `desktop/tauri/target/release/bundle/macos/Buster Claw.app` |
| Installer | `desktop/tauri/target/release/bundle/dmg/Buster Claw_<version>_<arch>.dmg` |

Open the `.app` directly, or open the `.dmg` to drag it into `/Applications`.

## Opening an unsigned build

A locally-built app is not signed by Apple, so Gatekeeper blocks the first
launch ("Apple could not verify…"). Either:

- **Right-click** the app → **Open** → **Open** (one-time per build), or
- Strip the quarantine attribute:

  ```bash
  xattr -dr com.apple.quarantine "/Applications/Buster Claw.app"
  ```

## First run

No `.env` or manual setup needed — the app self-configures on first launch:

- Creates its SQLite database and workspace under
  `~/Library/Application Support/BusterClaw/`.
- Generates the master key (`SECRET_KEY_BASE`) and loopback API tokens in your
  **macOS Keychain** (service `BusterClaw`).
- Runs database migrations.

See [`docs/DESKTOP_PACKAGING.md`](docs/DESKTOP_PACKAGING.md) for the full runtime
layout. Back up the master key from **Settings → Recovery key** so you can move
the install to another machine.

## Versioning

The root [`VERSION`](VERSION) file is the single source of truth. Edit it, and
`scripts/sync_version.sh` (run automatically by the build) propagates it into
`desktop/tauri/tauri.conf.json` and `desktop/tauri/Cargo.toml`.

## Troubleshooting

| Symptom | Fix |
|---------|-----|
| Preflight reports a missing tool | Install it per the table above; `.tool-versions` + `asdf install` covers Erlang/Elixir/Node. |
| `cargo tauri` not found | `cargo install tauri-cli` |
| `npm ci` fails | Ensure Node 26.x; remove `assets/node_modules` and retry. |
| "release binary not found" from the shell | Re-run `./scripts/build_desktop.sh` — it stages the release into `desktop/tauri/resources/release/`. |
| App opens to an error screen | Check `~/Library/Application Support/BusterClaw/logs/release.stderr.log`. |
| A newly built app shows an **old UI** | All builds share the bundle id `lol.busterclaw.desktop`, so they share one webview cache. Quit the app and clear it: `rm -rf ~/Library/WebKit/lol.busterclaw.desktop ~/Library/Caches/lol.busterclaw.desktop` (this does **not** touch app data in `~/Library/Application Support/BusterClaw/`). |
| `cargo tauri dev` fails with `failed to run tauri-build: Permission denied` | A prior `build_desktop.sh` staged the full ERTS release into `desktop/tauri/resources/release/`, which `tauri-build` chokes on while scanning. Dev doesn't need it — clear it: `find desktop/tauri/resources/release -mindepth 1 -not -name .gitkeep -delete`. `scripts/dev.sh` now does this automatically before launching. |
