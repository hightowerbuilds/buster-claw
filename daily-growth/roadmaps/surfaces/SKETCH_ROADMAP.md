# The Sketch Pad — a surface two of you can draw on

**Scoped 2026-08-16 · Status: Phases 0–4 COMPLETE 08-16. Phase 5 (live
co-drawing) remains deliberately unscoped — `D10` says the turn boundary makes
it optional, so scope it when there is a real complaint.**

> **Unwalked.** Every phase is green in the suite and none of it has been used by
> a person. The exit test that matters — *the model attempts to delete an
> operator's stroke and is gated, not obeyed* — is asserted in code and has never
> been watched happen.

> ### The one-sentence version
>
> **The model and the operator draw on the same document, and either one can
> change or remove anything the other put there — within a boundary drawn by
> authorship, not by tier.**

The Sketch Pad shipped on 08-16 as a canvas, five colours, three brush sizes, an
eraser and clear. Its own moduledoc asks for this map by name: *"When there is
[somewhere to save], it will be a `sketch_*` command and a workspace path, and
the argument for where those live belongs in a roadmap rather than in a button
somebody added because the toolbar looked empty."*

This is that argument, and it arrives with a finding the first pass could not
have known: **the requirement to edit and delete makes the current
implementation the wrong shape**, and no amount of adding to it fixes that.

---

## What it covers

The document model, the command surface, model authorship, screenshot import,
text, and the collaboration rules — presence, attribution, and who may remove
whose work.

## What it does not

- **The chat SVG channel** — `BusterClaw.SvgViewer`, which already exists and
  already lets the model draw. Its relationship to this surface is settled in
  `D2`, but it is not changed by this map.
- **The Studio shell** — the rail, the `/studio` route and the tab registry
  belong to [`STUDIO`](STUDIO_ROADMAP.md).
- **Image storage generally** — Pockets and the Appearance image pool own the
  operator's *collections* of media. A sketch's images are not a collection; they
  are parts of one document, and `D11` gives them a sidecar rather than a third
  library. *(This line used to say the map would borrow Pockets. It cannot: a
  Pocket is read-only by construction and a test enforces it.)*

---

## Part I — What already exists, measured before designing anything

### Outside: four systems, one shared answer

