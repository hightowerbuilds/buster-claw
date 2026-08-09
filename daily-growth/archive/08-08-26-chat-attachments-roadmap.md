# Chat attachments — dragging images and files into the conversation

**Scoped 08-08-26 · Status: PHASE 0 DONE — all mechanisms verified on this machine. MUST (operator, 08-08).**

**What this is, in one line:** drag or paste an image or a file into the homepage
chat and have the model actually see it — the way Claude Code, Codex and every
TUI and web chat already work.

**Why it is a must and not a nicety.** It is table stakes. Every chat surface a
user has ever touched accepts a dropped image, and the homepage chat is the
product's front door. Worse than absent, it is currently **falsely advertised**:
nothing on the page handles a drop, so the webview's default takes over, the
cursor says "copy" on hover, and the drop does nothing useful. **A user has
already been told by the interface that this works.**

---

## The lay of the land (read before building)

There are **three** obstacles, and only the third is the actual feature.

### 1. Nothing on the homepage handles a drop

No `allow_upload`, no `phx-drop-target`, no hook anywhere in `StatusLive` or
`ChatPanel`. The false affordance is the browser's own default behaviour.

### 2. WKWebView will not give the DOM file *contents* — and this is written down

From `assets/js/hooks/workspace_dropzone.js`, which already solved this once:

> macOS WKWebView does **NOT** hand file *contents* to the DOM on an OS drop, so
> the HTML5 upload path only works in a plain browser (dev). In the Tauri app we
> use the native drag-drop event, which delivers real file *paths*.

**So `phx-drop-target` + `allow_upload` — the pattern Appearance, Music, Notify
and Sound Studio all use — works perfectly in dev and does nothing in the
shipped app.** `WorkspaceDropzone` is the only correct precedent here: it runs
both paths and picks by environment. Copy that hook's shape, not the upload
examples'.

**Consequence for the Tauri path:** the app receives a *path*, reads the bytes
itself, and never relies on the DOM having them.

### 3. The message transport is text-only — but it is closer than it looks

`Chat.send_message(conv_id, text)`. There is no attachment concept in
`Agent.Chat` or `AgentRunner`, and `claude --help` has **no attachment flag** —
images are not a CLI argument.

But there are two live paths and they differ:

**The streaming path already speaks the right language.**
`BusterClaw.Agent.ChatMessageEncoder` (`:50`) writes:

    {"type":"user","message":{"role":"user","content":"…"}}

on stdin, to `claude -p --input-format stream-json` (`agent_backend.ex:344`).
That is the **Anthropic message format**, in which `content` is allowed to be an
array of blocks — including `{"type":"image","source":{"type":"base64",…}}`.
**An inline image needs no new transport, only a richer `content`.**

**The default path cannot do that.** A non-streaming turn passes the prompt as a
single discrete argument, so an image there has to be a **file the agent reads by
path**, granted with `--add-dir`.

**And the streaming path is not on by default.** Chat steering is DEV-ONLY behind
a flag; its rollout is `LAUNCH_ROADMAP` **G-41**. So the mechanism that does this
properly is gated behind a release decision this roadmap does not own.

---

# Part I — The design question, answered

**Operator constraint (08-08): "we don't want the model to be saving the image,
without a special request. It should be comparable to Claude and Codex and all
the TUI chats."**

That rules out the obvious implementation — copy the file into the workspace and
reference it — because that makes every dropped screenshot a permanent artifact
in the user's own filesystem.

## (A) Inline content block — the right answer where it is available

Extend `ChatMessageEncoder` so `content` may be an array: a text block plus one
image block per attachment, base64 in the JSON line.

- **No file ever exists.** Nothing to stage, nothing to clean up, nothing for the
  model to "save". This is precisely what the operator asked for.
- No new transport, no new flags, no `--add-dir`.
- **Only available on the streaming path**, which is DEV-only until G-41.

## (B) Staged file + `--add-dir` — the fallback, and it must exist

For the default (non-streaming) path: write the bytes to an **app-managed
attachments directory that is NOT the workspace the agent browses**, grant it for
the turn with `--add-dir`, and reference the path in the prompt.

- **Staging is not saving.** The distinction is the operator's, and it is real:
  the app puts a file where the agent can read it for one turn; the *model* never
  decides to keep anything.
- **Lifetime is already decided by precedent.** The SVG drawings live exactly as
  long as their conversation and are deleted with it — *"NOT a saved gallery"*.
  Attachments follow the same rule, for the same reason.

**Both are needed.** (A) alone ships nothing until G-41; (B) alone is worse than
the product deserves. Build (B) first because it works today, then (A) so the
better mechanism is ready when steering rolls out.

## What counts as an attachment

| Kind | Mechanism |
|---|---|
| **Images** (png, jpeg, gif, webp) | inline block (A) / staged path (B) |
| **Text-ish** (md, txt, csv, code, json) | inline as **text**, no image block, no file — cheapest and best |
| **PDF and other binaries** | staged path only; CLI document support is unverified |

Text files inlining as text is worth calling out: it is the common case for
"other files", it needs neither mechanism, and it is the one that will just work.

---

## Decisions taken while scoping (revisit if wrong)

1. **The app reads the bytes; the DOM is never trusted to have them.** Forced by
   the WKWebView finding, and it makes both mechanisms share one path.
