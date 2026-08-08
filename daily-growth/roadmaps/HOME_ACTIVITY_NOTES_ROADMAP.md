# Home Activity + Notes — minutes separated from the notebook

**Scoped 08-08-26 · Status: IN PROGRESS — Phases 0-2 complete.**

Before this implementation, Home had one **Notes** tab doing two jobs badly by
definition:

1. it is Buster Claw's append-only chronological record (“the minutes of the
   day”); and
2. its name promises the user a place to write notes, but it is not a notebook.

This map separates those jobs:

- **Activity** shows Buster Claw's minutes: what the agent did, day by day,
  backed by the existing `journal/` Markdown and durable activity metrics.
- **Notes** is the user's Markdown notebook: create, write, organize, search,
  link, and preview `.md` files under `<workspace>/notes/`.

No existing journal file is moved or rewritten. The split changes the product
model and UI, not the user's historical record.

### Implementation checkpoint

The product split is done. Home carries distinct Notes and far-right Activity
tabs; Activity is read-only, live-updating BC Minutes with seven-day metrics; and
Notes is a working Markdown vault — folders, recursive discovery, safe creation,
rename and move, a writing/preview surface, 700 ms autosave with ⌘S, an honest
five-state save chip, atomic revision-checked writes, focus/tick reconciliation,
conflict recovery that can copy the draft out, unsupported-file handling, and
confirmed deletion. What remains is the notebook's *finding* half: search,
wikilinks, backlinks, keyboard navigation, and the `note_*` command family.

### Delivery ledger

| Phase | State | Delivered | Still open |
|---|---|---|---|
| 0 — language and data contract | **Complete** | Separate registry entries; Activity is far right; journal paths/commands preserved; Introduction, jobs, catalog, Explore copy, and tests teach the split | Optional `activity_*` command aliases remain intentionally deferred |
| 1 — BC Minutes in Activity | **Complete** | `ActivityComponent`, read-only journal, streamed day rail, seven-day summary, live PubSub refresh, legacy operator markers | Timeline graph remains later polish |
| 2 — Notes R1 | **Complete** | Recursive Markdown discovery; folder create + grouped rail; safe create/open/edit; rename and move; sanitized preview behind a narrow-window toggle; 700 ms autosave plus ⌘S; Unsaved/Saving…/Saved/Conflict/Save failed; atomic revision saves; focus + slow-tick reconciliation; conflict copy/reload/confirmed overwrite; unsupported-file pane; confirmed permanent delete | — |
| 3 — search and links | **Not started** | — | Body search, switcher, wikilinks, backlinks, keyboard navigation |
| 4 — agent collaboration | **Foundation only** | Notes context broadcasts changes and generated guidance protects the Activity/Notes boundary | `note_*` commands, host subscription, open-editor agent collision flow |
| 5 — measured polish | **Not started** | — | Tags, outline, trash, attachments, watcher, graph only if justified |

---

## The useful repository history

Commit `a1d0b5e` was titled **“Notes tab becomes the minutes of the day.”** It
introduced today's `BusterClaw.Journal` and `JournalComponent`, and deleted an
earlier `BusterClaw.Notes` plus `NotesComponent` that already provided:

- one Markdown file per note under `notes/`;
- safe title-to-filename handling and traversal tests;
- create, select, edit, autosave, delete;
- split editor and sanitized live preview.

That old implementation is prior art, not something to revert wholesale. It was
flat, used non-atomic `File.write`, had no external-edit conflict detection, no
search/backlinks/folders, and could let an autosave overwrite an agent's edit.
The rebuild should recover its proven path-safety and UI shape while fixing the
collaboration and durability gaps.

The later `db10a58` change deliberately renamed “daily minutes” to “the Notes
record” so the agent saw exactly one activity destination. This map reverses the
*label*, not the single-log rule: after the split there is still exactly one
Buster Claw activity log, but it is correctly named **Activity**. The new Notes
vault is user-authored material, not a second activity log.

---

## Product contract

### Activity / BC Minutes

- A chronological, day-addressed record of what Buster Claw did.
- Stored exactly where it is now: `<workspace>/journal/YYYY-MM-DD.md`.
- Agent entries continue through `journal_append`; existing `journal_read`
  callers remain compatible.
