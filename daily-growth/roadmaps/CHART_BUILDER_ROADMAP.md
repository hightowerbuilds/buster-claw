# Chart Builder — a fourth kind of trading tab

**Scoped 08-02-26 · Status: ACTIVE — Phases 0–3 complete (built 08-02-26;
palette reconciled against the `dataviz` method 08-03-26). Phase 4 unstarted.**

A new Trading tab kind, **Chart Build**, alongside Chat / Robinhood / Research.
It opens with a **chart preview above a chat**: you describe the chart you want,
the model builds it, it appears above the conversation, and you iterate by
talking. The model is taught to do this by a **reference skill** — the same
runtime-loadable mechanism that already teaches shader authoring.

**Why it fits here:** the Trading page is already a strip of *typed*
conversations where the type decides what the chat can reach. A fourth type is
the established way to add a capability without widening the other three. And
the app already has every piece this needs — an SVG channel from chat, a
server-side chart engine, a skills layer, and cached market data — so most of
this roadmap is assembly, not invention.

---

## The lay of the land (read before building)

**The tab system is a well-trodden path.** A `kind` is a string that appears in
a small, findable set of places: `@tab_kinds` (`trading.ex:51`), `kind_label/1`,
`kind_badge/1`, `chat_opts_for/1`, two `kind in [...]` guards in `TradingLive`
(`trading_new_tab` ~L174, `trading_set_kind` ~L290), and the badge colour in
`TradingTabStrip` (today a binary research-or-not conditional — a third colour
means it becomes a real function). `Conversations` stores `kind` per row;
`docked` is set false for kinds that own a data panel, which Chart Build does.

**The SVG-from-chat channel already exists and is hardened.** `BusterClaw.SvgViewer`
extracts fenced ```` ```svg ```` blocks from assistant text (`extract/1`, fail-closed,
100 KB cap), strips scripts/handlers/`<foreignObject>`/external refs
(`sanitize/1`), and `guide/0` is the system-prompt appendix that teaches a model
to emit them. The enforced CSP (`script-src 'self' 'nonce-…'`) is the real
backstop. The homepage already renders these beside its chat, with a zoom modal.
**This is the whole delivery mechanism, already shipped and already trusted.**

**There is already a house chart engine**, and its moduledoc states the doctrine:
*"Server-rendered SVG. No charting dependency: the data already lives on the
server, LiveView already re-renders, and the CSP forbids fetching a library
anyway."* `PortfolioChart` (996 lines) also encodes two honesty rules worth
stealing wholesale: **zero is always in frame**, and **gaps are gaps** (a real
date scale, with segments broken across missing days rather than a line drawn
through days nobody measured). The operator declined `lightweight-charts` on
07-28 — **do not re-propose a JS charting library.**

**Reference skills are the right skill mechanism, with a precedent to copy.**
`BusterClaw.Skills` supports `handler_kind: reference` — "a playbook the agent
*reads* (no steps; the markdown body is the payload) to do an authoring task the
command surface doesn't cover, **e.g. designing a homepage shader pattern**."
`skills/shader-designer.md` is the worked example: frontmatter, hard constraints,
the contract, then shipped examples. Skills are discovered at runtime — no
recompile — and are operator-editable and git-diffable.

**The cost model is the constraint nobody should discover the hard way.** Every
broker read is one CLI run (~cents, **28s–213s measured, ~1-in-6 flaky**). The
Trading tab's design principle is *tab open = zero runs (all cache)*. A chart
builder that fires a live broker read on every iteration would be slow, flaky,
and expensive. See `roadmaps/archive/` and the trading-tab notes.

---

# Part I — The design question: how does a model produce a chart?

**Decide this before building. Everything else follows from it.**

### (A) Freehand SVG — the model writes the markup

The model emits ```` ```svg ```` and we render it. **Cost to build: nearly zero** —
the channel, the sanitizer, the renderer, and the system-prompt guide all exist.
Maximum expressive range: anything drawable is drawable.

**The risk is not security — it's arithmetic.** `sanitize/1` plus the CSP handle
the injection surface. What they cannot check is whether the picture is *true*: a
language model computing pixel geometry can draw a bar chart whose bar heights
don't match its own numbers, an axis that silently starts at 40 instead of 0, or
a smooth line across a three-week hole in the data. It renders crisply and looks
authoritative either way. On a **trading** page, a subtly wrong chart is worse
than no chart.

