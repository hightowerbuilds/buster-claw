---
name: pockets
description: What a Pocket is, when to look in one, and how to read it — the pocket_* verbs, why a Pocket's own prose is the part worth reading, and the one thing on this surface you can never do.
tier: safe
enabled: true
handler_kind: reference
---

# pockets

A **reference** skill: read this, then use the `pocket_*` commands. Run each
verb through the CLI:

    ./buster-claw run pocket_list --json '{}'

## What a Pocket is

A **Pocket is a named, typed folder of the operator's own material** — icons,
badges, banners, fonts, media, page bundles — with a `POCKET.md` manifest
saying what it is and what it is *for*.

That last part is the whole reason Pockets exist and are not just directories
with nicer names. A folder can hold six PNGs. It cannot tell you that the 32px
versions are the ones that read at menu-bar size, that `claw.png` is the master
and the small ones are regenerated from it, or that this pile is the operator's
brand marks rather than screenshots they forgot to delete. A Pocket carries all
of that, written by the operator, and `pocket_describe` hands it to you.

Each Pocket declares:

- **`kind`** — `icons`, `badges`, `banners`, `fonts`, `media`, `pages`, or
  `free`. What it holds, which decides how its files are validated and shown.
- **`description`** — one line, from the operator.
- **`roles`** — the slots a surface may bind it to (a background, for example).
  A Pocket may declare a role nothing asks for yet; it simply stays inert.
- **the body** — free prose below the frontmatter. **Read it.**

## The three verbs

| Verb | Arguments | Answers |
|---|---|---|
| `pocket_list` | none | What Pockets exist, their kind, description, roles, file count, and whether each is valid |
| `pocket_describe` | `name` | One Pocket in full: its prose body, and every file with size and whether it is text |
| `pocket_read` | `name`, `file` | The text of one file inside it |

    ./buster-claw run pocket_list --json '{}'
    ./buster-claw run pocket_describe --json '{"name":"hazard-icons"}'
    ./buster-claw run pocket_read --json '{"name":"hazard-icons","file":"palette.css"}'

`file` is a **bare filename**, exactly as `pocket_describe` listed it. Not a
path. Separators, `..` and leading dots are refused before the filesystem is
touched, and a symlink is refused rather than followed — so you cannot read
your way out of a Pocket, and there is no argument that would let you try.

## The one thing you can never do here

**You cannot mount, unmount, or change where a Pocket's bytes live.** A Pocket
may be backed by a folder anywhere on the machine, through a record the app
keeps *outside* the Pocket. That record is written by the operator in the UI and
by nothing else. There is no command for it, at any tier, and there never will
be — its absence is the enforcement, not a permission check you might one day
pass.

Two consequences worth holding on to:

1. **Editing `POCKET.md` relabels a Pocket. It never moves one.** The manifest
   holds description; it holds no permission and no path. If you write
   `writable: true` or a source directory into a manifest, nothing happens —
   those are not fields, on purpose, because a manifest is a file you can write.
2. **If the operator wants a folder available as a Pocket, say so and stop.**
   The right answer is "open Pockets and add it" — not an edit you make, and
   not a symlink. Symlinks are treated as an attack everywhere in this app and
   will be refused; that is deliberate and is not a bug to route around.

## Reading files, and what comes back

`pocket_read` returns `content` only for **text**. A binary file — a PNG, a
`.ttf`, an audio clip — still *succeeds*, and returns `text: false`,
`content: null`, and its size.

That is the correct answer, not a failure. Bytes of an icon in a transcript are
noise: you cannot see them, they cost the operator context, and the file's
purpose is to be *displayed* by a surface that can render it. Describe it —
name, size, kind of Pocket it sits in — and move on. **Never** ask for a binary
file twice hoping for different bytes, and never claim to have looked at an
image.

Text is capped at 64 KB; past that `truncated` comes back `true` and you have
the first 64 KB. `pocket_describe` marks each file `text: true` or
`text: false`, so check there before reading rather than guessing from an
extension.

## When to look in a Pocket

- **The operator refers to "my icons", "my fonts", "the banners", "that image I
  put in".** Run `pocket_list` before assuming those things are not on the
  machine. This is where the operator's own material lives.
- **Before proposing that anything be downloaded or generated.** If the operator
  already has hazard glyphs in a Pocket, generating new ones is worse than
  useless — it competes with their own work.
- **When a surface needs media and you are choosing what it should show.**
  Pockets declare `roles` for exactly this.
- **When you need to know how a set of files relate to each other.** The body is
  where a master file, a naming scheme, or a "regenerate these, don't edit them"
  rule is written down.

## Invalid is not missing

`pocket_list` reports broken Pockets in a separate `invalid` list with a reason
— `no_manifest`, `name_mismatch`, `invalid_name`, `unknown_kind`,
`invalid_roles`. That distinction matters and you should pass it on verbatim:

> "`typefaces` is there but its `POCKET.md` declares a different name, so it is
> not loading."

is a fixable, one-line problem. "You don't have a typefaces Pocket" sends the
operator looking for a folder that is sitting right there. `unknown_kind` and
`invalid_roles` are usually a typo in the frontmatter; `name_mismatch` means the
`name:` field disagrees with the directory, and **the directory is the truth**.

## What this surface does not do

- **No writing.** No verb here creates a Pocket, adds a file to one, deletes
  one, or edits a manifest. If the operator wants any of that, say plainly that
  it is theirs to do in the Pockets tab.
- **No reach outside a Pocket.** These verbs address Pockets and nothing else on
  the disk. Reading the operator's documents, notes or library is a different
  surface with different verbs; check the live catalog rather than guessing from
  this file.
- **No opinion about images.** There is no vision on this path. You can report
  that a file is 6 kB and named `claw-32.png`. You cannot report what it looks
  like, and saying otherwise is the one failure that costs the operator's trust
  outright.
