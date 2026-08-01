# 08-01-26 — One catalog, two surfaces

Settings → Appearance had two background pickers that didn't know about each
other: five image slots that only the terminal could use, one separate image
file that only the homepage could use, and the whole shader list rendered twice.
It is now **one catalog, shown once**, with a shared image pool either surface
can point at — and the two surfaces sit beside it as live previews of what they
are actually running.

One commit on main. Suite at close: 2052 tests, 110 JS, 34 Rust, credo strict
clean, `mix precommit` green. Five iterations on the layout, one feature built
and then deleted on operator testing.

## 1. The model: one pool, one grammar

The old storage was per-surface and it was the reason the UI had to be two
pickers. Terminal images lived in `terminal_background_<n>_path` (slots 1–5)
plus a `terminal_background_active` pointer; the homepage image lived in a
separate `home_background_image_path` with no slot at all. Nothing could be
shared, so nothing was.

Now there is one 8-slot pool (`background_image_<n>_path`) and **one mode
grammar for both surfaces**: `off`, a shader name, or `image:<n>`. Everything
below the API is written against a `@surfaces` config table — mode key, custom
key, colors key, topic, broadcast message, default — so there is one code path
and two configurations rather than two parallel implementations. The immediate
payoff: the same image can back the homepage and the terminal at once, which was
simply unrepresentable before.

Defaults differ per surface and that is deliberate: the homepage falls back to
`smoke`, the terminal to `off`. An empty homepage reads as broken; an empty
terminal reads as plain.

## 2. The migration rewrites settings, never files

`Appearance.ensure/0` runs at boot beside the other `ensure` calls, marker-
guarded and idempotent. Terminal slots keep their numbers; the homepage image
takes the first free slot; the old `"image"` mode plus its active-slot pointer
becomes an explicit `image:<n>`. An unset terminal mode with an active slot
still means image — that was the pre-shader install's implicit behavior and
dropping it would have silently cleared someone's background.

**It touches no files.** Only `Settings` keys are rewritten, so an image adopted
from the old layout keeps its old name on disk and simply answers to a pool slot
now. `clear_image/1` therefore deletes the file the slot actually points at,
then sweeps the canonical names — because a migrated slot's file is not named
what the current code would have named it. Both operations stay fenced to the
appearance dir by the existing containment guard.

Seven migration tests, including the fresh-install case that must migrate
nothing.

## 3. The blast radius that wasn't

`terminal_background/0` and `home_background_state/0` still return the exact
same shapes — `kind`, `mode`, `shader`, `source_url`, `image_url`, `custom`,
`colors`. The *stored* grammar changed; the *resolved* shape did not. So
`StatusLive`, `TerminalLive` and `SplitLive` needed **zero changes** despite
sitting directly on this data. Worth remembering as a shape: pick the seam at
the resolved value, not the storage, and a storage rewrite stops being a
cross-cutting change.

The controller collapsed to one route — `/appearance/image/:slot`. A slot isn't
owned by a surface any more, so a per-surface route had nothing left to mean.

## 4. Drag-and-drop: built, then cut

The first design was drag-a-tile-onto-a-surface, with a delegated hook modeled
on `file_tree_dnd.js` (private MIME type, one listener set on the section root,
`pushEvent` on drop) and click buttons as the accessible fallback. It worked,
it was tested, and on real use the operator's verdict was that HTML5 DnD "doesn't
work out so well" — which matches what this codebase already knows about
WKWebView and drag events (see `tab_strip.js`, which hit the same wall from the
`contextmenu` side).

So it was **removed entirely**, not disabled: the hook file deleted and
unregistered, the CSS drop states deleted, `draggable` / `data-bg-filled` /
`data-bg-surface` / the drop-hint overlay stripped from the markup, and every
line of copy that promised dragging rewritten. Verified `BackgroundDnd` is
absent from the built bundle.

The server contract never changed — `assign_background` was always the single
event behind both the drag and the buttons. Removing the drag removed a *caller*,
not behavior, and the buttons that remain were never a fallback bolted on; they
were the same path all along. That is the only reason the cut was cheap.

## 5. A shader is named, not pictured

Catalog tiles first painted a static gradient built from each shader's palette,
mirrored into Elixir from `assets/js/smoke/palettes.js`. Two problems: the
mirror was a drift risk I had to write a comment about, and the gradients were a
fiction — they are not what the shader looks like.

Cut. Shaders are now plain named rows; only images carry a thumbnail, because a
thumbnail is the only way to tell one image from another. The palette table went
with it, so the drift risk is gone rather than documented.

The reason there is no live canvas per row stands and is worth recording:
`createSmoke` requests its own adapter and device per canvas, so a gallery of
live previews means a GPU device per tile. Only the two surface panels animate —
the same count the old page had.

## 6. The layout, in four passes

Two columns: catalog left, the two surface panels stacked right. Then, in order:
previews capped with `max-h-40`; the themes moved *below* the backgrounds; images
and their upload zone moved *above* the shader list (the upload zone had to move
with the grid it feeds, or it would have been orphaned); shaders one per row.

The last pass was the interesting one. A fixed `lg:max-h-[30rem]` on the catalog
looked absurd next to a right column whose height varies with state — a surface
on a shader renders palette controls, one that's `off` doesn't. The fix is CSS
Grid's default `align-items: stretch`, but stretch alone would have done the
*opposite* of what was wanted: the row sizes to the tallest item's content, so a
long option list would have driven the height and the surfaces would have
stretched to match it.

So the catalog panel is taken **out of flow** — a `relative` wrapper is the grid
cell, and from `lg` up the panel is `absolute inset-0` inside it. The wrapper
contributes no content height, the row is sized purely by the two stacked
panels, and the panel fills exactly that. Out-of-flow is the whole trick.
Below `lg` nothing is positioned and the columns stack normally.

Equal heights made the sticky right column pointless; it came out.

## 7. Tests

Context tests went 344 → 481 lines, LiveView tests 56 → 268. Beyond the
migration set: one image backing both surfaces, surface independence, the
shaderface fence enforced at the boundary for *both* surfaces (not just the
picker), `option_key/1` round-tripping as the inverse of `set_background/2`,
removal degrading only the surfaces that were using a slot, and crafted events
naming an unknown surface or a non-numeric slot no-opping instead of crashing.

Two pre-existing helpers in `split_live_test` and `terminal_live_test` wrote the
legacy settings keys directly and had to move to the pool keys — the only places
outside Appearance that knew the old storage.

One test-only trap worth writing down: `Appearance.ensure/0` runs at application
boot and commits its marker to the test DB *before* the sandbox opens, so every
migration test started life already migrated. The fix is a `setup` that deletes
the marker inside the test's transaction. Any future boot-time `ensure` with a
persisted guard will hit this.

## 8. Open

**No visual pass was done.** Everything here is verified by the suite and by
reading the generated CSS (the arbitrary `calc()` normalization, and that
`lg:absolute`/`lg:inset-0` emit inside `@media (width >= 64rem)`), but the page
was never opened in a browser — the dev server is operator-run. The equal-height
grid behavior and the two live WebGPU previews sitting side by side are exactly
the kind of thing that reads fine in markup and surprises you on screen. First
launch should look at those two things.