- Read-only in the UI for R1. Historical `— OPERATOR` entries remain visible,
  but new human writing goes into Notes.
- Live-updates while open when the agent appends an entry.
- Shows computed context from `BusterClaw.ActivityReport` without pretending the
  metrics are the minutes themselves.

### Notes / Markdown vault

- User-owned Markdown files under `<workspace>/notes/`.
- Editable in Buster Claw and readable in any editor; no database-only body and
  no proprietary document format.
- Agent access is explicit: the agent may read or change a note when the user
  asks, but must never use Notes as the automatic activity log.
- Safe for concurrent human/agent editing: an external change is detected before
  autosave can overwrite it.
- Sanitized Markdown preview; raw note HTML never gets trusted because a note may
  be agent-authored or imported.

### The labels are the boundary

| Surface | Answers | Source of truth | Writer |
|---|---|---|---|
| Activity | “What did Buster Claw do?” | `journal/YYYY-MM-DD.md` + computed metrics | Agent automatically; legacy operator entries preserved |
| Notes | “What am I thinking or keeping?” | `notes/**/*.md` | User; agent only on explicit request |
| Security | “What consequential command happened?” | Sentinel events | System |
| Memory | “What did a prior run learn?” | `run_summaries` | System |
| Library/Documents | “What artifact was produced?” | workspace documents | User or agent |

The generated `INTRODUCTION.md`, job descriptions, command descriptions, Explore
tutorials, and tests all have to teach this same table. Renaming the tab without
rewriting agent orientation would send the next run back to Notes as an activity
dump.

---

## Proposed Home rail

```text
Chat | Notes | Calendar | Phone | Studio | Explore | Activity
```

Activity sits at the far right as a persistent operational record that users can
inspect without placing it ahead of their primary creation and communication
tools. The registry remains the single source of truth used by both the rail and
`select_home_tab` guard.

As with the other Home panels, only the active panel is mounted. State that must
survive a glance at Chat belongs in `StatusLive` only when necessary. Editing
state and streams belong in the Notes component; `StatusLive` should gain no note
CRUD logic.

---

## UI map

### Activity

```text
+----------------------+-----------------------------------------------+
| BC MINUTES           |  ACTIVITY · 08 AUG 2026                       |
| Today                |  Runs  4   Commands  31   Handled  6   Open 2|
| Aug 7                +-----------------------------------------------+
| Aug 6                |  09:12  Checked trusted inbox                 |
| ...                  |  09:18  Completed dispatch #214              |
|                      |  10:03  Saved launch review                   |
+----------------------+-----------------------------------------------+
```

- Left: streamed/newest-first day rail from `Journal.list/0`.
- Main: selected day's sanitized Markdown, with clear agent/operator markers.
- Header: small `ActivityReport.summary/1` cards for the selected/recent window.
- Later: day/week/month graph from `ActivityReport.timeline/2`; not required to
  make the Activity split useful.
- No composer in R1. Activity is evidence, not a scratchpad.

### Notes

```text
+----------------------+--------------------------+--------------------+
| NOTES                | Meeting Notes.md         | PREVIEW            |
| [ Search notes... ]  |                          |                    |
| + New note           | # Meeting Notes          | Meeting Notes      |
| Inbox/               |                          | rendered Markdown  |
|   Launch ideas.md    | - [ ] Send the draft    |                    |
| Projects/            |                          | Backlinks (later)  |
|   Remote access.md   | Saving... / Saved        |                    |
+----------------------+--------------------------+--------------------+
```

On narrow windows the three panes become a two-step layout: file rail → editor,
with Preview as a toggle/drawer. The editor remains a real `<textarea>` for
reliable typing, selection, spellcheck, and mobile input; “Obsidian-like” means
local Markdown ownership and linked-note ergonomics, not recreating a desktop
code editor in `contenteditable`.

---

## Domain architecture

### Keep Journal stable; present it as Activity

`BusterClaw.Journal` is already safe, tested, and used by commands/jobs. Keep the
module, directory, PubSub topic, and command names through the UI split.

The shipped `BusterClawWeb.ActivityComponent` owns:

