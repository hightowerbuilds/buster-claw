# Explained — the rewrite

**Scoped and BUILT 10-16-26, same morning.** Operator's ask: *"rewrite the explained panel —
there's a lot of stuff in there that doesn't exist anymore. A comprehensive,
thorough rewrite of that entire panel."*

> ### The one-sentence version
>
> **Every tutorial in Explained is re-read against the app as it is on 10-16 —
> no phone, no dock, a work area of panels, a sidebar, a Clock panel with
> Contacts and Notify, four terminals, attachments in the mail path — and every
> sentence that describes something gone is replaced with the thing that is
> there, with the quoted facts derived from source wherever a module can hand
> them over.**

> ### What shipped
>
> All six phases, one commit. Every tab re-read against the running app; the
> Studio's routing keys now render from `Notifications.Sound.route_keys/0`
> (D1); contact faces left the Pockets and Shaders prose (D2); one geography
> paragraph on the Intro and the same words everywhere after it (D3);
> busterclaw.lol described as the download, the docs and the source (D4); the
> BrowserControl tab gained the Ask door and the three fences (`browser_secret_*`,
> `browser_egress_level`, `browser_download`); the Gmail/GWS tab gained the
> attachment path and the duty dock; the Studio gained the recording verbs. The
> audit test's stale-phrase list grew by ten phrases (D7) and **caught five
> drifts outside Explained on its first run**: the `sound_apply` and
> `sound_delete` descriptions still named `voicemail`, `note_list` still said
> "the Workspace page's Notes tab", the tab strip still carried a `/phone`
> label, and the Duty page's "Add a trusted sender" blocker still linked to
> `/phone` — a dead route. All five fixed in the same commit. Q1–Q3 took their
> defaults.

> ### Read this first: what the panel never absorbed
>
> Explained was written 08-02 → 08-16 and patched by deletion since: the Phone
> tab was removed (10-15), the Voice Library (09-19), the Sketch Pad (09-05),
> Trading (08-08), VoxCPM (10-11). Each removal took its own tab or verbs and
> left the *other* tabs' references standing. On top of that, the app's
> geography changed under it and nobody re-read the prose: the dock became a
> sidebar; home sub-tabs became work-area panels; Workspace lost its Notes and
> Calendar tabs to panels of their own; the terminal became four slots; the
> corner widget became the Clock panel; a duty dock, a Mailman and an Ask door
> arrived (THREE_DOORS); trusted-sender attachments arrived (10-14). The audit
> test guards command names and routes. It cannot guard a sentence.

---

## Part I — The audit, tab by tab

Ground truth taken 10-16 from the running app: 183 catalog commands (`/api/
commands`), routes from `router.ex`, panels from `WorkbenchState.panels/0`,
widget tabs from `HomeWidget` (Time & Place · Contacts · Notify), sound routing
keys from `Notifications.Sound` (15: no `voicemail`, no `sms`), Appearance
surfaces (Homepage · Time & Place · Terminal), ModelPolicy surfaces (chat,
dispatcher, swarm_planner, swarm_run; no floors).

