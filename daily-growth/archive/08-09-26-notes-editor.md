# Notes editor — a word processor whose file is still Markdown

**Scoped 08-09-26 · ARCHIVED 08-09 — walked and working, on the third editing
design.** Its three leftovers moved to `daily-growth/roadmaps/LEFTOVERS.md`.

> **If you are here because a comment cited this file, read Part VIII first.** It
> supersedes the design in Parts II–IV. The editor described in the earlier parts
> was built twice and failed both walks; what actually ships is the smaller thing
> in Part VIII, and Parts I–VII are kept because the two failures are the useful
> part of this document.

> ### The one-sentence version
>
> **The Notes textarea becomes a live-preview editor — headings render big and
> bold, `**bold**` renders bold, markers appear only on the line the caret is in
> — with a formatting toolbar, and the file on disk stays the exact Markdown it
> is today.**

> ### The operator's correction that started this
>
> *"I think I led us slightly astray in the initial design. We want this to
> function like a notepad or MS Word-like word processor."* (08-09)
>
> `HOME_ACTIVITY_NOTES_ROADMAP` shipped Notes as a **Markdown vault with an
> editor attached** — a source textarea beside a rendered preview. That is a
> developer's notebook. The ask is the other emphasis: **a writing surface whose
> storage format happens to be Markdown**. The vault, the `note_*` commands, the
> wiki links, the backlinks and the conflict machinery all stay; the *editing
> surface* is what was wrong.

---

## Contents

