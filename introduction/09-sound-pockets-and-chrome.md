## Sound: the chimes, and the two verbs that are gated

This machine plays sounds — a chime when a job lands, when a shift ends, when a
call arrives. There are **29 `sound_*` commands**, and they divide into three
jobs that are easy to confuse:

- **The library.** `sound_list`, `sound_sources`, `sound_routes` — what exists,
  and which event key plays what. Reads. Start here; the routing table is the
  thing most questions are actually about.
- **Editing.** Trim, fade, normalize, join. These write **new sources** into the
  Studio's working folder. They change no chime anyone hears — a cut file is a
  file until it is installed.
- **Installing.** `sound_apply` is **gated**, and it is the only verb that
  changes what the machine plays. That is the line: cutting is drafting,
  applying is publishing.

**`sound_record` is gated for a different reason and deserves its own sentence:
it opens the microphone.** It is the one command in this app that changes what
the machine does when nobody is watching. Never reach for it to "check
something"; if a task seems to need it, say so and let the operator start it.

There is also a **cut-up engine** — recordings indexed word by word, then
spliced into sentences nobody said. No model, no network. It is command-only and
its verbs are in the catalog below; the Explained tab's Ramshackle page is the
long version if the operator asks how it works.

**The corpus is divided into voice banks, and `voice_bank_*` is how you read and
switch them.** A bank is *one person through one microphone* — not a folder. The
rule is that **banks never merge**, and it is not fussiness: a phrase spliced
from two speakers sounds broken, and nothing downstream repairs it, because the
matcher chooses takes by timbre and will happily rank a stranger's voice as the
best fit for a word. `voice_bank_list` is safe and tells you which bank is
active; `voice_bank_select` switches it, which changes both what the dictionary
reports and whose voice a new recording joins.

So before you answer *"can it say this?"*, know **which voice you are asking
about** — a word the active bank has never said is missing even when another
bank says it thirty times. `sound_gaps` reports the active bank, not the machine.

`sound_record_save` is the in-app recorder's write half and is **gated** for the
same reason `sound_record` is. Note what it produces that nothing else does:
takes with origin `manual` at confidence 1.0, because the operator recorded a
known word deliberately and the clip *is* the word. Every one of the 655 takes
in the original voicemail corpus is `aligned` — a proportional guess capped at
0.9 — so a recorded take is the only kind the aligner cannot second-guess.

## Pockets: folders that know what they are for

A **Pocket** is one directory under `pockets/` with a `POCKET.md` manifest
saying what it holds. The background image pool is one. The dock icons are one.
The contact shaderfaces are one.

`pocket_list`, `pocket_describe`, `pocket_read` are **reads, and that is the
whole command surface** — there is no verb that creates a Pocket, fills one, or
points one somewhere else.

Two things follow, and the second is the one that catches people:

- **The manifest describes; it never grants.** A Pocket saying it holds icons
  does not make it the icon folder. Which Pocket backs which role is fixed in
  code, precisely because a manifest is a file you can write.
- **You can put a file in a Pocket without any command** — the workspace is
  writable. That is *why* the surfaces that matter do not simply follow their
  folder. A background shader you wrote needs the operator to apply it once. The
  macOS Dock icon needs them to press a button. Writing the file is not the act;
  their click is.

## What you can see and cannot drive

Some of this app is deliberately out of your reach. Knowing which parts saves
you offering something you will then have to walk back:

- **The Dock icon** (`pockets/app-icon/`) — you can write an image into the
  folder. **No command applies it.** Tell the operator the file is there and
  point them at Settings → Pockets.
- **Terminal themes** — `terminal_theme_list`, `_select`, `_paint`, `_reset` are
  yours, and they carry 21 validated colour values, which cannot execute. A
  palette is not a shader; that is the whole reason these are not gated.
- **`model_policy`** is **gated**: it decides which agent CLI and model run each
  surface, including the ones that spend money. Read it freely; changing it is
  the operator's call, in as many words.

## The Sketch Pad

A **sketch** is a drawing the operator and you share — a surface in the Studio
holding freehand strokes and images. Unlike a picture, every mark on it is an
**element with its own id**, which is what makes one of them changeable and
removable rather than baked into pixels.

`sketch_list` says what exists. `sketch_get` returns one, and returns it **two
ways at once**:

- `elements` — every mark with its id, its author (`operator` or `model`), its
  colour and width or its image source, and the box it occupies.
- `preview` — a **path to a rendered PNG of the whole drawing. Open it.**

Both, every time. The list tells you what is there; the picture tells you what it
*looks* like — which marks overlap, which are illegible, where the empty space
is. Answering from the list alone is how you describe a drawing you have not
seen. A stroke's individual coordinates are deliberately not returned: a freehand
mark is hundreds of points you cannot act on, so it carries a point count and a
bounding box instead.

`preview` may be `null` with a `preview_error` beside it — rendering leans on a
macOS tool that is not always there. The elements are still correct: say what is
on the sketch, and say you could not see it.

**These are reads, and that is the whole surface today.** You cannot yet add,
change or remove a mark. When you can, the rule will be that you may freely
change and delete **what you drew**, and touching something the operator drew
will need their say-so — so the `author` field is worth reading now.

