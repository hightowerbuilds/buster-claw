# Leftovers — the shell

**Created 08-13**, when the whole-codebase review
([`CODE_REVIEW_08-13-26`](../../archive/CODE_REVIEW_08-13-26.html) §§8–9) produced the
first item list for the JS and Rust layers — the two layers the size gate does
not cover. Same rules as the sibling LEFTOVERS files: everything here is
concrete, blocks nothing, and is deferred on purpose. The review's shell-side
fixes that could land same-day did (`577085e`: the two dead Trading hooks
deleted, the hook guard made bidirectional); these are the rest.

Covers [Supermap](../SUPERMAP.md) Part I, plus the Tauri shell beneath it.

---

### `tab_strip.js` (664) — the overloaded one, sitting on the most fragile seam

Three cohabiting jobs: the tab strip proper; split-tab/surface reconciliation —
the JS half of the Rust surface lifecycle (the mount-order coupling
`browser_agent_mode_surface_coupling` records), whose
`joinTabs`/`swapSides`/`separateTabs` have **no bun tests**, unlike everything
else in `lib/`; and a bespoke ~150-line context menu. Extract
`lib/split_tabs.js` (mostly pure path/param manipulation, immediately testable)
and the menu module; ~500 lines after. Separately, `showCloseConfirm`
(`:617–649`) re-implements `lib/claw_confirm.js`'s modal because claw_confirm
is click-interception-shaped and this caller is promise-shaped — `clawConfirm`
is already a promise internally; export it and delete the copy.

---

### `chrome.js` (864) — three UIs share one bar

The find bar (`:467–533`) and omnibox suggestions (`:375–454`) coordinate with
the bookmark bar through flags; each extracts to a `lib/` module with a small
"who owns the bar" arbiter. Also: the ⌘-digit tab-shortcut convention
(`/^tab_([1-9])$/` + ⌘9 = last tab) is implemented three times
(`chrome.js:314`, `tab_strip.js:78`, `tab_strip.js:579`) with nothing
asserting they agree.

---

### The one cross-language seam with no guard

The Rust→chrome contract (`window.__on*`, `__agent*`, `__menuShortcut`) is
stringly-typed across two languages — the same fragility class as phx-hook,
which now has a two-direction lockstep test, while this has none. A grep-based
test asserting every name emitted from `notify.rs`/`webviews.rs` appears in
`chrome.js` is cheap and in-house style. Remember the 08-08 lesson before
writing it: a `~H` template is a heredoc — any comment-skipping must not
swallow it.

---

### Rust tail — the 07-22 shape holds (tests 34 → 39); these are dated nits

- `browser_find_count` embeds the **only** injected page-script living outside
  `js.rs` (`mod.rs:377–386`) — safe today via `js_str`, but outside the
  escaping test suite and invisible to the purity guard. Move it in as
  `find_count_js(query)` with a test.
- `browser_wait_active` blocks async-executor threads with `thread::sleep`
  polling (`mod.rs:712, 729` — up to 30 s of 250 ms sleeps), as does
  `render_settle_and_read` in `webviews.rs`. Harmless with one agent driving
  one browser; `tokio::time::sleep(...).await` is the correct shape.
- `main.rs:600–606` calls `env::set_var` after threads may exist — becomes
  `unsafe` in Rust 2024. Know it before a toolchain bump.
- `state.rs`'s poison-recovery incantation
  (`lock().unwrap_or_else(|e| e.into_inner())`) appears ~20 times; one private
  helper halves the noise. Cosmetic only.

---

### `terminal_theme.ex` (859) — the seams for next growth

Cap-as-is now (HELD 880 in the review's proposed inventory); when it next
needs room, the legibility floor (~130 lines, exactly one internal caller) is
`TerminalTheme.Legibility` and the HSL generator (~120) is
`TerminalTheme.Spectrum`. Known pair to watch: the hex normalizer here
*refuses* while `appearance.ex`'s silently coerces to `#000000` — divergent
failure modes, and the file's own comment already rules that a third copy
should force a shared module.

---

## The rule for this file

Same as its siblings: an item leaves by being done or by being promoted to a
real roadmap — never by being forgotten. Anything that grows a design question
is promoted, not expanded in place.