- selected day;
- streamed day summaries;
- rendered minutes;
- read-only ActivityReport summary/timeline data.

`StatusLive` continues subscribing to Journal PubSub and sends an update to the
Activity component. The current implementation resets the small day stream and
summary from disk on refresh; affected-day-only stream updates are an optional
optimization after real journal sizes justify the extra state.

### Restore a dedicated Notes context

`BusterClaw.Notes` owns the vault root and all note operations. Its shipped API
works in relative, normalized note paths rather than accepting arbitrary
absolute paths:

```elixir
list/1
folders/0
get/1
create/2
create_folder/1
rename/2
move/2
save/3
delete/1
subscribe/0
```

Still planned: `search/1` and `backlinks/1`.

`rename/2` and `move/2` copy into an exclusively-created destination and then
remove the source, rather than calling `File.rename/2`. Rename clobbers an
existing destination silently, and losing a note to a name collision is the
failure this vault exists to prevent; a crash between the two steps leaves a
duplicate, which is recoverable, instead of a hole, which is not.

The implementation returns plain maps with this representative shape:

```elixir
%{
  id: "note-...",
  path: "Projects/Remote access.md",
  title: "Remote access",
  body: "# Remote access\n",
  revision: "sha256:...",
  updated_at: ~U[2026-08-08 20:00:00Z]
}
```

The revision is a hash of the bytes read, not only mtime. `save/3` accepts the
revision the editor opened and returns `{:error, {:conflict, current_note}}` if
the file changed. This is what prevents a delayed LiveView autosave from erasing
an agent or external editor's newer content.

### Containment and writes

- The vault root is `Artifact.workspace_path("notes")`.
- Every relative path is normalized and confirmed with
  `FileManager.within?/2`; separators are allowed only to represent real nested
  folders under that root.
- Symlink escapes are refused using the same canonical/realpath posture as
  `FileManager`; tests seed hostile in-vault symlinks.
- Only `.md` and `.markdown` files appear in the Notes tree.
- Creation supplies `.md` when omitted and refuses clobbering.
- Save is atomic: write a same-directory temporary file, sync/close as practical,
  then rename over the destination. Never truncate the live note before the new
  bytes exist.
- A reasonable UTF-8 size cap protects LiveView memory; oversized/binary files
  are visible as unsupported rather than loaded into the socket.
- Delete uses the app's existing explicit confirmation posture. A later Trash
  phase may make it recoverable; R1 must state honestly if deletion is permanent.

### Change propagation

Internal create/save/folder-create/delete/move operations broadcast a Notes
PubSub event carrying the path and, for saves, the new revision. External editors
do not broadcast. The shipped editor checks the current revision before every
save, and the `NoteEditor` hook also asks for a check:

- when the browser/window regains focus;
- on a 20-second tick, and only while a note is open.

A check on a clean editor adopts the newer file silently — refusing to show it
would be the surprising half. A check with a draft in flight raises the same
conflict banner a save would, which is what turns "someone else edited this"
from a silent overwrite into a decision.

Do not add a filesystem-watcher dependency for R1 unless the focus/revision
contract proves inadequate. A watcher can be evaluated later and must coalesce
atomic rename events rather than treating them as delete/create flicker.

---

## Phase 0 — Lock the language and data migration contract — COMPLETE

- Add `"activity"` and `"notes"` as distinct Home registry entries.
- Decide the exact display copy: **Activity** in the rail; **BC Minutes** inside
  the panel.
- Record that `journal/` stays in place and existing content is never copied into
  `notes/` automatically.
- Scan the generated Introduction, job descriptions, command catalog, user
  guide, Explore tutorials, README, and tests for “Notes record,” “daily
  minutes,” and `journal_*` assumptions.
- Write the new single-log rule before changing the UI:
  “Activity is the one Buster Claw activity log. Notes is the user's notebook.”
- Preserve `journal_append` and `journal_read` for compatibility. Consider
  friendlier `activity_append`/`activity_read` aliases only after the UI ships;
  do not break job files and agents for naming purity.

**Acceptance:** a test walks every Home registry key through the guard; generated
Introduction has exactly one automatic activity destination and explicitly says
Notes is not it.

