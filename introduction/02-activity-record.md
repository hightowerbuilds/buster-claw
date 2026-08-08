## The Activity record — the one place activity is logged

**There is exactly one activity log, and it is the homepage Activity tab.**
Everything that happens in Buster Claw goes there and nowhere else. If you
find yourself wondering where to write down what you just did, the answer is
always this and never anything below it.

On disk it's `journal/` — one `YYYY-MM-DD.md` per day. Don't write those
files by hand; append through the command surface so each entry lands
chronologically with a timestamp (the day's document is created on its first
entry):

    ./buster-claw run journal_append --json '{"text":"what happened"}'
    ./buster-claw run journal_read                       # today's activity
    ./buster-claw run journal_read --json '{"date":"2026-07-20"}'

Append throughout the day: every command run, reply sent, and notable
decision. Historical `— OPERATOR` entries remain valid context, but the
Activity UI is now read-only. The homepage Notes tab is a separate notebook
owned by the operator; do not dump routine activity into it.

### What is NOT the activity log

Several things in this workspace look like a place to record what happened.
None of them is. Writing your activity into any of them means the user opens
the Activity tab and sees a gap where your work should be.

| | What it actually is |
|---|---|
| `.buster-claw/dispatch/<date>/Dispatch.{md,jsonl}` | A **machine projection** of queue events, written automatically. Never hand-authored. |
| `activity_report` | A **computed read** over dispatch rows. It reports; it doesn't record. |
| Run summaries (`memory_search`) | Captured **automatically** per run. You never write these. |
| The Library (`document_save`) | **Artifacts** — reports, captured pages, research. Not a diary. |
| The Notes vault (`note_*`) | The **operator's own notebook**. Yours to touch only when they ask. |

The split that resolves almost every case: **the Library holds artifacts,
Activity holds what happened, and Notes holds the operator's writing.**
Produce a research report → `document_save` it, then write one Activity entry
saying you produced it and where it lives. The artifact, record, and notebook
are different objects with different jobs.

### The Notes commands — the operator's notebook, on request

`notes/` is the operator's Markdown, shown on the homepage Notes tab. Five
commands reach it, and the rule for all five is the same: **only when the
operator asked for a note.** A finding you decided to write down is a Library
document; what you did is an Activity entry; a note is what they asked you to
write or change in *their* notebook.

    ./buster-claw run note_list
    ./buster-claw run note_search --json '{"query":"loopback"}'
    ./buster-claw run note_read --json '{"path":"Projects/Launch.md"}'
    ./buster-claw run note_create --json '{"title":"Trip plan","folder":"Projects","body":"# Trip plan\n"}'
    ./buster-claw run note_save --json '{"path":"Trip plan.md","body":"...","revision":"sha256:..."}'

Paths are always **relative to the vault** — there is no absolute-path write,
and there is no note delete: deleting a note is the operator's own action in
the UI.

`note_save` needs the `revision` that `note_read` gave you. If the file changed
in between — the operator may literally be typing in it — the save is refused
and you get the current revision back. Re-read, merge what you were asked to
change into the newer text, and save again. Never work around a refusal by
creating a second copy of the note.

Editing a note that is open in the UI is fine and expected: the editor notices,
keeps the operator's unsaved draft, and shows them a conflict rather than
letting either side vanish.

### notesthatfloat.com is a different thing entirely

**notesthatfloat.com** is a separate notebook the operator uses — a real,
useful product, and **not part of Buster Claw**. It is not connected to this
app, this workspace, or Buster Claw's Notes tab; the similar name is the only
thing they share.

So: never write Buster Claw activity there, and never read it as context for
what happened in the app. If the operator mentions "my notes", ask which one
they mean rather than guessing — the two live in completely different places
and an entry in the wrong one is simply lost.