| System | How the model sees the canvas | How it changes it |
|---|---|---|
| [**tldraw agent starter kit**](https://tldraw.dev/starter-kits/agent) | **Both** a screenshot *and* a simplified shape list, split into viewport / focused / peripheral tiers | ~15 structured actions — create, update, delete, freehand, plus align/rotate/stack |
| [**tldraw agent-template**](https://github.com/tldraw/agent-template) | Same, plus session history and "lints" naming suspect shapes | Zod-schema'd action objects applied through the editor API |
| [**Excalidraw**](https://docs.excalidraw.com/docs/@excalidraw/excalidraw/api/excalidraw-element-skeleton) | — | `ExcalidrawElementSkeleton` → `convertToExcalidrawElements` — a deliberately minimal shape the generator writes |
| [**tldraw-skill**](https://github.com/Agents365-ai/tldraw-skill) | Renders to PNG, then **reads its own output back** with vision to catch overlaps and clipping | Up to 2 auto-fix rounds |

**Every one of them is structured. Not one operates on pixels.** That is not
taste — it is forced by exactly the capability this map is being written for. You
cannot delete a stroke from a bitmap, because after it is drawn there is no
stroke there, only pixels that used to be one.

### Four things worth stealing

**1. Dual representation, always.** tldraw sends the model a screenshot *and* the
shape list, and the reason is that neither is sufficient. The JSON says what is
addressable; the image says what it actually looks like — which things overlap,
which label is unreadable, where the empty space is. A model given only JSON
produces tidy data and ugly drawings.

**2. Sanitize every action against current state before applying it.** tldraw
ships `ensureShapeIdExists()` because *"the model can make mistakes… sometimes
due to hallucinations, and sometimes due to the canvas changing since the last
time the model saw it."* The second half is the one to design for: it is not a
model defect, it is a race, and it is guaranteed on a surface a human is also
drawing on.

**3. Concurrency is the actual hard problem, and it has published failure
modes.** The [Cleo work on concurrent human-agent editing](https://arxiv.org/html/2603.02050)
records the exact bug: *the agent executes a layout while the user proposes a
different one; unaware of the user's intent, it treats the user's edit as an
error conflicting with its plan and reverts it.* An agent that silently undoes
your work is worse than one that cannot draw.

**4. Attribution is a feature, not decoration.** The same literature lands on
presence indicators, visually distinguished agent edits, and surfacing conflicts
rather than resolving them silently.

### Inside: five findings from this repo

**F1 — The model can already draw here, and it is not this surface.**
`BusterClaw.SvgViewer` is live and load-bearing in the homepage chat: it appends
its own guide to the system prompt (`Status.Chat` line 142), extracts ```` ```svg ````
blocks from replies, sanitizes them, and renders them with a zoom modal. It is
**one-way, ephemeral, and has no element identity** — the model emits a picture
and that is the end of the transaction. **Two surfaces where "the model draws"
is a real risk this map has to answer**, and `D2` answers it.

**F2 — The Sketch Pad has no command surface at all.** Nothing in
`lib/buster_claw/commands/` mentions sketch. The model cannot see it, reach it,
or know it exists.

**F3 — The first pass is raster, by an explicit and well-argued decision.**
`sketch_pad.js` owns every pixel; `sketch.ex` carries `phx-update="ignore"` so
LiveView cannot re-render it away. The moduledoc states the trade honestly and
cites the Notes editor's rule — *do not build a parallel model beside the DOM.*
**That decision was right for what it was built for and is wrong for this**, and
`D1` says so out loud rather than quietly contradicting it.

**F4 — There is a precedent for exactly the contract this needs.** Scene3D:
**validated JSON in, rendered output out, the model never writes code.** The
feature is deleted; the contract is the reusable part, and it is the shape of
`D3`.

**F5 — And a sharper security precedent than the SVG one.** `SvgViewer` renders
model-authored markup live into the DOM, so it needs `sanitize/1` plus the CSP as
a backstop. **A structured document needs neither** — the model emits data, the
app draws it, and no model-authored markup ever reaches the DOM. Choosing
structure is not only what makes editing possible; it removes an injection
surface the existing drawing path has to actively defend.

---

## Part II — The central finding

> ### Editing and deleting force a document. There is no version of this on a bitmap.
>
> The ask is: the model draws, imports screenshots, adds text, and **edits and
> deletes all of those**. Every verb after the first requires that a thing drawn
> earlier still exist as a *thing*.
>
> On the current canvas it does not. Two strokes that cross are one region of
> pixels; a "delete the red arrow" instruction has nothing to address and nothing
> to remove. The eraser in the first pass is honest about this — **it paints the
> background colour**, because there is no other way to erase pixels on an opaque
> surface. That is a correct implementation of erase-on-a-bitmap and it is also
> the proof that bitmaps are the wrong substrate here.
>
> **So the core changes: a sketch becomes a list of addressable elements that the
> app renders, rather than a canvas that the browser paints.** Freehand strokes
> survive as elements — a stroke is a path with an id, not a smear — so nothing
> the operator can do today is lost.

This reverses `sketch.ex`'s "the browser owns the drawing." **That reversal is
the cost of the feature and it should be paid deliberately.** The Notes rule it
cited still holds where it was aimed: do not keep a *second* model beside the DOM.
The answer here is not two models but one, on the server, with the DOM as its
projection — which is what LiveView is for.

---

## Part III — Decisions

| # | Decision | Why |
|---|---|---|
| **D1** | **A sketch is a document of addressable elements, not a bitmap.** Rendered by the app from data | Forced by edit + delete. Part II |
| **D2** | **`SvgViewer` stays, unchanged, and is not this.** Chat SVG is a *reply*; a sketch is a *place* | Two model-drawing paths are fine when one is ephemeral output and the other is durable shared state. Merging them would make every chat drawing a document nobody asked to keep |
| **D3** | **The model emits validated element JSON. It never emits SVG, markup, or code into a sketch** | Scene3D's contract (`F4`), and it means no model-authored markup reaches the DOM (`F5`) |
| **D4** | **Both representations go to the model: the element list *and* a rendered image** | Every system surveyed does this, and for a stated reason |
| **D5** | **Every model action is validated against the live document before it applies.** Unknown id → refused, named, not guessed | tldraw's `ensureShapeIdExists`, and the repo's own instinct to refuse rather than approximate |
| **D6** | **Authorship is the permission boundary, not tier.** The model may freely change and delete **what the model authored**. Touching an operator-authored element is a gated action | See below — this is the load-bearing one |
| **D7** | **Every element records its author, and the surface shows it** | Attribution is how `D6` is legible instead of arbitrary |
| **D8** | **An imported screenshot is untrusted content and marks the run** | See Part V |
| **D9** | **Persistence is a workspace file the operator owns.** Markdown-adjacent, greppable, one file per sketch | "A workspace you own" is a product claim, not an implementation detail |
| **D10** | **No live co-drawing in v1.** The model's turn produces a batch the operator sees arrive | Concurrency is the published hard problem; a turn boundary is the cheap way to not have it. Revisit only with a reason |
| **D11** | **Image bytes live in a sidecar beside the sketch** — `sketches/<name>.assets/`, content-named | Operator call, 08-16. A sketch and its images travel together: deleting the sketch deletes them, and the folder is legible in Finder. The cost is a duplicate when two sketches use one image, which is the cheaper mistake — the shared-folder alternative needs an orphan sweeper nobody has written, and quietly leaves files behind on every delete |
| **D12** | **A drop is TWO transports; a paste is one** | Not a preference — a measured platform fact. See below |
| **D13** | **A command that needs to know its caller declares it by taking a second argument** | `D6` is the first rule in this codebase that a tier cannot express. See below |

### D13, because it changed the command surface for everything

Until 08-16 **no command had ever known who was calling it.** Authorization was
entirely the `PolicyEngine`'s, decided from the command's *name* before it ran —
and that is still right for almost the whole catalog.

`D6` is the first rule that cannot be expressed that way. *"The model may delete
what the model drew, and asks about the operator's marks"* is a decision about
**the data being touched**, not about the verb: the same `sketch_delete` is fine
or gated depending on which element it names. No tier encodes that, so the
command itself has to be told.

`dispatch/3` now hands the caller to any command that **declares arity 2**.
Everything else keeps the one-argument shape it has always had.

> Opt-in by arity rather than a registry or a reserved `_caller` key in the args
> map. A registry goes stale silently. A reserved key is invisible in the
> signature, rides along into every command that never asked for it, and would
> have to be scrubbed back out of the audit log. This way *"this command's answer
> depends on who asked"* is legible exactly where it matters — in the function
> head — and a command that does not care cannot accidentally read it.

### D12, because it is the one that would ship broken

**macOS WKWebView does not hand file *contents* to the DOM on an OS drag.** The
packaged app receives a *path* from Tauri's native drag-drop event and the server
reads the file; a dev browser receives real bytes through the HTML5 upload. Both
paths exist, **exactly one is live per environment**, and a surface wired only to
`phx-drop-target` works perfectly in `mix phx.server` and silently does nothing in
the DMG — which is the actual product.

This repo has already paid for that discovery twice, and the shape it arrived at
is reusable rather than merely instructive: `WorkspaceDropzone` and
`ChatDropzone` are the same hook applied to two surfaces, with the accept/refuse
judgement in a pure `assets/js/lib/attachments.js` under `bun test`, and the
house rule that **a drop is refused at the drop** — before a byte moves, while
the message is still obviously about the file just let go of.

**Paste is the easier half and works everywhere.** A pasteboard carries no
promise, so a copied screenshot is real bytes in `clipboardData` in the packaged
app as much as in a browser. The one thing it cannot do is a file *copied in
Finder*: that arrives as a reference with nothing behind it, which is precisely
what the drag path is for. Worth stating because "paste didn't work" will
otherwise be reported as a bug about the wrong gesture.

### D6, at length, because it is the one that will be argued with

The obvious design is a tier: let `agent_untrusted` create but not delete. It is
wrong, and it is wrong in a way this repo has already worked out twice.

**Terminal paint** (`TERMINAL_PAINT` D3): the model may repaint the terminal, but
every write lands in *the agent's own theme slot* — the operator's saved palette
survives whatever the model does, and a test fails if a call to `set_custom/3`
ever appears. **Voice banks** (`STUDIO` V.0): banks never merge, so one
contributor's takes can never be spliced into another's.

Both are the same rule: **the model gets full power over its own work and none
over yours.** Applied here it produces something better than a tier could:

- The model can iterate freely — draw, look, redraw, delete its own false starts
  — with no confirmation friction, which is what makes it useful at all.
- The operator's strokes cannot be silently removed by a model that decided they
  were a mistake. **That is the Cleo failure mode, refused structurally rather
  than prompted against.**
- The rule is one sentence, so the surface can state it and a test can enforce it.

Deleting or modifying an operator-authored element is therefore **gated** — it
surfaces for approval like any outbound action, rather than being refused
outright, because "move my box to make room" is a reasonable thing to ask for and
an unreasonable thing to do unasked.

---

## Part IV — The document

Shape sketch, not a schema. The real one belongs in Phase 1 with the tests.

```
sketch
  id, title, created_at, updated_at
  elements: [ ordered; z-order is list order ]

element (common)
  id          stable, app-minted — never model-minted (D5)
  author      :operator | :model      (D7)
  created_at
  kind        :stroke | :text | :image | :rect | :ellipse | :arrow

  stroke   points[], color, width
  text     x, y, content, size, color
  image    x, y, w, h, source        source names a Pocket/workspace file, never bytes inline
  rect
  ellipse  x, y, w, h, stroke, fill
  arrow    from, to, color, width
```

**Ids are minted by the app, never by the model.** A model-supplied id is the
same class of input as a model-supplied file path, and the repo already knows
what to do with those.

**Images reference a file; they never carry bytes.** A base64 blob in a document
is a document that cannot be diffed, grepped, or read — and it would put
arbitrary bytes into whatever the audit log captures.

---

## Part V — Trust

### The screenshot is the interesting one

"Import screenshots" sounds like a file-picker feature. It is an ingest path.

A screenshot of a web page is **untrusted content**, and the model will read it
back on the next turn as part of `D4`'s rendered image. Text inside that image is
text the model reads. This is prompt injection with an extra step, and it is a
path this repo already models: an autonomous run that has touched untrusted
content is `agent_untrusted` and loses the gated commands.

**So: importing a screenshot into a sketch marks the run** (`D8`). Not because
the picture is dangerous, but because looking at it changes what the run is
allowed to do afterwards — which is the whole point of having provenance.

`browser_screenshot` already exists and already produces exactly this artifact,
so the import path is mostly wiring rather than new capability.

### The rest

- **Element bodies are scrubbed from the audit log**, the way `note_create` and
  `note_save` bodies already are — a sketch is the operator's private thinking,
  and the audit row should record that a sketch changed, which one, and how much.
- **Sketch commands are `restricted`, not `safe`.** They mutate operator content.
  A read (`sketch_get`) can be safe.
- **No command mounts, moves, or reads outside the sketch directory**, the same
  absence Pockets enforces with a test.

---

## Part VI — Phases

Ordered so each one is usable alone, and so the riskiest thing is proven before
the expensive thing is built.

### Phase 0 — Make the current pad honest · *hours*

Independent of everything below, and worth doing whether or not the rest happens.

- [ ] The footer says *"a reload clears the page."* **A Studio tab switch also
      clears it** — `studio_panel.ex:160` is `:if={@tab == "sketch"}`, so leaving
      and returning destroys the canvas. One click, not a reload. Say the true thing.
- [ ] The eraser never marks itself active, so you can be erasing while a colour
      still reads as selected.
- [ ] `mark()` toggles only `border-*`, but the first size button also carries
      `text-primary`, which nothing removes — the dot stays highlighted on size 2
      no matter what is selected.
- [ ] No test exists for either the component or the hook. 21 JS test files exist;
      this is not an exotic ask.

### Phase 1 — The document, with no model in sight · **COMPLETE 08-16**

**The whole substrate change, provable by a human alone.** If this phase is right,
everything after it is wiring; if it is wrong, nothing after it can be right.

- [x] The element list, the schema, the renderer, and the workspace file —
      `Sketch.Element` / `Document` / `Store`, `Studio.SketchSvg`.
- [x] The existing tools re-expressed as elements: freehand strokes work
      identically and now have ids.
- [x] **Select, move, delete** — for the operator, and the phase's real test:
      deleting one stroke of five leaves the other four untouched.
- [x] Save and load. A sketch survives a tab switch, a reload, and a restart.
- [x] **Undo**, nearly free once elements exist, and not possible before.

**Three things the build decided that the scoping had not:**

1. **SVG, not a canvas.** Every element becomes a DOM node with an id, so
   hit-testing is `elementFromPoint` and selection is free. It also means the
   document is server-owned with the DOM as its projection — one model, not two —
   and strokes are resolution-independent, which the retina backing-store code in
   the raster version had to work for.
2. **The eraser had to change meaning.** It painted the panel's background,
   which is the only erase a bitmap allows. On a document that would create
   ground-coloured *elements* — marks that look erased, stay in the file, and
   would be read back to the model as strokes in Phase 2. It deletes now.
3. **Two renderers now produce the same path string**, one in Elixir and one in
   JS, because the hook draws a stroke while it is being made and the server
   draws it the instant it commits. A disagreement is not a rendering bug, it is
   a visible jump at the end of every stroke. Both are tested on identical cases.

> **The browser still owns one thing, and it has to.** `pointermove` fires per
> pixel; a round trip per point would be visible lag on the one interaction that
> must feel immediate. So a stroke is the browser's until `pointerup` and the
> server's from then on — **at any moment it is exactly one of the two**, which
> is what keeps this from being the parallel model the Notes editor warned about.

### Phase 2 — The model can read one · **COMPLETE 08-16**

- [x] `sketch_list`, `sketch_get` — safe tier, reviewed into the catalog's
      safe-tier snapshot with the reasoning.
- [x] `D4`'s dual representation: the element list **plus** a rendered PNG.
- [x] Nothing writes. `commands/sketch_test.exs` fails if a mutating verb appears
      before Phase 3.

**The raster needed a decision the scoping had not anticipated.** There is no SVG
rasteriser in this stack — no `rsvg-convert`, no `resvg`, no ImageMagick — and
adding an image *decoder* to the BEAM to draw pictures the operator already has
is a large surface for a small feature. macOS ships `qlmanage`, whose SVG support
is the same WebKit the app already embeds. It was **measured before being relied
on**: a 400x300 sketch rendered correctly.

Three consequences, written down rather than discovered:

1. It is a **thumbnailer**, so it boxes its output to a square. The first render
   came back with a white L filling the rest of the frame — which a model reading
   the picture can reasonably describe *as part of the drawing*. The preview
   canvas is square now, so that region is the sketch's own paper. Nothing moves
   and nothing distorts.
2. It is **macOS-only**, which the app already is.
3. It has **never run in a packaged build**, so rendering is non-fatal: a sketch
   whose picture could not be drawn still returns its elements, with
   `preview_error` saying why. A read is about the drawing, not the picture of it.

**One extraction the phase forced.** `path_data/1` lived in `Studio.SketchSvg`, a
web component, and a command runs with no socket — a command module reaching into
`BusterClawWeb` points the dependency the wrong way. The geometry moved to
`Sketch.Svg`, so it has one home and two callers rather than two copies, and the
JS agreement test now pins the pure module.

**And three guards caught what a human would not have.** The safe-tier snapshot
demanded a written review before promoting two commands; `INTRODUCTION.md`'s
family check demanded prose so the model knows the surface exists at all; and the
Explained atlas's hardcoded totals had to move with the catalog.

### Phase 3 — The model can draw · *2–3 days*

- [ ] `sketch_add` — validated element JSON, app-minted ids, author `:model`.
- [ ] `sketch_update`, `sketch_delete` — **model-authored elements only** (`D6`).
- [ ] `sketch_text` for text, if it is not simply an element kind by then.
- [ ] Every action sanitized against the live document first (`D5`); an unknown
      id is refused **by name**, never silently skipped.
- [ ] Attribution visible on the surface (`D7`).
- [ ] The gate: touching an operator-authored element surfaces for approval.

### Phase 4 — Images · *2–3 days* — **PULLED AHEAD of Phases 2–3 on 08-16**

Reordered at the operator's request, and the order is defensible rather than
merely allowed: Phase 2 is *"the model can read a sketch"*, and a sketch with a
screenshot in it is a far more interesting thing to read than one with five
strokes on it. Images make the phases after this worth more, so they come first.

Scope also **grew**. This phase was written as model-facing only —
`sketch_import` and `browser_screenshot`. The operator wants to put an image in
by hand, three ways, and that is a different surface with a different hazard.

**The operator's half:**

- [ ] An `:image` element kind: `x, y, w, h, source`. **References a file; never
      carries bytes.** A base64 blob in the document cannot be diffed, grepped or
      read, and would put arbitrary bytes into whatever the audit captures.
- [ ] Bytes land in a **sidecar folder** — see `D11`.
- [ ] A `:media` route serving them back, with `nosniff`, name-guarded the way
      every other workspace-bytes route already is.
- [ ] **Drop** — and it is two transports, not one. See `D12`.
- [ ] **Paste** — one transport, and it works in the packaged app.
- [ ] A file picker, because a drop-only surface is unreachable by keyboard.
- [ ] Validation by **magic bytes, not extension**, and a dimension cap. An
      extension is a claim; the first bytes are evidence.

**The model's half** (unchanged from the original scoping):

- [ ] `sketch_import` placing an existing workspace/Pocket image as an element.
- [ ] `browser_screenshot` → sketch, which is the errand this actually unlocks:
      *"screenshot the checkout page and mark what is wrong with it."*
- [ ] The provenance mark (`D8`), and the surface saying the run is now untrusted.

### Phase 5 — Collaboration proper · *unscoped, deliberately*

Presence, live co-drawing, conflict surfacing. **Not scoped until Phases 1–4 have
been used**, because `D10` says the turn boundary makes this optional and the
literature says it is the expensive part. Scope it when there is a real complaint,
not before.

---

## Part VII — Open questions

1. ~~**Where does a sketch live?**~~ **ANSWERED 08-16 by building it.**
   `<workspace>/sketches/<name>.json`, and `D9`'s "greppable" turned out to be
   the wrong word for it — a JSON document of stroke coordinates is not
   meaningfully greppable wherever it sits. What it *is* is **readable, portable
   and deletable**, which is the property that mattered. Images join it in a
   sidecar (`D11`). A rendered PNG next to the document, so the folder previews
   in Finder, is still worth doing and is not built.
2. ~~**Is a sketch a Library artifact, a Pocket, or its own thing?**~~
   **ANSWERED 08-16: its own thing.** The Library is markdown artifacts an agent
   produced; a Pocket is READ ONLY by construction (`POCKETS_ROADMAP` D4) and
   writing into one would contradict the rule its own test enforces. Neither fits,
   and forcing it would have cost a migration later.
3. **Does the model see the sketch it is not looking at?** tldraw solves this with
   viewport tiers. This surface is one screen, so probably not — but "probably"
   should become "measured" before Phase 2 ships.
4. **Text editing:** does the operator edit model-authored text inline, and does
   that change its author? A text box the model wrote and the operator fixed is
   genuinely co-authored, and `D6` has no answer for it yet.

---

## Exit tests

- [ ] An operator deletes one stroke of five and the other four are untouched
- [ ] A sketch survives a tab switch, a reload, and an app restart
- [x] The model, shown a sketch, describes what is on it correctly — the
      representation ships; the description itself is an operator walk
- [ ] The model adds an element, then deletes the element it added
- [ ] **The model attempts to delete an operator's stroke and is gated, not obeyed**
- [ ] An unknown element id is refused by name rather than silently ignored
- [ ] A model-supplied `id` field is ignored — the app minted the real one
- [ ] Importing a screenshot marks the run untrusted, and the surface says so
- [ ] No `sketch_*` command reads or writes outside the sketch directory
- [ ] Audit rows record that a sketch changed and how much, never its contents

---

## The short version

**Phase 0 is hours and is owed regardless.** Phase 1 is the map — it is a
substrate change, it reverses a decision made yesterday for good reasons, and
everything else is wiring on top of it.

**The one to get right is `D6`.** Every other decision here can be revised in a
later version. A model that can silently delete the operator's work teaches the
operator not to draw on the same surface as the model, and that lesson is not
recoverable by shipping a fix.
