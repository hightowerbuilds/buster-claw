# 10-14-26 — The receipt the agent could never see

The operator named one consistent failure: email Buster Claw a photo of a
receipt, ask for an invoice with the picture in it, and watch it fail the same
way every time. The diagnosis took less time than expected because there was
nothing to debug. **Inbound Gmail attachments had never been built.**

The 05-17 Gmail roadmap deferred them in one line — *"do not implement
attachment download in v1 (record presence in frontmatter only)"* — and the
frontmatter note was never written either. `Parser.parse_message` kept
`text/plain` and `text/html` and silently dropped every part with a filename.
`gmail_read` printed the raw payload, so the model could *see* an
`attachmentId` buried in JSON and had no verb that turned it into bytes. The
worst of both worlds: it knew the receipt existed and could not reach it.

Outbound was the opposite story. `Gmail.Mime` has composed `multipart/mixed`
with workspace-fenced attachments since `1728e64`. So the invoice half of the
loop was already possible; only the intake half was missing.

---

## What landed on main

| | |
|---|---|
| `f8d5653` | Inbound Gmail attachments, end to end: listed by the parser, fetched by the client, saved into the workspace by one fenced store, named on `Dispatch.md`, and carried back out on `dispatch reply --attach`. +1 command (192 → 193). |
| (second commit) | The Drive fences. `drive_download` / `drive_export` destinations and the `drive_upload` source all go through one `Helpers.fenced_workspace_path/1`; a Google-native file is turned away before `alt=media` with a pointer to `drive_export`; the fence refusals finally render as sentences instead of "unexpected error". |

First commit 22 files, **+723 / −71**; second 7 files. `mix precommit` green
at 3,414 tests.

## The pieces

- **`Gmail.Parts`** (new, 125 lines) owns the MIME tree walk, the header map,
  base64url decoding and the attachment listing. `Parser` shrank 309 → 202 and
  its cap ratcheted 260 → 223. Each parsed message now carries `attachments:`
  — metadata only, never bytes, so `gmail_read` stays JSON-printable.
- **`Gmail.attachment/4`** hits `messages.attachments.get` with a 60 s receive
  timeout (the 10 s default was sized for metadata, not a 20 MB photo).
- **`GmailAttachments`** (new, 289 lines) is the one place inbound bytes touch
  disk: `attachments/gmail/<message-id>/<name>` under the workspace root.
  Destination fenced with `FileManager.within?/2` before any fetch; sender
  filenames reduced to a safe basename with same-name collisions suffixed;
  a 25 MB per-file cap; one failed download never loses its siblings. Gmail
  inlines small attachments as `body.data` with no id — those are decoded out
  of the raw message with no round trip.
- **`gmail_attachment_download`** — `:safe` `:read`, narrows by
  `attachment_id`, `filename`, or 1-based `index`; default is all.
- **`GmailSync`** downloads attachments for **trusted senders only** — the
  same line that decides whether mail becomes agent work decides whether its
  files land in the workspace the agent reads. Untrusted mail is archived with
  the attachment *list* (name, type, size, id) and a "not downloaded" note, so
  the operator can pull one deliberately. The Library doc gains an
  `## Attachments` section and a `has-attachments` tag; the queue item carries
  the saved paths in `metadata["attachments"]`.
- **`Dispatch.md`** names each saved file under `- attachments:` — the agent
  learns a receipt arrived from the fridge, not from re-reading the mail.
- **`dispatch reply --attach <path>`** (repeatable) rides through to
  `Gmail.Mime`, which already refuses anything outside the workspace. Tested
  both ways: a workspace invoice goes out as `multipart/mixed`; `/etc/hosts`
  fails before Google is called and the item stays queued.
- **Mail Triage brief** (seed digest appended): where attachments land, how to
  look at one, how to re-pull, and the receipt → invoice recipe — read the
  image, write the invoice as HTML or Markdown in the workspace, reply with
  both attached.

## What was decided, and why

- **Workspace file, not Google Doc, for the invoice.** Docs API
  `insertInlineImage` requires a *publicly reachable* URI; a private Drive file
  does not qualify without sharing it "anyone with the link", which is the
  wrong default for a receipt. The brief steers to a workspace HTML/Markdown
  invoice sent back on the thread. A Docs path can come later behind an
  explicit share flag.
- **Trust gates the bytes.** Downloading every stranger's attachment into the
  directory the agent browses would be an unprompted write of untrusted
  content. Listing is free; fetching is deliberate.
- **The guard was broken on purpose.** With the fence replaced by `if true`,
  the outside-workspace test failed on the `flunk` inside the HTTP stub; put
  back, green. Per the house rule.

## The Drive fences (second commit)

The first commit's "left open" list had two Drive items. Reading them closely
turned up a third that mattered more than either: **`drive_upload` read any
path the app could read and shipped it to Drive.** That is the exact shape
`Gmail.Mime`'s attachment fence was written for in `1728e64` — an exfiltration
channel named by a path argument — and the Drive verb had never been given the
same fence. Now all three Drive path arguments go through
`Helpers.fenced_workspace_path/1`; the default download name is reduced to a
safe basename (a Drive file named `../../.zshrc` is just a file); `drive_export`
names its output after the document plus the extension the MIME type implies
(`Q3 invoice` → `Q3_invoice.pdf`, where before it was `Q3 invoice` with no
extension at all).

The other find: **every fence refusal in the app rendered as "unexpected
error".** `{:attachment_outside_workspace, _}`, `{:file_unreadable, _, _}`, the
new `{:outside_workspace, _}` — none had an `ErrorFormatter` clause, so an
agent that named a bad path learned nothing it could act on. They are
sentences now, naming the path and the rule. The fence was broken on purpose
once more (`drive_upload` with the plain resolver) and the test failed on
`/etc/hosts`; restored, green.

## Left open

- Live walk not performed: a real receipt photo through a real trusted-sender
  sync on this machine. Every seam is unit-tested against `Req.Test` stubs
  shaped from the Gmail API; the suite cannot prove Google's actual payload
  shape for an iPhone photo mailed inline.