**Delivered 08-08-26:** the registry and rendered guard share the seven-entry
order; agent orientation, job seeds, catalog descriptions, Explore copy, and
tests now name Activity as the one automatic log and Notes as the user's
notebook. No journal file or command moved.

---

## Phase 1 — Move today's minutes to Activity — COMPLETE

- Extract/rename the current Journal component to `ActivityComponent`.
- Change its root DOM id to `home-activity`; retain stable child ids for day rail
  and reading pane.
- Remove the operator append composer from the Activity UI.
- Preserve historical operator entries and source markers.
- Keep local-date behavior and the fresh-day empty state.
- Add `ActivityReport.summary/1` cards. Metrics are labelled “last 7 days” (or
  the chosen window), never implied to be counts for the selected document.
- Re-stream the day rail on journal append and preserve the selected day unless
  the user is looking at today.
- Update `StatusLive.handle_info({:journal_appended, ...})` to target the Activity
  component only when it is mounted; an update while another tab is active must
  not crash or discard the broadcast contract.

**Acceptance:** existing journal files render unchanged under Activity; an agent
append appears live; the UI has no way to edit or delete historical minutes;
Chat/Calendar/Phone/Studio state behavior is unchanged.

**Delivered 08-08-26:** `JournalComponent` became a purpose-built, read-only
`ActivityComponent`; the operator composer is gone; `home-activity`, the day
stream, sanitized reading pane, four summary cards, empty state, and live journal
refresh all have focused LiveView coverage.

---

## Phase 2 — Notes R1: safe create, type, save, preview — COMPLETE

Start from the old `BusterClaw.Notes` design visible before commit `a1d0b5e`, but
write the durability contract first.

R1 includes:

- create a note or folder;
- list Markdown files beneath `notes/`;
- open and type in a note;
- 600–900 ms debounced autosave plus explicit Cmd/Ctrl+S;
- clear `Unsaved` → `Saving…` → `Saved` → `Conflict` status text;
- sanitized live Markdown preview;
- rename, move, and confirmed delete;
- responsive file rail and preview toggle;
- empty, loading, unsupported-file, filesystem-error, and conflict states.

The form is driven by `to_form/2` and imported `<.input>` components. Key forms,
buttons, rails, editor, preview, and save status get stable DOM IDs. Note lists
use LiveView streams; filesystem contents are refetched and the stream reset for
search/filter/tree changes.

The editor hook owns only browser ergonomics (keyboard shortcuts, focus revision
check, preserving selection). File content and save authority stay in the
LiveComponent/context. Any hook-managed DOM has its required unique id and
`phx-update="ignore"` only around the exact node the hook owns.

**Conflict UX:** stop autosaving, keep the user's draft in the textarea, show the
new disk revision, and offer:

- Copy my draft;
- Reload disk version;
- Compare (Phase 3 if necessary);
- Overwrite only behind an explicit confirmation.

**Acceptance:** create → type → save → reload round-trip writes a readable `.md`
file; an external write between open and autosave produces Conflict and neither
version is lost.

**Delivered 08-08-26.** The context rejects traversal and symlink entries, skips
dot-entries, lists nested `.md`/`.markdown` files grouped folders-first, refuses
clobbering on create *and* on rename/move, caps text size, writes through
same-directory temporary files, and uses SHA-256 byte revisions. The UI creates
folders and files notes into them, renames and moves in one submission, halts
autosave on conflict while keeping the draft (copy, reload, or confirmed
overwrite), and shows oversized or non-UTF-8 files as unsupported rather than
loading their bytes into the socket. `Compare` was not built: with the draft
copyable and the disk version one click away, a diff view is Phase 3's problem if
anyone actually wants it.

**Where the save states come from,** because a status chip that guesses is worse
than none:

| State | Authority | Why not elsewhere |
|---|---|---|
| `Unsaved` | the `NoteEditor` hook's `note_dirty` | `phx-debounce` means the server hears nothing for 700 ms; the server cannot know the draft moved |
| `Saving…` | CSS on LiveView's `phx-change-loading` | the in-flight save is over before an assign made during it could paint |
| `Saved` / `Conflict` / `Save failed` | `NotesComponent` | only the write knows |