| Tab | False or stale | Missing |
|---|---|---|
| **Registry** | Pockets blurb/body teach contact shaderfaces as a live surface; the `@command_stats` comment is a 60-line recompute diary that mentions the phone four times; `cmd`'s `path` comment is history | — |
| **Intro** | "a phone line" in the summary; the surface list predates the work area | A paragraph that says *where things are*: the sidebar, the panels, the Clock panel, the duty dock |
| **Sites** | busterclaw.lol described as "the planned counter where your agent will be able to get its own phone number"; "use the Phone tab" | What the site is now: the download, the docs, the source, the terms |
| **Models** | "Codex keeps a conversation thread when live steering is enabled; the fallback one-shot adapter starts a fresh session" — Codex runs through one app-server connection now (`CodexAppServer`), threads always | — |
| **Gmail/GWS** | "Workspace page's Calendar tab" (it is the Calendar panel); "corner widget's Notify tab" (the Clock panel's); "add … as a contact on the Phone tab" (the Clock panel's Contacts tab); "go on duty from the dock" / "the bar at the bottom of every screen" (the sidebar's duty dock) | Attachments: a trusted sender's attachments are saved under `attachments/gmail/<id>/`, named in the Library doc and the queue item; `dispatch_reply` can attach; `gmail_attachment_download` |
| **Command List** | "Activity sub-tab" / "corner widget" placements; `CmdTable` moduledoc quotes 33 groups and 203 descriptions (39 and 183 today) | The queue is also `Dispatch.md` in the workspace and the Duty page |
| **BrowserControl** | Nothing false | Three doors that shipped after it: **Ask** on the browser chrome (prefills Chat with the page), `browser_secret_put`/`_delete` (gated; `$secret.<name>` typed during a fill, never read back), `browser_egress_level`, `browser_download` |
| **Shaders** | "a contact shaderface for the Phone tab's face picker" — the picker left with the Phone tab; "joined on 08-15" | — |
| **Pockets** | `pockets/contact-faces/` taught as the third load-bearing Pocket; **nothing in the web layer renders a contact's face any more** (`face_seed`/`face_shader` have no reader outside `Pockets.Faces`); "Home → Pockets → Mount…" and "Open the Pockets tab" (it is a work-area panel) | — |
| **Studio** | Routing keys list names `voicemail` and `sms`; "a voicemail arrives"; the worked prompts install "my voicemail chime"; `sound_import` "a phone event whose recording the app itself stored"; "an imported voicemail can be imported again" | The recording verbs: `sound_devices`, `sound_record` (gated — the microphone), `sound_input_level`; `sound_sources` |

---

## Part II — Decisions

- **D1 — Derive what can be derived.** The Studio's routing keys render from
  `Notifications.Sound.route_keys/0` rather than a typed list, the way Shaders
  reads `Appearance` and Models reads `ModelPolicy`. That list is how the phone
  got into this tab twice.
- **D2 — Contact faces stop being taught as a surface.** `Pockets.Faces` and
  the `face_shader` column stay in the code (deleting them is a separate call,
  [Q2](#q2--delete-the-contact-faces-code)); the Pockets tutorial names the two
  Pockets a reader actually meets — `backgrounds` and the six brand Pockets —
  and the Shaders file contract teaches the `face` name as **reserved**, which
  is what the code does. The Pockets test's three-pocket pin becomes two.
- **D3 — One geography, used everywhere.** *Sidebar* (the panel menu, Browser,
  Settings, the duty dock, the corner widget); *work area* and *panel* (Chat,
  Workspace, Notes, Calendar, Terminal ×4, Pockets, Explained, Activity, Clock);
  *the Clock panel* with its three tabs (Time & Place, Contacts, Notify). No
  "dock", no "sub-tab", no "corner widget" as a location. The Intro carries the
  one paragraph that establishes it.
- **D4 — busterclaw.lol is the download, the docs and the source.** No vending,
  no counter, no future tense. The site copy was cut to match on 10-16
  (`buster-website` `3112500`).
- **D5 — No new tab.** The ask is a rewrite. The queue and the duty loop get
  their honest sentences inside Cmd cycle 4 and GWS cycle 4 rather than a ninth
  tile ([Q1](#q1--an-on-duty-tutorial)).
- **D6 — Dated trivia leaves the reader-facing prose.** "Joined on 08-15",
  "until 09-05", "three sub-tabs until…" are moduledoc material. Moduledocs are
  shortened to the history that still explains a shape.
- **D7 — The guard grows with the rewrite.** `explained_audit_test.exs`'s
  stale-string list gains the phone-era and dock-era phrases (`Phone tab`,
  `phone line`, `voicemail`, `shaderface`, `the dock`, `sub-tab`, `corner
  widget`), so the next removal that leaves a sentence behind fails a test.
  Pinned strings in `status_live_test.exs` and `explained_panel_test.exs` are
  updated where the sentence they pin changed.
- **D8 — The Registry's recompute diary becomes one rule.** `@command_stats`
  keeps the numbers and a two-line note: measured from `Catalog.entries/0`, and
  the contract test is the only reason to trust them.

---

## Part III — Phases

| Phase | Scope |
|---|---|
| 0 | This map. |
| 1 | Registry, Intro, Sites. |
| 2 | Gmail/GWS, Command List (+ `CmdTable` moduledoc). |
| 3 | BrowserControl, Models. |
| 4 | Shaders, Pockets (+ the Pockets test pins). |
| 5 | Studio (route keys derived; recording verbs added). |
| 6 | Audit-test stale list; `mix precommit`; size caps re-held. |

Every phase is a read of the tab against the app, not a word swap: a sentence
survives only if the thing it describes can be opened.

---

## Part IV — Open questions for the operator

### Q1 — An "On duty" tutorial?

The 08-09 leftovers called the work queue "the real gap": the README names it
the whole design and it has no tab while shaders does. **Default: no** — this is
a rewrite, and the loop is taught inside two existing cycles. Say the word and
it is a module, a registry line and a dispatch line.

### Q2 — Delete the contact-faces code?

`Pockets.Faces`, `Contact.face_shader`, `face_seed`, and the `face` name rule in
`Appearance` have no renderer since the Phone tab left. **Default: leave the
code, stop teaching it** (D2). Deleting it is a small map of its own: a column
migration, a Pocket kind, a naming rule, and a seeded `contact-faces` folder.

### Q3 — Keep the two site tabs?

They teach nothing about the app; the 08-09 decision kept them last in the rail.
**Default: keep**, rewritten to the truth.
