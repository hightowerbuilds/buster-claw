# 06-16-2026 Summary

A terminal-polish day: fixed the in-app terminal's edge padding, made the command
cheat-sheet tolerate label-less entries, and — the main work — optimized the
xterm.js + PTY stack so TUIs like Claude Code and Codex render cleanly under load
instead of drifting out of alignment while "thinking."

## Terminal padding (`terminal_live.ex`)

- The xterm host div applied `p-2` only in the standalone branch; when **embedded**
  (the Tauri desktop window) it got bare `h-full`, so characters ran flush to the
  window edge. Made the padding unconditional and bumped it `p-2 → p-3` (12 px).
  The `ResizeObserver`/`FitAddon` recompute cols/rows on the smaller area, so no
  manual refit is needed.

## Command cheat-sheet: label-less commands (`terminal_commands.ex`, `terminal_live.ex`)

- The `welcome-introduction` entry is now bare prompt text (no `:label`/
  `:description`). The cheat-sheet template assumed both keys existed and would
  crash rendering. Switched to `command[:label]` access with `:if` guards and a
  conditional `mt-3` so a label-less command renders as just its prompt.
- Regression test in `terminal_live_test.exs` asserts the label-less command
  renders without crashing the panel. (12 tests, 0 failures.)

## Terminal optimized for TUIs (the main work)

Diagnosed why lines drift out of alignment specifically while Claude is thinking +
the screen scrolls. Three real causes across the JS hook and the Rust PTY reader;
all four fixes landed.

- **WebGL renderer** (`assets/js/app.js`, new `@xterm/addon-webgl` dep). xterm 6.0
  defaults to the DOM renderer (only `addon-fit` was installed), which tears and
  misaligns under a TUI's rapid full-screen redraws. Now loads the GPU WebGL
  renderer, which draws the whole cell grid to a canvas cell-accurately, with a
  silent **fall back to the DOM renderer** if WebGL is unavailable or its context
  is lost (`onContextLoss` → dispose). Added `allowProposedApi: true` for the
  renderer's glyph-atlas cache.
- **Font-ready gate.** `term.open()` + `fit()` ran on mount before the self-hosted
  `IBM Plex Mono` had loaded, so xterm measured the **fallback** font's cell width;
  when Plex swapped in, its different glyph advance drifted characters out of their
  cells on long lines. Now `await document.fonts.ready` (capped at 600 ms so a
  stalled FontFaceSet can't hang the terminal) before opening.
- **Debounced resize.** The `ResizeObserver` fit()/PTY-resize now coalesces to one
  call per frame via `requestAnimationFrame` (cancelled on unmount), so xterm and
  the PTY never briefly disagree on cols/rows mid-redraw.
- **UTF-8 boundary buffering** (`desktop/tauri/src/terminal.rs`). The reader thread
  decoded each 4 KB read with `String::from_utf8_lossy` independently, so any
  multi-byte sequence straddling a read boundary — 3-byte box-drawing glyphs
  (`│ ─ ╭ ╮`, heavily used by Claude's TUI) and emoji — became `�` with wrong cell
  widths. Now emits the longest valid UTF-8 prefix and carries an incomplete
  trailing sequence into the next read; genuinely-invalid mid-stream bytes still
  flush lossily so the stream can't wedge. Scrollback still stores raw bytes.

## Distribution roadmap — Google verification correction (carried in this commit)

- `06-14-26-distribution-roadmap.md` (F2): corrected the OAuth-verification cost
  model. The restricted Gmail scopes (`gmail.readonly` + `gmail.compose`) need
  **OAuth/brand verification but very likely NOT the $15k–75k/yr CASA security
  assessment** — Google exempts purely client-side/desktop apps that access only
  local on-device data, which is Buster Claw's posture (loopback Phoenix, Keychain
  tokens, local SQLite, on-device PKCE). Re-scoped the timeline to **weeks/~free**;
  gating prerequisite remains a domain (privacy-policy + authorized-domain URLs).

## Verification

- `mix test test/buster_claw_web/live/terminal_live_test.exs
  test/buster_claw/terminal_commands_test.exs` — 12 tests, 0 failures.
- `mix assets.build` clean (app.js bundles with the WebGL addon, 956 kb).
- UTF-8 carry algorithm validated standalone with `rustc`: box-drawing + emoji
  reassemble exactly when fed byte-by-byte (worst-case split), and invalid bytes
  don't wedge the stream.
- Could not `cargo check` the Tauri crate in this environment — `tauri_build`
  hits a filesystem-permission error scanning the bundled `resources/release/`
  tree (environmental, before the source compiles). Builds normally via
  `./scripts/dev.sh` / `cargo tauri dev`.

## Notes

- The Rust UTF-8 fix needs a desktop rebuild (`./scripts/dev.sh`) to take effect;
  the JS changes ship with the asset bundle.
- New dependency: `@xterm/addon-webgl@0.19.0` (matches xterm 6.0), recorded in
  `assets/package.json` + lockfile.
