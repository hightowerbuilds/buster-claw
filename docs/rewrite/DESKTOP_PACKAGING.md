# Desktop Packaging Path

Packaging target: local Phoenix release on `127.0.0.1`, opened by a thin desktop shell.

Selected wrapper:

- macOS first: Tauri.
- Keep Phoenix as the app runtime instead of rewriting LiveView screens into native UI.
- Bundle the Erlang runtime through a Mix release.
- Store SQLite and Library data under a stable user data directory.
- Keep the browser sidecar optional until the Playwright path is hardened.

Current development shell:

- `desktop/tauri` contains the Tauri v2 wrapper.
- `cargo tauri dev` opens `http://127.0.0.1:4000`.
- Phoenix still needs to be started separately with `mix phx.server`.

Release requirements:

- Build assets with `mix assets.deploy`.
- Build release with `MIX_ENV=prod mix release`.
- Configure host binding to `127.0.0.1`.
- Use a configured or randomly assigned local port.
- Launch the webview only after the endpoint health check passes.
- Shut down the BEAM runtime when the shell exits.

Deferred hardening:

- macOS notarization/signing.
- Windows and Linux installers.
- Bundled Playwright browser dependencies.
- Log rotation and crash report collection.
