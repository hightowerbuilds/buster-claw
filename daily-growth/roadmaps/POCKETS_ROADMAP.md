# Pockets — folders that know what they are for

**Scoped 08-08-26 · Status: SCOPED, nothing built. UI placement answered by the
operator the same day — [D9](#d9--the-ui-is-a-home-sub-tab-and-it-is-minimalist),
a minimalist Home sub-tab.**

> ### The one-sentence version
>
> **A Pocket is a named, typed folder of *data* — icons, badges, banners, fonts,
> media — that surfaces bind to by *role* rather than by path, and that may be
> backed by a directory anywhere on the machine through a **mount the app
> records**, not a symlink the filesystem hides.**

> ### The reframe this roadmap turns on
>
> The operator's ask was to *"strengthen the symlink."* Reading the code says the
> honest way to strengthen it is to **replace it**. A symlink carries no author,
> no purpose, no permission, and no revocation — and three separate layers of our
> own code exist specifically to defeat one. Every property Pockets wants is
> metadata a symlink structurally cannot carry, so the app carries it instead.
>
> Same felt result: *your data is right there in the folder.* Different
> mechanism: **authored, listed, revocable, per-pocket permissioned, and visible
> in the UI.**

> ### Read this before planning around it
>
> **This is the mechanism that killed the last one.** `EXTENSIONS_ROADMAP` shipped
> 08-07 and was deleted 08-08 because it lost its only consumer and became ~1,400
> lines serving nothing. Pockets is a *more general* mechanism than extensions
> was. It therefore carries a *higher* version of the same risk, and the only
> real defence is [D7](#d7--backgrounds-migrates-in-this-roadmap-or-the-roadmap-stops):
> **`backgrounds/` migrates onto Pockets inside this roadmap.** If Pockets cannot
> absorb a drawer that already exists, already holds images, and already has a
> UI, it is not ready to hold anything else and should not be built.

---

## Contents

- [Part I — What the code already tells us](#part-i--what-the-code-already-tells-us)
- [Part II — Locked decisions](#part-ii--locked-decisions)
- [Part III — What a Pocket is](#part-iii--what-a-pocket-is)
- [Part IV — The mount: the strengthened symlink](#part-iv--the-mount-the-strengthened-symlink)
- [Part V — Roles, and why they are the point](#part-v--roles-and-why-they-are-the-point)
- [Part VI — The phases](#part-vi--the-phases)
- [Part VII — What this does not solve](#part-vii--what-this-does-not-solve)
- [Part VIII — Risks](#part-viii--risks)
- [Part IX — Open questions for the operator](#part-ix--open-questions-for-the-operator)

---

## Part I — What the code already tells us

Five findings from reading. Two of them make the work **smaller** than the pitch,
one makes it **larger**, and one is a correction to something I said out loud
before reading carefully enough.

### I.1 — The workspace registry is closed at the top level only

`BusterClaw.Workspace` declares ~25 top-level entries, and
`test/buster_claw/workspace_test.exs:106` fails the build if any module in `lib/`
reaches for an undeclared top-level path. That guard exists because the folder
grew to twenty entries with no list describing the whole.

**Correction to my first read.** I said Pockets collide with that guard head-on.
They do not. The guard checks **top-level names**; `pockets/` is one declared
entry and every Pocket is a *child* of it. The registry already says so in its own
words, about audio:

> *"Those two are NOT declared here — this registry describes top-level entries,
> and they are inside one."* — `workspace.ex`, on `sounds/music/` and
> `sounds/studio/`

So there is direct, shipped precedent for a declared parent with
user-materialised children. **One new registry entry, tier `:on_demand`, and the
guard keeps every bit of its value.**

### I.2 — Symlinks are currently treated as an attack, and correctly so

Three layers defeat them, deliberately:

| Layer | Mechanism | Where |
|---|---|---|
| Containment | `within?/2` canonicalizes **every path component** with `read_link` | `file_manager.ex:212`, `:223` |
| Notes vault | walks with `lstat`, refuses `:symlink` typed entries | `notes.ex:348` |
| Attachments | `lstat` not `stat`, so a link is *seen* as a link and refused | `attachments.ex:502` |

The comment on `canonical/1` says the purpose in one line: *"so a symlink inside
`base` that points outside it can't slip past the lexical containment check."*

**This is the finding that decides the architecture.** At the filesystem level
there is no difference between the link the operator made on purpose and one an
attacker planted. Our guards cannot tell them apart because *nothing* can. A
Pocket built on `File.ln_s/2` would be fought by our own security layer on every
read, and the only way to make it work would be to weaken the guard for everyone.

### I.3 — Serving is already broader than containment

`WorkspaceFileController.image/2` serves any image under **`$HOME` or the
workspace root** (`workspace_file_controller.ex:75-77`), because the Workspace tab
can already browse anywhere under home. Documents do not — `show/2` is
workspace-contained via `read_file/2`.

**This makes the work smaller.** A Pocket of images living outside the workspace
is already servable to the webview today, provided it is under home. It is
*agent* containment, not *display*, that the mount has to solve. And because
serving goes through our own controller, every Pocket asset is **same-origin** —
so the strict CSP (`script-src 'self'`, `content_security_policy.ex:77`) is not an
obstacle for images or fonts.

### I.4 — There is no native folder picker, and that is a design opportunity

`desktop/tauri/` has **no dialog plugin** — no `tauri-plugin-dialog`, no `rfd`, no
`pick_folder` command anywhere in `blocklist.json`, `browser/`, `clinch.rs`,
`main.rs`, `terminal.rs`, `voice.rs`, or `workspace.rs`. The workspace root is
chosen by **typing a path into a text field** (`workspace_live.ex:402`).

Adding a Tauri plugin means a new dependency, a new capability registration, and
`build.rs` lockstep — and this codebase has already lost a feature to exactly that
omission once (co-presence commands were ACL-dead until 07-17).

**So don't add one.** The Workspace tab *already browses the whole home
directory.* "Mount this folder as a Pocket" belongs as an action in the file
browser, on the folder the operator is already standing on. **Zero new native
surface, and the operator picks a folder by looking at it.**

### I.5 — The extensions post-mortem left one rule that applies unchanged

D1 from `08-08-26-extensions-roadmap.md`: **an extension is never executable
code** — a fact about the BEAM having no code sandbox, not a policy, and it does
not expire.

Pockets hold *data*. They sit inside that rule rather than fighting it, which is
the strongest structural argument that this is the right shape where
extensions-as-code was not. See [D8](#d8--an-app-pocket-is-a-page-bundle-not-a-program)
for the one item on the operator's list that tests it.

---

## Part II — Locked decisions

Revisit any of these if they turn out wrong, but change them **in this document**
rather than in code.

### D1 — A Pocket holds data. Never code.

Inherited verbatim from extensions D1. No `.beam`, no Elixir, no LiveView, no
executable bit that the app itself runs. A Pocket cannot grant itself a trust
tier because it has no way to run at all.

### D2 — The manifest is Markdown with frontmatter, named `POCKET.md`

Matching `Skills` (`skills.ex:27`), job descriptions, and trusted-sender lists:
**file-first, git-diffable, operator-editable, discovered at runtime with no
recompile.** A JSON manifest would be the odd one out in this codebase and would
lose the free-text body where the operator says what the Pocket is *for*.

The name must equal the directory name, `[a-z0-9-]`, exactly as a skill's name
must equal its filename stem — that check already exists and is already tested.

### D3 — Mounts are recorded by the app. `within?/2` does not change.

The containment function stays exactly as strict as it is today. A *new*
resolver, `Pockets.resolve/1`, is the only thing that admits a path outside the
workspace, and it admits **only paths the operator explicitly registered**. A
planted symlink still fails everywhere it fails today.

This is the whole "strengthened symlink," and it is a small amount of code. The
strength is not in the mechanism; it is in the fact that **the link has an author,
a record, and an off switch.**

### D4 — The agent may read a mounted Pocket. It may never mount one.

The Clinch already solved this shape once — *remote may **use** credentials, never
**manage** them*, enforced structurally by an IPC split rather than a policy
check. The analogue here:

> **Mounting is an operator act in the UI. There is no `pocket_mount` command, at
> any tier, ever.**

Enforced the same way: the mount registry is written by one surface, and the
command layer has no verb that reaches it.

### D5 — Mounts are read-only by default; write is per-Pocket and never unattended

A mount points at a folder the operator chose *outside* the sandbox everything
else lives in. Read is the useful case (my icons, my exports, my font library).
Write is occasionally wanted and always the dangerous one.

Default read-only. Write is a per-Pocket opt-in in the manifest, and an
**unattended run never gets it** regardless of what the manifest says — the same
split `sound_apply` and the browser's purchase gate already use.

### D6 — Surfaces bind to a *role*, not to a folder name

`:app_icon`, `:badge`, `:banner`, `:home_background`, `:terminal_background`,
`:font`. A surface asks the role what to show. This is the difference between
Pockets and "a folder with a nicer name," and it is the reason the mechanism pays
for itself.

### D7 — `backgrounds/` migrates in this roadmap, or the roadmap stops

Non-negotiable, and it is the direct lesson of the extensions deletion. Phase 2
migrates `Appearance`'s image pool onto Pockets. If that migration is ugly,
Pockets has the wrong shape and **the correct response is to stop**, not to ship
the mechanism and hope a consumer arrives.

### D8 — An "app" Pocket is a page bundle, not a program

The operator's list was *"images, apps, fonts, other data."* Three of those four
are data. An "app" is the one that tests D1.

**Locked:** an app Pocket is a directory of HTML/CSS/asset files served through
the existing local-trust page path (`pages/`, `docs/LOCAL_TRUST.md`), same-origin,
under the app CSP. That is already how the Manual ships. It is *not* a program the
BEAM loads, and it is not a new runtime.

### D9 — The UI is a Home sub-tab, and it is minimalist

**Operator call, 08-08.** Pockets are the operator's *material*, not a preference,
so they belong beside Notes and Activity rather than inside Settings.

Placement: **`chat · notes · pockets · calendar · phone · studio · explore ·
activity`** — directly after Notes, because those two are the operator's own
content and read as a pair. `activity` stays far right; it is the one automatic
log and has been anchored there since 08-08.

**Minimalist, stated as a constraint rather than a mood.** Two levels, one screen:

```
POCKETS                                    [ + New ]  [ Mount… ]

  hazard-icons        icons      6 files   ▪▪▪▪▪▪
  ntf-banners         banners    2 files   ▪▪
  typefaces           fonts     14 files   ↗ ~/Library/Fonts
  scratch             free       —         (empty)

──────────────────────────────────────────────────────────────
  ← hazard-icons · icons · 6 files · used by: app_icon, badge

  [img] [img] [img] [img] [img] [img]

  The 32px versions are the ones that read at menu-bar size.
```

**What that buys, and what it forbids.** A list, and one Pocket open. Nothing
else: no tree, no sidebar, no reordering, no drag handles, no inspector panel, no
preview modal. The `↗` is the only mount affordance and it is a *glyph*, not a
badge. The manifest body renders as plain prose under the contents, because the
operator wrote it to be read.

**Two things this decision costs, recorded now rather than discovered later:**

1. **The rail goes from seven tabs to eight.** That is a real crowding cost on a
   narrow window, and it is the first thing to re-examine if the rail starts to
   wrap. Pockets is not obviously more load-bearing than Studio or Calendar.
2. **`status_live.ex` is over its size cap already** (911 lines against a HELD cap
   of 891, as of 08-08) and is under active edit by another session. Adding a tab
   touches the one list at `status_live.ex:44` that feeds both the rail and the
   guard — *"they were two lists until 08-08, which is how Phone arrived as a
   button the server then refused."* **Add to that list and nowhere else**, and
   expect to owe an extraction rather than a cap raise.

The panel itself lives in its own component (`components/pockets_panel.ex`),
following `ExplorePanel` — so the LiveView gains a tab entry and a one-line render
call, not a feature.

---

## Part III — What a Pocket is

    <workspace>/pockets/
      hazard-icons/
        POCKET.md
        claw.png
        claw-32.png
        badge-live.svg
      ntf-banners/
        POCKET.md
        header.jpg
      typefaces/
        POCKET.md            # mounted → ~/Library/Fonts, read-only

`POCKET.md`:

```markdown
---
name: hazard-icons          # must equal the directory name, [a-z0-9-]
kind: icons                 # icons | badges | banners | fonts | media | pages | free
description: Claw marks and hazard glyphs for app icons and badges.
roles: [app_icon, badge]    # which slots this Pocket may fill
source: null                # null = local; otherwise an absolute mounted path
writable: false             # only meaningful when mounted; default false
---

The 32px versions are the ones that read at menu-bar size. `claw.png` is the
master — regenerate the small ones from it rather than editing them.
```

Everything below the frontmatter is the operator's own note, read by a person and
readable by the agent. **The description and body are the part a folder has never
been able to carry**, and they are most of why this is not just a directory.

**`kind` decides validation** (what file types are accepted, what caps apply).
**`roles` decides what may bind to it.** They are separate because a Pocket of
images might legitimately serve icons *and* badges, and a Pocket of images might
legitimately serve neither.

---

## Part IV — The mount: the strengthened symlink

### What actually changes

One new module and one new resolver. `FileManager.within?/2` is not touched.

```
Pockets.resolve(path)
  ├─ inside <workspace>/pockets/  → allowed (already contained today)
  ├─ inside a registered mount    → allowed, with that mount's permission
  └─ anything else                → refused
```

The mount registry is a file the app owns, listing `{pocket_name, absolute_path,
writable, mounted_at}`. It is written by the Workspace-tab action and by nothing
else ([D4](#d4--the-agent-may-read-a-mounted-pocket-it-may-never-mount-one)).

### Why this is stronger than a symlink, stated plainly

| | OS symlink | Recorded mount |
|---|---|---|
| Who made it | unknowable | recorded, with a timestamp |
| What it's for | nothing | the manifest says |
| Can the app refuse it | only by refusing all links | per-mount |
| Can the operator see the list | `find -type l` | a screen |
| Revoke | delete a file and hope nothing cached it | one row, one button |
| Survives our own guards | **no — by design** | yes, because it is declared |

The last row is the one that matters. **A symlink Pocket would be broken by our
own security code.** A mount is the same idea with the missing half supplied.

### The containment property that must hold

A mount widens what the agent can *read*. It must not widen what the agent can
*escape into*. So `Pockets.resolve/1` canonicalizes the resolved path the same way
`within?/2` does and re-checks it against the mount root — meaning **a symlink
planted inside a mounted folder still cannot escape that folder.** The mount is a
new root, not a hole.

---

## Part V — Roles, and why they are the point

Today `Appearance` hard-codes one drawer: `@subdir "backgrounds"`, `@max_images
8`, slots numbered 1–8, mode strings of the form `"image:<slot>"`
(`appearance.ex:41`, `:19`). It works, and it is the shape every future media
feature would otherwise be copy-pasted into.

Under roles, a background is *a Pocket bound to the `:home_background` role*, and
the next feature that needs user media — an app icon, a badge, a banner on a page
the operator is building — asks for a role instead of growing its own drawer.

**The migration is the proof.** `Appearance` keeps its public API
(`options/0`, `background/1`, `image_url/1`) so `AppearanceLive` and
`AppearanceController` do not move; underneath, its pool becomes a Pocket. If that
cannot be done without disturbing either caller, D7 fires.

The existing slot→path storage migrates the same way `Appearance` already migrated
its own per-surface layout into a shared pool — *"it rewrites `Settings` keys only
and never touches the files"* (`appearance.ex:26`). **That migration is written and
tested and is a working model for this one.**

---

## Part VI — The phases

Ordered so the trust expansion lands **after** the shape is proven and **before**
the polish — the mount is the point of the roadmap, so it cannot be last, but it
must not be first.

### Phase 0 — What has to be measured before building

Four unknowns that reading cannot settle. Half a day, and it is the phase that
makes the rest smaller.

1. **Does the packaged webview load an image from a path outside the workspace
   but inside home?** `image/2` says yes; WKWebView has surprised this codebase
   before. Test in the packaged app, not dev.
2. **What does the Tauri drag-drop event give for a dropped *directory*?** The
   attachments work established it gives paths for files. A folder may arrive as
   a path, or not at all. **If it arrives, dropping a folder onto the Pockets
   screen is the mount gesture** and I.4's browser action becomes the fallback
   rather than the primary.
3. **How many `Settings` keys does the `Appearance` pool migration actually
   touch?** Determines whether D7's migration is an afternoon or a week.
4. **Does `Frontmatter` accept a list value** (`roles: [app_icon, badge]`) or does
   it need a scalar? `Skills` uses JSON-in-a-string for `args`. If the parser is
   scalar-only, `roles` becomes a comma-separated string and D2 stands unchanged.

### Phase 1 — The Pocket, local only

`pockets/` registry entry (`:on_demand`, per I.1). `BusterClaw.Pockets` — a
types-only contract module first, then load, validate, list. `POCKET.md` parsing
with the `Skills` guards reused: name matches directory, invalid Pockets are
logged and skipped rather than crashing the list.

**No mounts. No roles. No UI** — the tab lands in Phase 2, beside the migration it
exists to make visible. A Pocket is a folder you can make by hand and the app can
describe back to you.

### Phase 2 — Roles, `backgrounds/` becomes the first consumer, and the tab

The role table. `Pockets.for_role/1`. Then the migration:
`Appearance`'s image pool becomes a Pocket, its public API unchanged, its
`Settings` keys rewritten in place with the files untouched.

**And the tab arrives here, read-only** — the list and one open Pocket, per
[D9](#d9--the-ui-is-a-home-sub-tab-and-it-is-minimalist). No creating, no
mounting, no deleting; just the two levels, so the migration has somewhere to be
*seen* landing. A `pockets/` folder the operator cannot look at is a folder they
will not believe in.

**This is the phase that decides whether the roadmap continues.**

### Phase 3 — The mount, and the surface that owns it

`Pockets.resolve/1`. The mount registry. The Workspace-tab action from I.4 (or
folder-drop, if Phase 0 says it works). Read-only by default; the `writable`
opt-in; the unattended refusal.

The tab gains its three affordances here and no others: **New**, **Mount…**, and
the `↗` glyph marking a mounted Pocket in the list.

Tests that must exist before this phase is called done:

- a planted symlink **inside** a mounted Pocket cannot escape it
- a path that merely *looks like* a mount root (`/Users/x/Pockets-evil` vs
  `/Users/x/Pockets`) is refused — the `<> "/"` boundary bug, tested explicitly
- an unattended caller is refused write on a `writable: true` Pocket
- there is no command in the catalog that can create or remove a mount (a lockstep
  test, the same idiom as the ACL suite)

### Phase 4 — The agent's reach

`pocket_list`, `pocket_read`, `pocket_describe` — and deliberately no more until
something wants more. Read verbs at `:safe`; any write verb `:restricted` and
gated. A reference skill teaching the agent what a Pocket is and when to look in
one.

### Phase 5 — Fonts and pages

`kind: fonts` — self-hosted, same-origin, which the CSP already permits (I.3).
`kind: pages` — the [D8](#d8--an-app-pocket-is-a-page-bundle-not-a-program) answer
to "apps," served through the existing local-trust path.

### Phase 6 — Open space

Deliberately empty. What Pockets should hold next is a question the first five
phases will answer better than this document can.

---

## Part VII — What this does not solve

**It does not make the agent safer.** A mount is a net *expansion* of what the
agent can read. D4 and D5 shape that expansion; they do not reverse it. Anyone
reading this roadmap as a security improvement has read it wrong.

**It does not replace extensions.** Extensions were about shipping *capability*
after download. Pockets are about *data the operator already owns*. If the
capability question returns, it returns on its own terms and D1 still applies.

**It does not give the operator a way to distribute a Pocket.** Sharing, signing,
and installing someone else's Pocket are all out of scope. That is the road that
led to extensions' signing and trust machinery, and it should not be walked again
without a specific reason.

**It does not touch the workspace root.** Pockets live inside the workspace or are
mounted from outside it; the root itself is chosen the way it is chosen today.

---

## Part VIII — Risks

**The one that killed extensions: a mechanism with no consumer.** Mitigated by D7
and only by D7. Watch for the temptation to skip Phase 2's migration because
Phase 3 is more interesting.

**A mount is a real trust expansion, and the UI is the only thing standing in
it.** If the mount screen is confusing, operators will mount their home directory
because it is the easiest thing to point at, and the sandbox becomes decorative.
The screen should make a *narrow* mount the path of least resistance.

**Manifest drift.** `Skills` already demonstrates the failure: an invalid skill is
logged and skipped, which is right, but a *silently* skipped Pocket looks like a
missing folder. Invalid Pockets must be visible in the UI as invalid, not absent.

**Registry-guard erosion.** `pockets/` is one entry whose children are
unconstrained. That is correct, and it is also the exact shape that could be
abused later to smuggle a feature's directory in as "a Pocket." The guard should
gain a note saying children of `pockets/` are operator data, never a feature's
storage.

---

## Part IX — Open questions for the operator

1. ~~**Where does the Pockets UI live?**~~ **ANSWERED 08-08 — a Home sub-tab,
   minimalist.** Locked as [D9](#d9--the-ui-is-a-home-sub-tab-and-it-is-minimalist).

   One consequence follows and is worth the operator's eye: **backgrounds are
   configured in Settings → Appearance, and their Pocket is now managed in Home →
   Pockets.** That split is defensible — *which* image is a preference, *the pile
   of images* is material — but it is a split, and D7's migration is where it
   first shows. If it reads wrong when built, the cheap fix is a link from
   Appearance to the tab, not a second copy of the UI.

2. **Should a Pocket be droppable-into from the chat?** The attachment work
   already accepts files into a staging area that dies with the conversation. "Put
   this in my icons Pocket" is the natural extension and is *exactly* the "special
   request" carve-out the 08-08 constraint left room for. Worth it now, or later?

3. **Does `sounds/`, `shaders/`, or `notes/` want to become a Pocket too?** Each is
   a fixed drawer of operator data. I would say **no for now** — one migration
   proves the shape, four migrations is a rewrite — but if the answer is
   eventually yes, the role table should be designed with that in mind.

4. **How does a Pocket die?** Deleting a local Pocket deletes the operator's
   files. Unmounting a mounted Pocket deletes nothing. Those are different enough
   that the UI should probably use two different words, and I would like to know
   which two.
