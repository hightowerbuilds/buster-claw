# 10-17-26 — One background

## Morning — the terminal stops being a surface

| | |
|---|---|
| (first commit) | **Backgrounds rebuilt around one background and the clock.** The Appearance page had three surfaces — Homepage, Terminal, Time & Place — and every catalog row carried three buttons. The terminal never needed one: a terminal in the Work Area sits on the Work Area's background, so a second setting was a second thing to keep in step. `Appearance.surfaces/0` is now `[:home, :widget]`, labelled **Background** and **Clock**. The catalog on the left is the background picker — a row IS the button, with an "In use" badge on the one running. The right column is the Background panel (live preview, overlay, custom colours) over the Clock panel, which carries a **Sky** `<select>` over the same catalog with "Day cycle (default)" first, since that sky has no catalog row and `default` is the only way back to it. Same `assign_background` event from both senders. The CLI was already there — `background_set surface=widget mode=…` — and its description now says what `home` and `widget` are. |

**What changed underneath.** `TerminalLive` subscribes to the app background
always, paints it itself only as a standalone tab, and is transparent whenever
something else paints the field: the Work Area (every slot, background on or
off) or a split. `SplitField` has one claimant — the app background, brought in
by a Home pane *or* a terminal pane; the "terminal field outranks home" branch
is gone, with the root attribute and the CSS rule that served it. `StatusLive`
and `SplitLive` dropped their terminal-topic subscriptions. The migration still
folds the five pre-pool terminal slots into the image pool (the images were
always the operator's) but no longer writes a terminal mode, and
`Migration.drop_terminal_surface/0` deletes the three dead keys on every boot —
three deletes beat a marker that outlives what it marks.

**Tests.** `appearance_test` gained a surfaces snapshot (`[:home, :widget]`,
the labels, and a check that `:terminal` is refused) and an every-boot key-drop
test; `commands/appearance_test`'s snapshot is `["home", "widget"]`; the
LiveView test covers the row-as-button, the Clock select (changes only the
clock, first entry is the sky, the clock's choice badges no row), and a crafted
`surface=terminal` event doing nothing; the terminal and split tests were
rewritten around the shared field (a standalone terminal paints the background
itself, runs its shader, is opaque when it is off, and follows a change live;
two joined terminals share one field with source `shared`). Three guards broken
on purpose: the key drop, the terminal pane bringing the field, the select
marking its selection — each failed, each passed restored.

Walked in Chrome on the dev app: the page, the badge, the Clock select, and the
Work Area with a terminal slot over the background.
