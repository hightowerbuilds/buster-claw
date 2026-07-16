# 07-15-2026 Summary

A build day across three surfaces: the terminal grew shader backgrounds with
custom palettes and learned to show them through a running TUI, the BusterPhone
roadmap got a real texting plan with the Twilio steps written out, and the
workspace tab got image preview and drag-and-drop (both inside the tree and from
the desktop).

## Terminal shader backgrounds + custom palettes (`b9a4390`)

The terminal background is now one active choice — off, an animated shader, or a
saved image — mirroring the homepage. `Appearance` gained a terminal background
*mode* resolved by `terminal_background/0` to a `%{kind, shader, source_url,
image_url, custom, colors}` struct, the single source of truth the terminal and
split views render from and the payload broadcast on the appearance topic.
Back-compatible: an existing active image slot with no saved mode still reads as
`:image`, so nobody's current background changes. Standalone terminals render a
hook-owned WebGPU canvas (the same `SmokeBackground` hook as the homepage) behind
the transparent xterm; a split paints one shader across the shared container so a
terminal/terminal split reads as one continuous field. Each shader also takes an
optional custom 3-color palette (Base/Accent/Highlight) with a live preview,
independent of the homepage's — the color storage is shared but keyed separately
so the two never bleed. `ShaderPreview` was parametrized with a color-input
prefix so the terminal's pickers drive the terminal preview, not the homepage's.

## TUIs show the background through them, not a black box (`77314a4`)

Operator report: Claude Code (and opencode) rendered a black rectangle over a
shader background, though images showed through fine. The transparent-background
strip that makes a TUI see-through only removed **pure black** background paint —
but these TUIs fill their surface with a near-black *neutral* (e.g.
`48;2;26;26;26`) that survived as opaque cells. Over a dark image that blends in
(so images "worked"); over a shader it read as black. Broadened the strip to
dark-and-roughly-neutral backgrounds (near-black RGB with low color spread, plus
the dark end of the 256-color grey ramp), while keeping clearly-colored
backgrounds — a teal Solarized base, a saturated selection — intact. 13 new bun
tests cover both sides plus chunk-split sequences.

## BusterPhone Phase 2 — the texting plan (`85d85b3`)

Rewrote the four-bullet SMS sketch in `BUSTERPHONE_ROADMAP.md` into a full plan
grounded in the current tree: what's already SMS-ready (schema `kind`/
`direction`, the `/phone` Texts tab, the trusted-numbers gate) vs the real gaps
(no Twilio REST client — the rotary dial is genuinely decorative; no `sms` edge
function; the drain is voicemail-only). Added the operator's seven-step Twilio
console checklist (brand + campaign registration, Messaging Service, webhook
wiring), the **Sole Proprietor** tier callout that could ship SMS without the
LLC (reversing the old "SMS forces the entity" assumption), and split the build
into 2A inbound (testable during campaign review) and 2B outbound — the app's
first money-spending, reach-a-stranger capability, so the `:restricted` tier and
usage caps ship *with* it, not after.

## Workspace tab: image preview + drag-and-drop (`9db4977`)

Three gaps closed in the file manager:

- **Image preview** (the reported bug). The pane called `read_file`, which caps
  at 1 MB and rejects binary, so every image wrongly hit "too large" / "binary."
  Images now serve as bytes via a new `/ws/image` route (revalidation cache,
  scoped to home or the workspace root) and render as an `<img>`. Verified
  against the running server: PNG serves as `image/png`, non-images and
  outside-home both 404.
- **Drag-to-move inside the tree.** File/folder rows are draggable; dropping onto
  a folder row moves it (`FileTreeDnd` hook → `drop_move` → `FileManager.move`),
  with a hover highlight. A private drag MIME keeps internal moves distinct from
  OS file drops; the client rejects no-ops and self/descendant moves, the server
  re-validates regardless.
- **Drag files from the OS desktop in.** Dropping from Finder imports into the
  folder in view via a LiveView auto-upload → `FileManager.import_file`, which
  name-dedupes (`photo.png` → `photo (1).png`, never an overwrite). Needed the
  Tauri main window's `dragDropEnabled:false` so OS drops reach the DOM — that
  one takes effect on the next desktop-shell restart.

## State of the tree

`mix precommit` green — **1014 tests**, 0 failures (988 → 1014 across the day's
Elixir work), plus **78 bun tests**. Everything above is committed and pushed to
main.