2. **Paste is in scope from the start.** ⌘V with an image on the clipboard is at
   least as common as dragging in every chat this is being compared to. It is a
   different event, and bolting it on later means designing the pipeline twice.
3. **Attachments die with their conversation** — the `chat_svgs` rule, applied
   unchanged. Keeping one is an explicit act, not a default.
4. **Nothing is written into the workspace the agent browses.** Staging lives in
   an app-managed directory reached only by `--add-dir`, for one turn.
5. ~~Refuse rather than silently degrade on backends that cannot read images.~~
   **WITHDRAWN 08-08 by measurement** — all three backends have a native
   attachment mechanism. See Phase 0. Replaced by: **stage once, deliver per
   backend.** Codex and OpenCode take paths and cannot take bytes, so the staged
   file is the substrate all three share; Claude's inline block is an
   optimisation on top, not an alternative to it.
6. **Cap size and count, and say so at the drop** — not after an upload that
   appears to succeed and then fails at the transport.

---

## Phase 0 answered it — measured, not assumed (08-08)

The blocking question was whether a path in a `-p` prompt actually gets read.
**It does.** And checking the other two backends changed the design, so all four
findings are recorded here rather than in a commit message.

The probe was a 120×120 PNG generated for the purpose — magenta ground, yellow
square — chosen because both facts are verifiable and neither is guessable.

| Backend | Mechanism | Verified |
|---|---|---|
| **Claude**, streaming | inline `{"type":"image","source":{"type":"base64",…}}` block in the `content` **array** on stdin | **yes** — answered correctly, and **no file existed and no Read tool ran** |
| **Claude**, default | path in the prompt + `--add-dir` | **yes** — answered correctly |
| **Codex** | `-i, --image <FILE>...` — *"image(s) to attach to the initial prompt"* | flag confirmed present |
| **OpenCode** | `-f, --file <array>` — *"file(s) to attach to message"* | flag confirmed present |

### What this changes

**Decision 5 was wrong and is withdrawn.** It said to refuse on backends that
cannot read images. **All three can** — each with its own native attachment
mechanism. There is nothing to refuse and no degraded path to warn about.

**And staging is not a Claude fallback — it is the universal substrate.** Codex
and OpenCode both take **file paths**; neither accepts bytes. So a file on disk
is required for two of three backends no matter what, which collapses the
architecture into one shape:

> **Stage once, then hand it to each backend the way that backend wants it.**

One pipeline with a short per-backend tail, rather than two competing mechanisms.
Claude's inline block stops being the *primary* design and becomes what it
actually is — an optimisation available on one path of one backend, worth taking
because it is the only route where **no file need exist at all**.

**The lifetime rule is unaffected.** Staged files live in an app-managed
directory outside the workspace the agent browses, and die with their
conversation — the `chat_svgs` rule. Staging is still not saving.

# Phase 0 — Prove the mechanisms, build no UI — **DONE 08-08**

- [x] `claude -p` + `--add-dir` + an image path. **Reads it.**
- [x] Inline base64 block on `--input-format stream-json`. **Works, with no file
      and no Read tool** — the mechanism the operator asked for.
- [x] Codex and OpenCode: both carry native attachment flags (`-i/--image`,
      `-f/--file`). Decision 5 withdrawn.

**Done. No app code was written to answer any of it**, which was the point:
Phase 1 rested on an assumption, and an afternoon of UI built on a false one
would have been wasted.

# Phase 1 — Getting the bytes in

- [ ] A `ChatDropzone` hook modelled on `WorkspaceDropzone`: Tauri native
      drag-drop (paths) and HTML5 (contents), one overlay, one event, exactly one
      live per environment.
- [ ] Paste handling on the composer for image clipboard data.
- [ ] Server-side: validate type and size, reject early and visibly, hold the
      bytes against the conversation.
- [ ] The composer shows attachment chips — name, size, thumbnail for images, and
      a way to remove one before sending.
- [ ] Tests including the case that matters: a dropped file that is **too large
      or the wrong type is refused at the drop**, not after.

# Phase 2 — Getting them to the model

- [ ] Mechanism (B): staged file + `--add-dir`, path in the prompt, cleaned up
      with the conversation.
- [ ] Mechanism (A): `ChatMessageEncoder` learns array `content` with image
      blocks. **Its existing tests pin the string shape — extend, do not replace.**
- [ ] Pick per turn: (A) when streaming, (B) otherwise.
- [ ] Backend refusal per decision 5.

# Phase 3 — The transcript

- [ ] Attachments render in their message bubble — thumbnail for images, chip for
      files — reusing the zoom modal `svg_modal/1` already provides.
- [ ] They survive reload, the same way drawings do: **that means the attachment
      must be recoverable from the transcript**, which is a real constraint on how
      Phase 1 stores them and is the reason this phase is scoped now rather than
      discovered later.

---

## Tail items

- The false affordance exists **today**. Even before Phase 1, a drop handler that
  refuses politely — *"attachments are coming"* — is better than a webview
  navigating away from the app. Cheap, and it stops the interface lying.
- `StatusLive` is on the decomposition list in `LEFTOVERS.md` and this adds to it.
  Attachment state should live in its own module from the start rather than
  becoming the seventh concern to extract later.