The hook announces dirt once per clean→dirty transition, not once per keystroke,
and stays quiet during a conflict — where autosave has stopped and the banner,
not the chip, is the status.

**The file it grew into.** `NotesComponent` reached ~810 lines, so the markup
came out as `BusterClawWeb.Notes.Rail` and `BusterClawWeb.Notes.Editor` (pure
function components; state and every save decision stay in the LiveComponent).
All three are named in `scripts/check_file_sizes.sh`, so Phase 3's search and
link work has to raise those caps deliberately rather than quietly.

---

## Phase 3 — Find and link notes like a notebook — NOT STARTED

The feature becomes meaningfully Obsidian-like here, without building a plugin
platform.

### Search

- Search filename/title and body, case-insensitive.
- R1 implementation may scan a bounded local vault with `Task.async_stream/3`,
  `timeout: :infinity`, and back-pressure; publish measured thresholds.
- If vault size makes scans slow, add a SQLite FTS index whose rows are a cache of
  Markdown files. Files remain the source of truth and rebuilding the index is
  always safe.
- Search results include a short escaped snippet and open the note at minimum;
  jumping to a line is later polish.

### Wiki links and backlinks

- Parse `[[Note]]` and `[[Folder/Note|Label]]` outside fenced code blocks.
- Render known links as internal note buttons and missing links as “create this
  note” affordances.
- Backlinks are computed from the vault/index and shown in the Preview pane.
- A rename updates links only through an explicit preview/confirmation; silently
  rewriting every note is too large a mutation for a filename change.

### Keyboard and focus

- Cmd/Ctrl+N: new note dialog.
- Cmd/Ctrl+P: note switcher/search.
- Cmd/Ctrl+S: immediate save.
- Escape: close switcher/preview overlay, never discard a draft.
- Arrow/key navigation in results has visible focus and screen-reader labels.

**Acceptance:** links and backlinks survive reload, code-fence false positives are
covered, missing-link creation is path-safe, and keyboard paths have JS tests.

---

## Phase 4 — Agent collaboration without returning to one muddled log — FOUNDATION ONLY

Add a narrow command family backed by the same Notes context:

- `note_list`
- `note_read`
- `note_create`
- `note_save` with expected revision
- `note_search`

Do not give the agent a raw absolute-path write command. Mutating commands use
the existing trust tiers and Sentinel auditing, with note path and revision but
not entire private note bodies in audit metadata.

Update the generated Introduction:

- `journal_append` remains mandatory for Buster Claw activity.
- `note_*` is for user-authored reference material and only when requested.
- producing a report still belongs in Documents/Library unless the user asks for
  it in Notes.

When an agent command saves an open note, PubSub triggers the same revision check
and conflict UI. The browser must never silently replace a local unsaved draft.

**Acceptance:** an agent-created note appears in the open Notes rail without tab
switching; an agent edit colliding with a user draft preserves both versions.

---

## Phase 5 — Polish after measured use — NOT STARTED

Candidates, not R1 promises:

- frontmatter-aware title/tags;
- tag browser;
- command palette actions;
- outline generated from Markdown headings;
- recoverable `.trash/` instead of permanent deletion;
- daily-note template in the Notes vault (distinct from Activity minutes);
- attachments under a note-assets directory with safe relative embeds;
- filesystem watcher for instant external-editor updates;
- graph view only if backlinks prove users need a graph rather than a list.

Explicitly out of scope until requested: Obsidian plugin compatibility,
collaborative CRDT editing, proprietary sync, WYSIWYG rich text, and storing note
bodies in Ecto.

---

## Test map

### Evidence at Phase 2 close (08-08-26)

- Full Elixir suite: **2,824 tests, 3 doctests, 0 failures**. The two
  browser-controller failures the earlier checkpoint recorded
  (`ClawConfirmTest`, `BrowserHomeControllerTest`) are green again.
- **Run the suite with `MIX_TEST_PARTITION=<lane> mix test` in this checkout.**
  Other sessions share the working tree, and an unpartitioned run collides on the
  one SQLite file — the failure reads `Exqlite.Error: Database busy` at
  `Conversations.ensure_seeded/0` on mount, which looks like a mount bug and is
  not one.
