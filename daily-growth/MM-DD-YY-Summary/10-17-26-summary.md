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

---

## Morning — Appearance on one screen

| | |
|---|---|
| (second commit) | **The page fits the window.** `Layouts.app fit_viewport` clamps the shell; the grid row is `minmax(0,1fr)` so three columns get exactly the room left, and each scrolls inside itself (`shrink-0` on the children, or a bounded flex column squashes a preview to nothing — it did). Column 1 is the catalog: filled images as small tiles four to a row with one "Add" tile standing for every free slot (the count says how many), then the shaders two to a row. Column 2 is Theme, then Terminal theme, both tightened. Column 3 is the Background and Clock previews (shorter — the preview is proof the setting took, not a wallpaper viewer) and the chat theme, whose transcript preview is clipped with a fade rather than shown whole. Empty image slots no longer render as placeholder tiles; the catalog description says the picker counts them instead. |

---

## Morning — two buttons, two modals

| | |
|---|---|
| (third commit) | **The catalog went behind two buttons.** Under the Background preview: **Images** and **Shaders**, the one whose half is in use outlined. Each opens a modal (`Catalog.catalog_modal/1`, `@picker`) with its half of the catalog — thumbnails with names and the Add tile and upload on one side, `off` plus every shader three to a row on the other. A pick raises the same `assign_background` the rows always did and closes the modal; a refused pick leaves it open with the flash; removing an image keeps it open (housekeeping, not a choice). Escape, the backdrop and × close it. With the catalog gone from the page, the first column is the current background with its selectors and controls, and the Clock under it, as asked; Theme and Terminal theme are the middle column; the chat theme has the third, with its transcript preview whole again. Tests open the picker first; three modal tests added; the handoff test opens Shaders before it clicks. Two caps banked (catalog 349→460, live 513→530). |

---

## Morning — Notify on one screen

| | |
|---|---|
| (fourth commit) | **The sound board tidied.** Every route is a row — label, sound menu, ▶, Test — in two columns of groups (Default, By kind, By source | Agent attention, Security, Chimes), with `fit_viewport` and no page scroll. The "Sounds on deck" library listing is gone: the sixteen bundled chimes are in every menu under a Built-in group, and only sounds the operator added appear, as chips with ▶ and × under the board, with the upload beside them. The menu's unset entry reads "Inherit · Bongos" (or "Auto · …" for Default), so what a row plays is read in the menu, not in a sentence beside it; `data-plays` carries the same for tests. A silent row's ▶ is disabled. The empty "Comms" group header that sat on the page for months is gone (`@columns` lists the groups that have rows). Tests: a new one asserts no library listing and a menu, ▶ and Test on every route; the others read `data-plays` and the selected option. |

---

## Morning — Your sounds as a file list

| | |
|---|---|
| (fifth commit) | **The chips became a file-explorer list.** Under the board, the operator's own sounds are a table — Name (with the filename beside it), Kind, Size, Modified, then ▶ and delete — with a sticky header in a box that scrolls on its own, so a long `sounds/` folder never pushes the board off the screen. One `File.stat` per row, local time, a vanished file reads as 0 B rather than crashing. The count and the upload sit on the row above it. |

---

## Morning — the sound list in three columns

| | |
|---|---|
| (sixth commit) | **Three columns, filenames only.** The operator asked for the list in three columns, then for the extra information to go: no kind, no size, no modified — the extension already says what a file is. A row is the filename, ▶ and delete; the list fills top to bottom then across (`columns/2`), in a box that scrolls on its own. The `File.stat` machinery from the previous commit went with the columns it fed. |

---

## Morning — the sound list reaches the bottom

| | |
|---|---|
| (seventh commit) | **No wasted space under the list.** The panel body is a flex column: the board keeps its own height and the Your sounds section takes everything left, its list box `flex-1` down to the panel's bottom edge instead of a fixed `max-h-40` that left the lower third of a tall window empty. |

---

## Late morning — Integrations deleted whole

| | |
|---|---|
| (eighth commit) | **Settings → Integrations is gone, and the code with it.** It was GitHub activity polling into Library markdown snapshots, with a secret-verified webhook, and it had not been touched in months of daily use; with MCP the route is not the one to take. Deleted: `BusterClaw.Integrations` and its five modules (GitHub adapter, Service behaviour, Snapshot, the two schemas), `IntegrationsLive`, the webhook controller, `Commands.Integrations`, its catalog entries (eight verbs; the catalog is 172 → 164 and the Explained stats say so), and four test files. Edited: the router (the live route and the webhook route, and with the webhook the endpoint's raw-body reader is gone too, with its test), the settings tabs, pane routes, tab-strip titles, the runtime status views, the CRUD auto-loop in `Commands`, the Clinch — `:service_key` now has no store (it listed integration tokens read-only; the kind stays because the enum is the contract) and the rekey walks one table fewer, which the rekey test's schema sweep now asserts — plus three JS path lists, the size gate, the dialyzer ignore list, and the four docs. A forward-only migration drops `integration_runs` and `integrations`. |

**Follow-up.** The operator's app reopened its remembered Settings tab on
`/integrations` and hit "no route found". `/integrations` now redirects to
Appearance (`LegacySettingsController`, beside `/cmd-list`), and the client's
retired-route recovery maps it the same way, so a remembered tab, a bookmark
and a restored window all land. One controller test and one JS test each.
(`StaplerRetryTest` failed once in the full run — a counter-file timing flake,
passes alone — and passed on the rerun.)