- [Part I — What the code already tells us](#part-i--what-the-code-already-tells-us)
- [Part II — Locked decisions](#part-ii--locked-decisions)
- [Part III — The model](#part-iii--the-model)
- [Part IV — The phases](#part-iv--the-phases)
- [Part V — Risks](#part-v--risks)
- [Part VI — What this does not solve](#part-vi--what-this-does-not-solve)
- [Part VII — The operator walk](#part-vii--the-operator-walk-08-09)
- [**Part VIII — The simplification**](#part-viii--the-simplification-08-09) ← start here

---

## Part I — What the code already tells us

Five findings. Two of them decide the architecture, and one is a trap that would
have silently eaten notes.

### I.1 — A textarea has exactly one font, so the textarea is the whole job

`components/notes/editor.ex:209` renders `<.input type="textarea" id="note-editor">`
in `font-mono text-sm`. There is no arrangement of CSS in which one `<textarea>`
shows a heading larger than its body text — the element renders a single text
node in a single computed style.

So "the editor shows the bigger bolder font" is not a styling task with a
textarea in it. **The textarea has to stop being the visible surface**, and
everything else in this roadmap follows from that one fact. The toolbar, by
contrast, is the easy half: buttons that rewrite a string.

### I.2 — `body` is the whole file, and nothing normalizes it

`Notes.save/3` (`notes.ex:194`) writes the string it is handed:

```elixir
with :ok <- validate_size(byte_size(body)),
     true <- String.valid?(body) || {:error, :binary},
     ...
     :ok <- atomic_write(absolute, body) do
```

No frontmatter split, no round-trip through a parser, no canonicalization. The
editor's output **is** the file. There is no layer downstream that would catch a
serializer dropping a table or mangling a code fence.

That is why the editor model was the first question asked, and why the answer was
the one where **round-tripping is identity rather than a conversion** (D1). A
full WYSIWYG surface would have made every keystroke rewrite the file through a
lossy HTML→Markdown pass, in a vault that `note_write` lets an agent author.

### I.3 — Serializing with `innerText` would silently delete the markers

This is the trap, and it is worth stating before any code exists.

The design hides Markdown markers with CSS on lines the caret is not in.
`element.innerText` **respects CSS** — it returns the *rendered* text, so a
marker hidden with `display: none` is absent from `innerText` by specification.
An editor that serialized that way would save `Launch plan` where the file said
`## Launch plan`, and it would do it silently, on every note, forever.

`textContent` ignores CSS entirely and is the correct primitive. It does not
insert newlines at element boundaries, so serialization is **a walk over the line
elements joining their `textContent` with `\n`** — never a single call on the
root. Phase 0 makes that a named, tested function precisely so nobody reaches for
the convenient wrong one later.

### I.4 — The save and conflict machinery is worth preserving exactly

`notes_component.ex` and `note_editor.js` already carry a careful design that has
nothing to do with how text is displayed:

- optimistic `Unsaved` from the hook, `Saving…` from CSS, `Saved`/`Conflict`/
  `Save failed` from the write (the moduledoc explains why each must come from
  where it does),
- revision compare on focus and on a 20s tick,
- the conflict banner, "Copy my draft", "Reload disk version", "Overwrite",
- `phx-debounce="700"` autosave plus ⌘S.

Every one of those reaches the text through `this.textarea()` or through
`phx-change` on the form. **None of it should change.** D3 is how that is
achieved: the textarea survives as the *model*, hidden, and the new surface is a
*view* over it. The alternative — reimplementing the form field as a `push_event`
channel — would have put a working conflict design at risk for no gain.

### I.5 — Two gates and one dead function will fire on contact

- **`scripts/check_file_sizes.sh` caps all four Notes files as `HELD`** (744 /
  300 / 211 / 134) and **fails in both directions**. Deleting the preview pane
  takes `editor.ex` well under 80% of its 300-line cap, which trips the ratchet.
  The cap must be lowered **in the same commit**, which is the gate working as
  designed, not an obstacle.
- **`Links.replace/2`'s only caller in the repo** is `notes_component.ex:418`,
  inside the preview render this roadmap deletes. It does not simply become dead:
  the editor needs the same resolution to know whether a `[[link]]` target
  exists. It moves rather than dies — but if Phase 1 lands before the editor
  consumes it, it is momentarily an F1-class orphan, and the honest fix is to
  land them together.

---

## Part II — Locked decisions

**D1 — The editor's text is literal Markdown. Always.** The DOM holds the source
string, decorated. It never holds a rendered document that must be converted
back. This is what makes an unknown construct — a table, a footnote, raw HTML,
frontmatter, a `[[wiki link]]` — safe: the tokenizer that does not recognise it
simply does not decorate it, and it saves back byte-identical. *Operator choice,
08-09, over full WYSIWYG.*

**D2 — Markers are hidden on every line except the one the caret is in.** That is
the "MS Word" feel without giving up D1. The caret's line is the *hot* line.

**D3 — The line the caret is in never contains a hidden character.** This is
the decision that makes D2 tractable: every caret-stuck-inside-an-invisible-marker
bug that live-preview editors are known for is *structurally absent* rather than
guarded against.

*Corrected during Phase 1.* This first read "the hot line is rendered as raw
text", which would have cost the feature its point — a heading you are editing
would lose its size the moment you put the caret in it. What actually ships is
better: **the markup of a line is identical hot or cold**, and `data-hot` plus
CSS decides whether its markers are visible. So the hot line is fully styled
*and* fully legible as source, the render path never has to know where the caret
is, and the property above still holds because a visible marker is not a hidden
one. The cost is that typing re-renders one line and restores the caret within
it, which is why IME composition is skipped explicitly.

**D4 — The textarea survives as the model.** It stays in the form, hidden,
server-rendered. The contenteditable writes to `.value` and dispatches `input`,
so `phx-change` + `phx-debounce="700"` fire unchanged; the server re-renders it
on open/reload/conflict-reload and the hook syncs the view from it. **The server
contract does not change at all** — no new events, no `push_event` body channel,
and `notes_component.ex`'s save logic is untouched by Phases 0–2.

**D5 — The toolbar rewrites the string, not the DOM.** Every button is a pure
`(text, selection, action) → {text, selection}` transform, applied to the model,
after which the view re-renders. No `document.execCommand("bold")`, no DOM
surgery, and the whole toolbar is unit-testable without a browser.

**D6 — No new npm dependency.** The repo has three, all xterm. A live-preview
source editor is a tokenizer and a caret helper; TipTap/ProseMirror exist to
solve the *conversion* problem D1 deletes.

**D7 — The preview pane is removed entirely.** *Operator choice, 08-09.* The
editor is the preview. Backlinks move beneath the editor. `toggle_preview` and
`preview_html` go with it.

---

## Part III — The model

Four values, and the loop between them. This is the whole architecture.

```
  text     the Markdown source, a string          ← the model (the hidden textarea)
  caret    an absolute character offset into it   ← the only cursor state
  hot      the line index containing `caret`      ← derived, never stored
  view     one element per line inside the        ← the contenteditable
           contenteditable
```

**Render** is `(text, caret) → view`: split into lines; the hot line becomes a
raw text node; every other line becomes decorated spans with its markers marked
for hiding.

**Read back** is `view → (text, caret)`: join the line elements' `textContent`
with `\n` (I.3), and walk text nodes to turn the DOM selection into an absolute
offset.

Then:

| Event | What happens |
|---|---|
| `input` (typing) | read back → re-render → sync the textarea → LiveView autosaves |
| caret moves to another line | re-render (old line decorates, new line goes raw) |
| toolbar button / chord | `applyX(text, sel)` → render → sync |
| server changes the textarea | re-render the view from it |

Restoring the caret by **absolute offset over the whole document** rather than by
DOM node is what makes this robust: a multi-line selection replaced by a paste
can invalidate every node in the view, and the offset still means the same thing.
And because the offset determines the hot line, and the hot line is raw, **the
offset is always addressable** — it can never land inside a hidden marker.

---

## Part IV — The phases

### Phase 0 — the pure core · **SHIPPED 08-09**

Two modules rather than the one this section first named — reading and writing
are separate concerns and the split fell out naturally. No DOM, nothing on
screen changed. **68 tests, and the full JS suite is 263 green.**

`assets/js/lib/note_markdown.js` — Markdown → decorations:

- `decorateLine(line, inFence)` → `{block, segments, fence}`. Blocks: heading
  1–6, bullet, ordered, task, quote, fence, code, hr, paragraph. Spans: bold,
  italic, strike, code, link, wiki link — each marker run *labelled*, never
  removed.
- `decorate(text)` carries fence state across lines, which is the one thing a
  line cannot self-report.
- `serializeLines(lineEls)` — the `textContent` join of I.3.
- `noteMarkdownHolds(line)` — the preservation invariant as a callable
  assertion, run over all 50 fixtures rather than trusted case by case.

`assets/js/lib/note_commands.js` — toolbar actions as string transforms:
`applyInline`, `applyBlock`, `applyLink`, `insertBlock`, `toggleTask`,
`runCommand`, and `NOTE_COMMANDS` as exported data for Phase 2's lockstep test.

Follows the `lib/note_keys.js` precedent exactly: *the part that decides is pure
and tested; the hook only wires it up.*

**Four things the design got wrong, found by writing the tests:**

1. **Intraword underscores.** The first tokenizer italicised `snake_case_word`.
   Earmark — the renderer this app actually uses — does not, and the rule is
   narrower than CommonMark's: only a single `_` whose *closer* is followed by a
   letter is suppressed (`foo_bar_ baz` still emphasises, and `a__b__c` and
   `a*b*c` carry no such rule). Measured against Earmark directly rather than
   assumed. This repo's own notes are full of identifiers; it would have been
   visible on day one.
2. **Italic inside bold stole a star.** Pressing Italic on the selected word in
   `**hello**` saw a `*` on each side and unwrapped them — silently demoting
   bold to italic when both were asked for. A neighbouring marker belonging to a
   longer run of the same character is somebody else's.
3. **A line-wise selection is not a pair of offsets.** Bulleting three selected
   lines shifted each end by its own prefix delta, leaving the first line
   selected from just after its new `- `. Multi-line selections now snap to whole
   lines; within one line the caret still moves with its character. Both
   intuitions are right, and they are different rules.
4. **`insertBlock("hr")` on a blank line** pushed the blank down instead of
   replacing it, leaving a stray gap.

None of these is exotic, and all four were invisible to reasoning — they came
out of writing the assertion. That is the argument for Phase 0 being its own
phase.

### Phase 1 — the surface · **SHIPPED 08-09 (operator walk outstanding)**

The contenteditable view, the hot-line render, caret offset save/restore, and the
CSS that makes a heading look like a heading. The textarea went hidden (D4). The
preview pane, its toggle and `preview_html` are gone (D7); backlinks moved under
the editor.

| | |
|---|---|
`assets/js/lib/note_view.js` (+ test) | decorations → escaped HTML, one string per line |
`assets/js/hooks/note_editor.js` | the view, the caret, and the four intercepted edits |
`components/notes/editor.ex` | hidden `<textarea>` model + `phx-update="ignore"` surface |
`live/notes_component.ex` | −2 assigns, −2 events, −1 render pass |
`assets/css/app.css` | the `.ic-note-surface` block — the whole "looks like a word processor" half |
`notes/links.ex` | `replace/2` deleted with the preview it served |

Gates: compile `--warnings-as-errors`, format, `credo --strict`, **3,564 Elixir
tests + 280 JS tests, 0 failures**, cycles, file sizes, docs drift, Rust.

**Two things this section predicted wrongly, corrected from the work:**

1. **The file-size ratchet never tripped.** I.5 expected deleting the preview to
   drop `editor.ex` under 80% of its 300-line cap. It went **273 → 282**: the
   moduledoc explaining the model/view split and the surface's own attributes
   are longer than the preview markup that came out. No cap changed. The
   reasoning was sound and the arithmetic was a guess — worth remembering that
   "this deletes code" and "this shrinks the file" are different claims.
2. **`Links.replace/2` did not need to move — it needed to go.** I.5 said it
   would be "momentarily orphaned" and should land with its new consumer. In
   fact its whole job was rewriting `[[x]]` into `#note/…` hrefs *for the
   preview*, and the editor never wants that: the tokenizer already refuses
   links inside fences and code spans, and a clicked link now reaches
   `Notes.resolve_link/2` with its raw target. Deleted, with its four tests.

**Two test-level findings worth keeping:**

- `open_link` and `create_link` collapsed into **one `follow_link` event**. The
  editor cannot know whether a target exists — resolution needs the vault index
  and the fuzzy basename match — so sending the raw target and letting the
  server decide is the only version with one source of truth.
- **A guard went vacuous and had to be moved, not kept.** "a wiki link inside a
  code fence is left as text" asserted `refute html =~ "#note-new/Fenced"`
  against the preview's HTML. With no preview the server emits no link markup at
  all, so both of its assertions pass regardless of what the code does. It was
  deleted here and re-asserted in `note_markdown.test.js` where the behaviour now
  lives. This is the third seam from `doc_drift_roadmap` — *a collection empties
  and its guard goes vacuously green* — caught this time because the deletion and
  the test were read together.

**Still outstanding: the operator walk.** A LiveView hook contract is invisible
to `render_hook/3`, so nothing above proves the editor *feels* right — only that
it is wired right. V.1 (undo) is known-missing and is Phase 3.

### Phase 2 — the toolbar · **SHIPPED 08-09 (operator walk outstanding)**

`components/notes/toolbar.ex`: 14 buttons in five groups — H1/H2/H3 · bold,
italic, strike, code · link · bullet, numbered, task · quote, code block, rule.
Each is `type="button"` carrying `data-note-cmd` and **nothing else** — no
`phx-click`, no `phx-target`, no server round-trip between pressing Bold and
seeing bold. Chords ⌘B/⌘I/⌘K joined `note_keys.js` as `formatChord/1`.

`NotesToolbarLockstepTest` holds the Elixir button list and JS `NOTE_COMMANDS`
together. It fails in **both** directions, unlike `hooks_registered_test.exs`:
there, an unused hook is a feature waiting for its surface; here, the toolbar is
the only thing that can invoke a transform, so an unrendered one is dead. **The
guard was verified by breaking it** — removing `quote` from the JS table fails
with `only in toolbar.ex: ["quote"]` — because a lockstep test that has never
failed is a lockstep test nobody has checked. It also asserts the regex found a
real table, so it cannot go vacuously green if `NOTE_COMMANDS` is renamed.

**Two details that decide whether the toolbar works at all:**

1. **`mousedown` is cancelled on every button.** Clicking anything focusable
   collapses the selection in the contenteditable — so by the time `click`
   fires, "select a word, press Bold" would have nothing selected. This is the
   one piece of the toolbar's behaviour that lives in the hook rather than the
   component, and it is why the buttons need no `tabindex` handling.
2. **Pressed state is derived, never tracked.** `activeCommands(text, offset)`
   reads the block from the caret's line and the inline styles from the segment
   the caret stands in — both straight out of the tokenizer, so a button cannot
   disagree with the text under it. Standing *before* a marker counts as
   outside the span it opens, so pressing Bold at the very start of `**bold**`
   starts a new one rather than claiming to end that one.

Gates: compile `--warnings-as-errors`, format, `credo --strict`, full Elixir
suite + **295 JS tests**, 0 failures, cycles, file sizes, docs drift, Rust.
(The Elixir total moved for reasons that were not this work — a second session
committed into the same tree mid-run. 5 of the tests are this phase's.)

### Phase 3 — the walk fix list · **W1/W2 SHIPPED · W3 REPLACED BY PART VIII**

Ran as four file-disjoint lanes. **W1 and W2 landed and stand.** W3 — the typing
rewrite — was attempted here, failed its walk, and was replaced wholesale by the
simplification in Part VIII; lanes B and C were deleted with it.

| Lane | Scope | Outcome |
|---|---|---|
**A — the typing rewrite** | `hooks/note_editor.js`, `lib/note_view.js`, `app.css` | **superseded — Part VIII** |
**B — undo/redo** | `lib/note_history.js` | **deleted** (browser's ⌘Z) |
**C — Enter & Tab** | `lib/note_structure.js` | **deleted** (browser's Enter) |
**D — rename & delete** | `notes/{editor,rail}.ex`, `notes_component.ex`, `hooks/note_context.js` | **shipped** |

The fan-out itself worked — three agents, no two sharing a file, no conflicts in a
tree three sessions were writing to. What it could not do was tell me the design
they were building onto was wrong. **Parallelism multiplies a plan; it does not
check one.**

### Phase 4 — prove it in the app · **PASSED 08-09**

*"It looks like its working now thats great."* — operator, fourth walk.

The base holds: typing, deleting and Enter behave, and the save status is steady.
That is the third editing design and the first one to survive contact.

**What the three walks cost, and what they bought.** Two full rewrites of the
same component, and every one of the three defects was invisible to a green
suite — a `data-hot` attribute stripped by its own re-render, a stale index that
swallowed edits, and a server echo that only became harmful when an unrelated
change removed the focus protection hiding it. Three gate-green states, three
unusable editors. **On an interactive surface, "the suite passes" and "it works"
are not the same claim, and only the operator can make the second one.**

The fix each time was to take *less* control, not more. That is the sentence to
carry to the next feature like this one.

#### Still open, deliberately

- **The niceties the simplification deleted**: list continuation on Enter,
  Tab-to-nest. Each returns as one narrow intercept, added and walked
  individually — never as a batch, since a batch is how the base got lost twice.
- **External links are inert.** `[label](url)` carries its target as data but
  nothing handles a click; only `[[wiki links]]` navigate. When it is wired the
  scheme must be checked — `javascript:` is already in the XSS fixtures for
  exactly this reason.
- **A packaged-app walk**, which is a LAUNCH G-40 concern rather than this
  roadmap's.

The mid-line list-split question (`- buy| milk` producing a double space) is
**moot** — `note_structure.js` was deleted with the simplification, so nothing
splits list markers any more.

#### The leftovers this section used to hold

**Undo (V.1) is the item that matters** — see the risk, unchanged and now the
largest known gap. With it: list continuation on Enter (pressing Return in a
bullet should open the next bullet, and on an empty one should end the list),
Tab/⇧Tab to nest, and the packaged-app walk.

Two smaller things Phase 2 surfaced and deliberately left:

- **External links are inert.** A `[label](url)` span carries its URL as
  `data-target` but nothing handles a click; only `[[wiki links]]` navigate. When
  that is wired, the scheme must be checked — `[click](javascript:alert(1))` is
  in the XSS fixtures precisely because the target survives tokenizing as data,
  which is safe only while nothing follows it.
- **No inline chord beyond three.** Eleven of the fourteen commands are
  click-only, on purpose (`formatChord`'s comment carries the reasoning). If the
  operator wants more after living with it, that is evidence rather than
  guesswork.

---

## Part V — Risks

**V.1 — Undo is the one thing this design makes harder, and it is table stakes.**
Re-rendering the view on every input destroys the browser's native undo stack.
For a surface the operator was told is "like Word", ⌘Z not working is a defect,
not a polish item. Two options, and Phase 3 must pick one deliberately rather
than discover it: keep programmatic edits inside `document.execCommand("insertText")`
(deprecated, still universally supported, participates in native undo), or keep
an explicit `{text, caret}` ring. **Named here so it is a decision and not a
surprise.**

**V.2 — This is a hook contract, and the Elixir suite cannot see it.**
`render_hook/3` pushes straight at the component and never loads the JS. The
repo has been bitten by exactly this shape before (the sweep that severed a
hook↔markup contract with a green suite the whole way). The mitigations are the
bun tests in Phase 0 and a real walk in Phase 1 — not more `render_hook` calls.

**V.3 — Paste.** The clipboard will deliver HTML from a browser or Word. Phase 1
takes the `text/plain` flavour only, which is correct and boring. Converting
pasted HTML *into* Markdown is the D1 conversion problem sneaking back in through
a side door; if it is ever wanted it is its own scoped item.

**V.4 — Very large notes.** Re-rendering every line on every keystroke is O(lines).
`Notes` already refuses files over its size cap, so there is a ceiling, but if it
drags, the fix is to re-render only the lines that changed — the model above
already supports it, and it should not be built until it is needed.

---

## Part VII — The operator walk, 08-09

Phases 0–2 shipped green and were then **used**, which produced three findings a
test suite could not have. Recorded before any of them is fixed, because the
third one is a design error of mine and the reasoning matters more than the
patch.

### W1 — Rename belongs to the title, not to a pencil

*"We want the title rename to be opened by users double clicking the title. We
don't want a pen and x button on the right."*

The header grew a pencil and a trash can because the rename form needed a
trigger and the delete needed a home. Both are the shape you reach for when you
are thinking about *the form* rather than about *the document* — a word
processor renames by clicking its title, and it does not keep a delete button
next to the thing you are typing into.

**Fix:** double-click the `<h2>` to open the rename form. The pencil goes.

### W2 — Delete belongs to the list, not to the open document

The trash can sits two centimetres from the writing surface and destroys the
file you are looking at. Its `data-claw-confirm` made that survivable rather
than safe.

**Fix:** right-click a row in the rail. `StudioContextMenu`
(`assets/js/hooks/studio_context_menu.js`) is the existing precedent in this
repo and the new menu should follow it rather than invent a second convention.
The trash button goes. `delete_note` already exists and does not change.

### W3 — Typing is rickety, and the cause is a decision I got wrong twice

*"Typing into the note is pretty rickety still."*

Four causes, and the first is a plain bug:

**W3a — the markers vanish on the line you are editing.** `render()` replaces the
hot line with `element.outerHTML = markup`, and that markup carries no
`data-hot` — it cannot, because Phase 1 made the markup identical hot or cold on
purpose. `setHot()` then early-returns, because the hot *index* did not change.
So the first keystroke on a line silently strips the attribute that reveals its
markers. The feature's central behaviour switches itself off as soon as you use
it.

**W3b — every keystroke tokenizes the whole document twice.** `render()` calls
`documentHtml(text)` (which decorates every line) and `onSelect` → `activeCommands`
calls `decorate(text)` again. On a 500-line note that is a thousand line-
tokenizations per character typed.

**W3c — every keystroke replaces the focused element and re-seats the caret.**
This is what "rickety" actually describes. Swapping the DOM node you are typing
into, then restoring the selection by offset, fights the browser's own editing
on every character — and it is why fast typing feels like it is catching.

**W3d — no undo**, because W3c destroys the native stack (V.1, known).

#### The correction

**D3 has now been wrong twice, in opposite directions, and the third version is
the one that was available all along.**

- *Original:* the hot line renders as raw text. Rejected in Phase 1 because a
  heading would lose its size the moment you put the caret in it.
- *Phase 1:* the hot line renders identically to a cold one, and CSS reveals its
  markers. This is what produced W3a and W3c.
- *Now:* **the hot line is a single text node, and the block styling lives on the
  line element rather than in its children.**

The Phase 1 rejection was reasoning about the wrong thing. A heading's size comes
from `data-block="heading" data-level="2"` on the `<div>` — an **attribute**, not
a span — so a line rendered as one bare text node is still big and bold. What a
plain hot line actually loses is *inline* decoration: bold inside the line you
are editing is not painted until you leave it. That is a real cost and a small
one, and it buys all of W3:

- nothing to strip, so W3a cannot happen;
- the element is never replaced while you type, so the caret is never re-seated
  (W3c) and the native undo stack survives (W3d);
- only the hot line needs re-tokenizing per keystroke, and only to see whether
  its *block* changed — two attribute writes, not a subtree (W3b). The whole
  document is re-tokenized only when the edit touches a fence, since that is the
  one construct whose effect escapes its own line.

The lesson worth keeping: **"the hot line must look finished" and "the hot line
must be cheap to edit" read as a trade-off and were not one.** The conflict came
from putting block styling in the children instead of on the line, and both
earlier versions accepted that layout without questioning it.

### W4 — The save status flickered, and the cause was the hidden textarea

*"It seems to be flickering between saved and unsaved in a rough manner. Maybe
we need a longer save time loop to allow the note to catch up to itself."*
(operator, third walk, 08-09)

**The operator's diagnosis was of the symptom; the cause was one line of the
save path.** Every successful save ran `assign_draft(note.body)`, which
reassigns `editor_form` and therefore re-renders the `<textarea>`.

That was harmless for the entire life of this feature *until Phase 1 hid the
textarea*, and the reason is a LiveView behaviour that is easy to rely on without
noticing: **LiveView will not clobber a focused input.** While the textarea was
the visible editor, it had focus whenever a save could land, so the echo was
silently discarded. Hidden and unfocused, it is patched like anything else — so
the server's copy arrives mid-keystroke, the hook sees a value it did not write,
rebuilds the surface, and takes the caret and every character typed during the
round-trip with it.

So the flicker and the lost text were the same event, and neither is in the save
logic. **A protection was being leaned on without being named, and the change
that removed it looked unrelated to saving.**

**The fix, both halves:**

1. `assign_body/2` records what the note contains without touching
   `editor_form`. Every save takes it. Only a genuine "here is different text"
   event — open, reload, conflict resolution, close — may re-render the field.
   Because the assign does not change, the diff carries **no update for that
   element at all**, which is the actual mechanism.
2. The hook refuses a server render while the surface holds focus. Redundant
   once (1) is in place, and kept because the failure mode is silent data loss.

**Why not the longer debounce.** It would have made the collision rarer rather
than impossible — the same race, hit less often, with saves feeling laggier and
keystrokes still disappearing occasionally. Worse, it would have looked like it
worked.

Guarded by *"a save does not echo the draft back into the editor field"*, which
asserts the rendered field is byte-identical across a save even though the file
on disk changed. It reads like asserting staleness, and that is exactly the
contract: **the client owns the draft, the server confirms it.** Verified by
reverting the fix and watching it fail.

---

## Part VIII — The simplification, 08-09

**Read this before Parts II–IV. Where they disagree with it, this wins.**

The second walk found the editor barely usable: *"when I open a note and try
editing it doesn't delete previous text, the enter button doesn't work or sends
the cursor up."* The operator's call was to stop patching and zoom out — *"clean
up the leftover dead code, rewrite our plan to stay nice and simple. It doesn't
need any CLI or agent connect so it should be very straightforward."*

That is the correct read, and this section is the smaller design.

### VIII.1 — What actually broke

The backspace bug is visible in the code without running anything. The typing
path had a fast case that started:

```js
const index = this.hot
if (index < 0 || index >= lines.length || lines[index] === this.docLines[index]) return
```

When the edited line is not the one the hook believes is focused — which happens
whenever `selectionchange` has not landed yet — that `return` fires and **the
model is never written**. The DOM changed and the textarea did not, so the next
render restored the old text. Deleting appeared not to work because the deletion
was being reverted.

The Enter bug was never diagnosed, and deliberately so: both are symptoms of one
cause, and diagnosing the second would only have produced a second patch for a
design that had to go.

### VIII.2 — The cause: a mirror nobody could keep in step

The Phase 3 hook maintained `docLines`, `decorated`, `rendered` and `hot`
alongside the real DOM, and recomputed caret offsets by walking text nodes on
every keystroke. **Four parallel structures, resynchronised per character.** One
stale index was enough to lose an edit, and there were a dozen ways to get one.

Both earlier designs share the shape, and it is worth naming as a single mistake
rather than two:

| | The design | How it failed |
|---|---|---|
Phase 1 | replace the focused line's element per keystroke, restore the caret by offset | typing felt like it was catching |
Phase 3 | keep a parallel model beside the DOM | a stale index swallowed edits |

Both were attempts to *own* editing. The fix is to stop trying.

### VIII.3 — The rule: the browser owns editing

**Typing never writes to the DOM tree. Not one node.**

The browser inserts and deletes characters exactly as it would in a textarea,
and the hook's entire job on a keystroke is to read the result out and hand it to
the model. Enter, Backspace, Delete, arrows, selection, drag, autocorrect, IME,
spellcheck and **⌘Z** are therefore the browser's own and work because nothing is
fighting them.

DOM writes are allowed in exactly three places, none on the typing path:

1. **Full render** — mount, or the server hands over different text.
2. **The caret leaves a line** — that line gets decorated. Safe *precisely
   because* the caret is elsewhere by then, so nothing needs restoring.
3. **A toolbar command** — rare and deliberate, so it may re-render and re-seat
   the caret.

The line the caret is in keeps whatever decoration it had when the caret
arrived, and CSS reveals its markers via `data-hot` — **an attribute the hook
sets, never something the renderer emits**, because an attribute write cannot
disturb a selection inside the element while rebuilding the element can.

Its decoration goes stale while you type: type `**` and it stays plain until you
leave the line. **That staleness is the price of the rule, and it is a good
trade.** Block styling still updates live, because that is also just attributes.

There is no parallel model, no caret arithmetic on the typing path, and no
keystroke interception. Nothing can fall out of sync because there is nothing to
sync.

### VIII.4 — What this deleted

Simplifying orphaned real work, including two modules built hours earlier. They
were good modules; the design that needed them was wrong.

| Deleted | Why |
|---|---|
`lib/note_history.js` + tests (37) | ⌘Z is the browser's again |
`lib/note_structure.js` + tests (43) | Enter is the browser's again; list continuation goes with it |
Enter / Backspace / Delete / Tab intercepts | the browser's |
`docLines`, `decorated`, `rendered`, `hot` mirrors | the cause |
`rawLine`, `decorate`'s `inFence` field, `lineHtml`'s `hot` parameter | orphaned by the above |

The hook went from ~600 lines to ~380, and the part that runs per keystroke from
about eighty lines to four.

**Lost features, recorded so they are choices and not drift:** list continuation
on Enter, Tab-to-nest, and a custom undo granularity. Each can come back later as
a *narrow* intercept, one at a time, only once the base is proven in the app.

### VIII.5 — The vacuous-guard rate

Three times in this one feature a test asserted a property the code did not have
and passed anyway:

1. the preview fence guard, `refute html =~ "#note-new/Fenced"`, after the
   preview stopped emitting link markup at all (caught, Phase 1);
2. `"hot and cold are the same markup"`, which called `documentHtml` twice with
   no caret argument and compared the results — it never exercised the thing it
   named (caught only after the design had changed under it);
3. its replacement's first draft, which asserted `lineHtml.length === 2` —
   **a parameter with a default does not count toward `Function.length`**, so
   `hot = false` would have slipped straight past.

The lesson is not "write better tests". It is that **a guard written in the same
sitting as the code it guards inherits that code's blind spot**, and the only
reliable check is to break the thing on purpose and watch the test fail. The
toolbar lockstep and the `data-hot` guard were both verified that way; the three
above were not.

---

## Part VI — What this does not solve

- **No tables UI, no image embedding, no export.** The toolbar is D5's twelve
  transforms.
- **Nothing about the `note_*` command surface.** An agent still writes Markdown
  through `Notes.save/3`; this roadmap does not add an appearance or formatting
  verb, and the reasoning in `TERMINAL_PAINT_ROADMAP` D1 about what the agent may
  put on screen is untouched.
- **No change to the vault, links, backlinks, switcher, rail, or search.**
- **No rich paste (V.3), no collaborative editing, no per-note settings.**