- Domain coverage proves create/save/read/list/delete, stale-revision conflict
  recovery, nested Markdown discovery, symlink exclusion, traversal rejection,
  sanitization, duplicate refusal, rename/move without clobbering, folder
  listing, dot-directory invisibility, folders-first ordering, and oversized
  files listed-but-unread.
- LiveView coverage proves Markdown create/edit/preview persistence, visible
  conflict recovery without disk overwrite, folder create → file → rename/move,
  `note_dirty` → `Unsaved`, ⌘S submit, clean reconciliation vs conflicting
  reconciliation, the preview toggle, the unsupported pane, read-only Activity,
  live journal refresh, and Activity's far-right registry position.
- JS: `bun test assets/js` — 142 passing, including `note_keys.test.js` for the
  save chord and the dirty-announcement suppressions.
- A new `BusterClawWeb.HooksRegisteredTest` asserts every `phx-hook` in `lib/`
  exists in `assets/js/hooks/index.js`. `render_hook/3` never loads JS, so an
  unregistered hook is a silently dead interaction with a green suite — the
  failure mode this repo has already shipped once.
- `scripts/check_docs_drift.sh`, `check_cycles.sh`, `check_file_sizes.sh`,
  `check_rust.sh`, `mix format --check-formatted`, and `mix credo --strict` all
  pass.

### `BusterClaw.Journal` / Activity

- Existing append/list/read/date/path tests remain green.
- Activity renders legacy agent and operator entries.
- Journal PubSub updates an open Activity panel.
- Activity summary agrees with `ActivityReport` fixtures.
- Activity is read-only in rendered controls.

### `BusterClaw.Notes`

- create/save/get/list/rename/move/delete round-trip;
- nested paths stay under the vault;
- `..`, absolute paths, nulls, hidden escape forms, and hostile symlinks fail;
- only Markdown extensions are listed/editable;
- create refuses clobbering;
- save is atomic under injected write/rename failure;
- stale revision returns conflict with both bodies recoverable;
- UTF-8/size/binary boundaries are explicit;
- search and backlink parsing cover code fences, aliases, and missing targets.

### Home LiveView

- Chat remains default.
- Activity and Notes are separate rail buttons accepted by the one registry guard.
- Each panel mounts only when selected and carries stable root IDs.
- Notes create/edit/save assertions use those IDs and `has_element?/2`, not raw
  HTML comparisons.
- selection/draft behavior survives the agreed tab-switch contract.
- streamed rail empty state follows the LiveView stream idiom.
- remote/plain-browser Notes editing works without Tauri.

### JavaScript

Covered by `assets/js/lib/note_keys.test.js` (bun) plus the LiveView tests that
exercise the events the hook pushes:

- Cmd/Ctrl+S mapping — **done**;
- conflict halts the dirty announcement, because autosave has stopped — **done**;
- focus/tick revision check — the event and both its outcomes are covered
  server-side; the listener wiring itself is not, and there is no DOM harness in
  this repo to cover it with.

Still owed, and waiting on Phase 3's keyboard work or a DOM harness:

- Cmd/Ctrl+N;
- debounce never submits after component destruction;
- selection/caret survives LiveView preview patches;
- reduced-motion and narrow-layout interactions.

Run focused context, LiveView, and JS tests throughout; finish the completed
implementation with `mix precommit`.

---

## Definition of done

The core product split satisfies the questions below, and Notes is now a vault
you can organize as well as write in. The roadmap remains in progress because
finding is not building: search, wikilinks, backlinks, the keyboard paths, and
the `note_*` command family are still ahead.

The split is done when a new user can answer these without explanation:

- “Where do I see what Buster Claw did?” → **Activity / BC Minutes**.
- “Where do I write my own Markdown?” → **Notes**.
- “Can another editor read the files?” → yes, ordinary `.md` under the workspace.
- “Can an agent edit one while I am typing?” → it can try, but Buster Claw shows
  a conflict and loses neither version.
- “Did we create two activity logs?” → no. Activity is the one log; Notes is a
  notebook.