### (B) A chart spec — the model emits JSON, we draw it

The model emits a bounded spec (```` ```chart ````: type, series, axes, labels,
title) and the app renders it server-side with the same SVG machinery
`PortfolioChart` already uses. **The app owns the geometry, so the honesty rules
are enforced by construction** — zero in frame, gaps as gaps, axis labels derived
from the data rather than asserted by the model. It is also far cheaper to
validate: a spec either parses or it doesn't.

**Cost:** a spec format, a validator, and a renderer per chart type — a real
build. And the chart vocabulary is capped at what we implement, so "draw me a
Sankey of my sector flows" is simply unavailable.

### (C) Hybrid — spec first, freehand as the labelled escape hatch

Standard chart types (line, bar, scatter, candle, pie) go through the spec and
get the honesty guarantees. Anything genuinely bespoke — an annotated diagram, an
unusual visualization — falls back to freehand SVG **and is visibly labelled as
drawn rather than computed**, so the user knows which trust class they're looking
at.

## Recommendation: (C), reached by shipping (A) first

Ship **(A)** in Phase 1 because it costs almost nothing and proves the entire
UX — the tab, the preview pane, the iteration loop, the skill — with real use.
Then add **(B)** in Phase 3 for the standard types, once actual sessions have
shown which charts people ask for and where freehand drawing goes wrong. The
label from (C) arrives with (B).

Shipping (A) first is not a shortcut; it is how we learn which specs are worth
writing. The one thing (A) must carry from day one is **the label** — a
freehand chart says so, always.

---

# Part II — The canvas question, answered

**Verdict: no. SVG for rendering; canvas earns a narrow role in export only.**

**Canvas cannot be authored declaratively.** A `<canvas>` is inert markup; pixels
appear only when JavaScript calls into a 2D context. So "the model builds a
canvas chart" means the model produces **executable JavaScript**, which then has
to run in the webview. Three ways that could go, all bad:

1. **Inject the model's JS into the DOM** — refused by the enforced CSP
   (`script-src 'self' 'nonce-…'`). It would not run.
2. **Weaken the CSP / add `unsafe-eval` and `eval()` it** — this is building a
   remote-code-execution channel for language-model output *inside the app that
   holds the user's logged-in browser session, brokerage reads, and email*. The
   CSP is the backstop the entire SVG channel is trusted on. Not a trade we make.
3. **Have the model emit a safe declarative spec that our own bundled JS turns
   into canvas draw calls** — tenable, but notice what happened: the model is no
   longer writing a chart, it's filling in a schema we designed, and we're
   writing the renderer. That is **option (B) above**, and once you're there,
   rendering it as server-side SVG is strictly less work than shipping a
   client-side canvas renderer, because `PortfolioChart` is already that engine.

**And canvas's real advantages don't apply at this data scale.** Canvas wins on
tens of thousands of points, pixel effects, and high-frequency redraw. Trading
payloads here are bounded to ~260 rows by design. We would be paying canvas's
costs for none of its benefits.

**Where canvas *is* legitimately useful: export.** Rasterizing a finished SVG to
PNG (draw the SVG into a canvas via a blob URL, `toDataURL`) is the standard way
to produce a shareable image — and `img-src` already allows `data:` and `blob:`.
That's a small, contained, *our-code-only* use with no model output involved.
Park it in Phase 4 as a nice-to-have; it does not change the rendering decision.

**Also note:** this keeps the tab **model-agnostic**. Emitting markup or JSON is
something any model can do, so Chart Build is not Claude-locked the way the
broker tabs are (codex chokes on the MCP flags). That is an argument for feeding
charts from *our* cached data rather than live MCP reads — see Part III.

---

# Part III — Where the data comes from

Three sources, in increasing cost. The tab should prefer the cheapest that answers.

1. **The app's own cache — free, instant, and the default.** `MarketData` (daily
   closes, quotes, indexes, earnings) and the `Portfolio` ledger (the only
   portfolio-value history that exists) are already on the server. A chart drawn
   from these costs **zero agent runs**, which preserves the tab-open-is-free
   principle. **Phase 2 exists to make this data reachable from the chat.**
2. **The conversation itself** — numbers the user pastes or describes. Free, and
   the natural path for "chart these five figures."
3. **A live broker read** — expensive and flaky (see the cost model). Opt-in,
   never automatic, and never on iteration. If a chart needs fresh broker data,
   the tab should say so and let the user ask for it explicitly.

Open sub-question for Phase 2: does the Chart Build chat get broker read tools at
all, or only the cached-data commands? **Recommend cached-only** to start — it
keeps the tab cheap, fast, model-agnostic, and outside the broker blast radius,
and nothing about drawing a chart requires a live quote.

---

# Phase 0 — Decide

- [x] Part I: confirmed (C)-via-(A): freehand SVG first, validated specs later.
- [x] Part III: cached-data-only chat; no broker reads or other agent tools.
- [x] Name it. `chartbuild` is the persisted kind string; **"Chart
      Build"** as the label and **`CHART`** as the badge unless the operator
      prefers otherwise. Locked 08-02-26.

# Phase 1 — The tab, the preview, and the loop

*The whole feature end to end on the existing SVG channel. Shippable alone.*

- [x] Add the kind everywhere it lives: `@tab_kinds`, `kind_label/1`,
      `kind_badge/1`, `chat_opts_for/1`, both `TradingLive` guards, and the tab
      strip badge colour (which becomes a real function, not a binary
      conditional). A test asserting `tab_kinds/0` and the guards agree — the
      kind list is exactly the sort of thing that drifts across six sites.
- [x] `chat_opts_for("chartbuild")`: the chart-authoring system prompt
      (modelled on `SvgViewer.guide/0`), plus whatever Phase 0 decides about
      data tools. **No broker write tool, ever** — same rule as every other kind.
- [x] The panel: **chart preview above, chat below**, in one tab (`docked:
      false`, like the other panel-owning kinds). The preview shows the newest
      chart from the conversation; older ones stay reachable — reuse the
      homepage's SVG-bank-plus-zoom-modal pattern rather than inventing a second
      one.
- [x] Iteration is conversational: "make the bars horizontal", "log scale",
      "drop 2023" produce a new chart in the preview. The preview always shows
      the newest; the transcript keeps the lineage.
- [x] Label every freehand chart as drawn-not-computed (Part I's standing rule).
- [x] Tests: the kind opens a tab, the panel renders, an ```` ```svg ```` reply
      lands in the preview and is stripped from the bubble, the sanitizer runs.

# Phase 2 — Give it data to chart

- [x] Make the cached market/portfolio data reachable from the Chart Build chat
      (Part III.1): the daily closes, the portfolio ledger, held symbols. Prefer
      existing command-surface reads over new ones; if a gap needs filling, one
      narrow read beats a general one.
- [x] Teach the skill (below) how to ask for it, and — importantly — how to
      report honestly when the data is thin. "I have 4 of the 30 days you asked
      for" is the correct answer; drawing a confident 30-day line is not.
- [x] Live-read gesture: intentionally none. Phase 0 did not allow broker reads;
      refreshes remain explicit actions on the Robinhood surface.

# Phase 3 — The `chart-builder` reference skill

*Can be written in parallel with Phase 1 — but it is worth writing after a few
real sessions, so it teaches what actually goes wrong.*

- [x] `skills/chart-builder.md`, `handler_kind: reference`, modelled directly on
      `shader-designer.md`: frontmatter, what a chart is here, the hard
      constraints (self-contained `<svg>`, `viewBox`, no external refs/scripts,
      size cap), the house palette and typography, and **the honesty rules as
      rules** — zero in frame, gaps are gaps, no smoothing across missing data,
      label the axes you actually plotted.
- [x] Worked examples, which is what makes `shader-designer` good: a line chart,
      a bar chart, a candle chart, each with the arithmetic shown.
- [x] Ship it enabled (`enabled: true`) so the tab works out of the box, and
      note that a user can edit it — that's the point of the file-first design.
- [x] **The `dataviz` skill in this environment is a strong source for the
      palette/mark/axis guidance** — read it before writing the house rules
      rather than reinventing them. Done 08-03-26, and it changed real things:

      - The first pass hand-picked two series colours. Both **failed the
        lightness band** for a dark surface. Replaced with a **five-slot fixed
        order**, derived by snap-to-passing against the `#111315` canvas and
        run through `validate_palette.js`: `#ff4407` (the hazard accent, pinned
        to the in-band step nearest `#FF4D1C`), `#00a1ce`, `#9417ff`,
        `#e10095`, `#ac9000`. Clean pass — worst adjacent CVD ΔE 16.0 (target
        ≥8), normal-vision ΔE 23.4 (floor ≥15), every slot ≥3:1. All-pairs
        (scatter/bubble) validates the **first four** slots.
      - **A measured collision, not a guess:** the down-red `#ff5c70` sits
        **ΔE 8.2 from the hazard orange** — a down candle against a price line.
        Searching for a replacement red made things worse (best candidate
        `#b5323c` scraped 3.09:1). So the rule is structural instead: **a chart
        encoding direction does not use slot 1**; series start at slot 2. Slot 4
        magenta sits exactly at the ΔE 15.0 floor against the down-red, so a
        directional chart wanting a fourth series folds or facets.
      - **Dual-axis is now honesty rule 8.** Price-and-volume on two y-scales is
        the single most common chart lie and the first pass had no rule against
        it. Two stacked plots on one x, or index to 100.
      - Contradictions fixed: "square corners" → 4px rounded data-end, square at
        the baseline; "direct labels when possible" → *selectively*, never a
        number on every point; monospace ticks → one sans with `tabular-nums`.
      - Added what was simply missing: pick-the-form (a lone number is a stat
        tile, not a one-bar chart), legend required at ≥2 series and forbidden
        at one, **text never wears the series colour**, mark specs and the two
        spacers, one-hue sequential / neutral-midpoint diverging.
      - **The hover layer is documented as unavailable**, not skipped. The
        sanitizer strips scripts and handlers, so there are no tooltips — which
        is *why* the direct-label and values-in-prose rules are mandatory here
        rather than advisory.
      - Locked with a test: `chart_builder_test.exs` asserts the five hexes
        appear **in slot order** (the order is the CVD mechanism), seeding into
        a scratch workspace because `Skills.ensure/0` never overwrites.

- [ ] **Carry-over from the above:** `Skills.ensure/0` deliberately never
      overwrites, so any install that already seeded `chart-builder.md` keeps
      the unvalidated palette forever. The stale dev-workspace copy was deleted
      so it re-seeds. Not a problem yet — the skill has never shipped — but
      **a skill worth updating after release has no upgrade path**, and that is
      a question for the whole skills layer, not just this file.

# Phase 4 — The rigorous path (option B) and the extras

*Only after real use has shown which charts matter.*

- [ ] The ```` ```chart ```` spec + validator + server-side renderer for the
      standard types, reusing `PortfolioChart`'s geometry and its two honesty
      rules. Spec-rendered charts lose the drawn-not-computed label — they've
      earned that.
- [ ] **Save a chart to the Library** as an artifact (`Library.Artifact`), so a
      chart outlives its conversation. Today the homepage's SVGs live exactly as
      long as the transcript and are explicitly *not* a gallery; a chart the user
      built deliberately deserves better.
- [ ] PNG export via canvas rasterization (Part II) — our code, no model output,
      `blob:`/`data:` already allowed by CSP.
- [ ] Consider surfacing a finished chart elsewhere (the dashboard, a Library
      document). Needs an operator yes; scope creep lives here.

---

## Order

**Phase 0 is a five-minute conversation and it gates the rest** — especially the
kind string, which is persisted and therefore expensive to rename later.

Then **Phase 1**, which is the whole feature on borrowed infrastructure and is
where the design either proves itself or doesn't. **Phase 2** immediately after,
because a chart builder that can't reach the user's own data is a drawing toy.
**Phase 3** once there are real sessions to learn from — a playbook written from
imagination will teach the wrong lessons. **Phase 4** is genuinely optional and
should be re-justified when reached, not assumed.

**The failure mode to watch for** is the one Part I names: this feature's output
*looks* authoritative by construction. Every phase should be asked the same
question — can the user tell whether this picture was computed or drawn?
