# BusterPhone removal — the phone comes out

**Scoped 2026-10-15 · BUILT the same night, Phases 0–4 in one commit.**
Operator decision, same day: *"get ready to remove the phone feature. We are
going to adopt a simpler, more customized route for remote comms."* — then,
hours later, *"let's follow through with the removal."* The route is not named
here (`IMESSAGE_ROADMAP` sits beside this map and is the obvious candidate);
this map is the subtraction, and it adds no replacement.

> ### What shipped (10-15, late)
>
> Everything in Parts I–V, as one commit rather than four, because the seams
> only hold together as a set: `mix precommit` green at 3,280 tests (3,424
> before; 144 phone tests gone, 11 added). Beyond the inventory, the cut found
> five more seams the map had not listed and took them too: the sound probe's
> `event_id` (a voicemail recording was the only thing it named), the sound
> board's telephony keys and the `voicemail`/`sms` bundled chimes, the Studio
> catalog's Recordings group, the sound board page's subscription, and the
> Explained atlas's "phone desk" cycle and `PHONE` surface box. Q1–Q4 took
> their defaults. **D10, not in the original map:** the Phone tab had been the
> only place to add a contact since 09-13, so adding one came back to the
> corner widget's Contacts tab, created and trusted in one step.
>
> **Phase 5 and Part VI are the operator's and are open:** the desktop walk,
> and the console teardown — release the toll-free number, delete the Supabase
> project, rotate the Twilio token, clear the stored `twilio_*` and
> `supabase_*` secrets from the Clinch, drop the six `.env` keys.

> ### The one-sentence version
>
> **Delete BusterPhone whole — the Twilio intake, the Supabase relay, the
> drain, the ten `phone_*` commands, the Phone page and panel, the voicemail
> and SMS triage jobs — and leave Contacts, Notifications, Dispatch and the
> Clinch standing without it.**

> ### Read this first: the business model stood on this leg
>
> `GO_TO_MARKET` (07-12, reaffirmed 07-14) made managed telephony **the only
> paid tier** — "we are the phone company", one bill, the user never sees
> Twilio — after the Browserbase cut left the paywall with no other leg, and
> after the Signature Feed was cut. `BUSTERPHONE_ROADMAP` carries the heading
> *"THIS IS THE MONEY LEG"*. Removing the phone removes the paid tier as
> designed. That is not an argument against the removal; it is the one thing
> the removal changes that is not code, and it is [Q2](#q2--what-is-the-paid-tier-now).
> The deletion does not wait on the answer.

---

## Contents

- [Part I — What goes, what stays](#part-i--what-goes-what-stays)
- [Part II — The inventory](#part-ii--the-inventory)
- [Part III — The seams](#part-iii--the-seams)
- [Part IV — Decisions](#part-iv--decisions)
- [Part V — The phases](#part-v--the-phases)
- [Part VI — Outside the repo](#part-vi--outside-the-repo)
- [Part VII — Risks](#part-vii--risks)
- [Part VIII — Open questions for the operator](#part-viii--open-questions-for-the-operator)

---

## Part I — What goes, what stays

BusterPhone has been **intake-only since 08-18** (`e08d1cd`): it answers,
records, transcribes, files the voicemail, archives inbound SMS, and sends
nothing. Outbound was already deleted. What remains to remove is the intake
and everything that displays or acts on it.

| Area | Outcome |
|---|---|
| Twilio intake: the webhooks, the Supabase relay (two edge functions, three SQL migrations), the Mac-side drain, PINs, trusted numbers | **Remove** |
| `Telephony`, `Telephony.{Drain,Event,Pins,Relay,Twilio}`, `TrustedNumbers` | **Remove** |
| Ten `phone_*` commands (`phone_list/get/stats/mark_heard`, `phone_trusted_*`, `phone_pin_*`) — 194 → **184** | **Remove** from the catalog, the CLI, the API |
| `/phone` page, `PhoneComponent`, the Phone work-area panel, the greeting component, the five `components/phone/*` modules, the recording media route | **Remove** |
| Explained → "The phone line" (`explained/phone.ex`, 591 lines) | **Remove** |
| The corner widget's Contacts tab: its *recent phone activity* column (`Status.Comms`, part of `Widget.CommsPanel`) | **Remove the column**; the contacts grid and the trusted-sender list stay |
| `voicemail-triage` and `sms-triage` jobs, the trusted-numbers policy file seed | **Retire** through `Seed.retire/2`, the way the cut-up seeds went |
| `Dispatch.enqueue_voicemail/2` | **Remove**; existing queue rows with `source: "voicemail"` are history and stay |
| Notification sources `voicemail`; sound routes `voicemail` and `sms` | **Remove** the routes; a stored sound map naming them is dropped on read, as unknown entries already are |
| The Clinch's three `twilio_*` app keys and the voicemail cost back-fill | **Remove** the key definitions; stored secrets are left for the operator to clear ([Part VI](#part-vi--outside-the-repo)) |
| `Sentinel`'s `pin` redaction fragment | **Remove** (it existed for `phone_pin_set` alone) |
| **`Contacts`** — people, with name, phone, email and a face | **Keep.** Shared by trusted senders, the duty dock, the widget. The `phone` column stays as a fact about a person ([Q3](#q3--does-a-contact-keep-its-phone-number)) |
| **`Messages`** — the Apple Messages read-only probe (`imsg`) | **Keep, untouched.** It is "independent of Twilio voicemail" by its own doc and may be where the new route starts. Not this map's call |
| Notifications, Dispatch, Mailman, the Duty shift, the Clinch itself | **Keep**; they lose their phone references only |
| The `keypad` and `sevenseg` smoke shaders | **Keep** unless told otherwise ([Q4](#q4--the-keypad-shaders)) — they are art the dialler left behind, not phone code |
| Existing recordings and transcripts in the Library | **Preserve.** They are the operator's files; nothing deletes them |

---

## Part II — The inventory

Paths relative to the repo root. Line counts as of 10-15.

### Owned outright — delete whole

| File | Lines |
|---|---|
| `lib/buster_claw/telephony.ex` | 337 |
| `lib/buster_claw/telephony/drain.ex` | 386 |
| `lib/buster_claw/telephony/relay.ex` | 188 |
| `lib/buster_claw/telephony/twilio.ex` | 173 |
| `lib/buster_claw/telephony/pins.ex` | 172 |
| `lib/buster_claw/telephony/event.ex` | 74 |
| `lib/buster_claw/trusted_numbers.ex` | 223 |
| `lib/buster_claw/commands/telephony.ex` | 136 |
| `lib/buster_claw/commands/catalog/telephony.ex` | 125 |
| `lib/buster_claw_web/live/phone_live.ex` | 58 |
| `lib/buster_claw_web/live/phone_component.ex` | 521 |
| `lib/buster_claw_web/live/phone/greeting_component.ex` | 103 |
| `lib/buster_claw_web/components/phone/{contact_list,log,playback,shared,registry}.ex` | 300 + 232 + 195 + 196 + 76 |
| `lib/buster_claw_web/components/explained/phone.ex` | 591 |
| `lib/buster_claw_web/controllers/telephony_recording_controller.ex` | 44 |
| `lib/buster_claw_web/live/status/comms.ex` (the activity rows; the trust rows move or go with it) | 113 |
| `priv/repo/seeds/telephony_demo.exs` | — |
| `supabase/` — `functions/{voice,sms}/`, `migrations/*.sql`, `SETUP.md`, `one-time-sweep-drained.sql`, `.temp/` | whole directory |
| `test/buster_claw/telephony/*`, `commands/telephony_test.exs`, `trusted_numbers_test.exs`, `live/phone_live_test.exs`, `controllers/telephony_recording_controller_test.exs`, `test/support/fixtures/sms_triage_pre_intake_only.md` | ~2,200 |

Roughly **4,400 lines of code and 2,200 of tests** leave outright, before the
seams below and the relay.

### Owned in part — edit

| File | What leaves |
|---|---|
| `lib/buster_claw/application.ex:194` | the `Telephony.Drain` child |
| `config/runtime.exs:98–131`, `config/test.exs` | `telephony_relay_*`, `telephony_drain_enabled`, the Twilio block |
| `lib/buster_claw/commands.ex`, `commands/catalog.ex` | the ten delegates and the catalog module |
| `lib/buster_claw_web/router.ex:91,125–128` | `live "/phone"` and the `/phone/recording` media scope |
| `lib/buster_claw_web/workbench_state.ex` | the `phone` panel key — **with a restore rule, see [D2](#d2--a-saved-layout-that-names-phone-loses-that-pane-not-the-layout)** |
| `lib/buster_claw_web/live/status_live.ex:14,19,35,63–66,228–230,561–579,706,719` | the `Telephony` alias and subscription, the `PhoneComponent` relay clauses and id, the phone panel, `@phone_activity`; **`Contacts` stays** |
| `lib/buster_claw_web/components/widget/comms_panel.ex`, `trusted_contacts_panel.ex` | the activity column; the "phone-side view" paragraph |
| `lib/buster_claw_web/live/duty_live.ex:15–16,24,72` + `duty_live.html.heex` | `Telephony` subscribe, `phone_ready` / `Relay.configured?` |
| `lib/buster_claw/duty_activity.ex:8` | the `PhoneEvent` alias and its clause |
| `lib/buster_claw/dispatch.ex:162–182,330–331`, `commands/dispatch.ex` | `enqueue_voicemail/2` and the dedupe key |
| `lib/buster_claw/jobs.ex:56–82,156–157,201,344–489` | the two triage briefs, their version digests, the roster lines, the trusted-numbers seed |
| `lib/buster_claw/seed.ex` | retire entries for the two jobs and the policy file |
| `lib/buster_claw/notifications/notification.ex:14`, `notifications/sound.ex:48–71`, `commands/catalog/notify.ex:25`, `live/notify_settings_live.ex:36–39` | the `voicemail` source and the `voicemail`/`sms` routes |
| `lib/buster_claw/clinch/app_keys.ex:72–96,173` | the three `twilio_*` keys |
| `lib/buster_claw/sentinel.ex:38–44` | the `pin` fragment |
| `lib/buster_claw_web/components/explained/registry.ex:31–42,119–128,216` | the phone entry and the catalog-count commentary |
| `lib/buster_claw/mailman.ex:12` | a doc comparison to the drain — reword |
| `lib/buster_claw/contacts.ex`, `contacts/contact.ex` | phone-specific affordances only, if any survive inspection; the schema stays |
| `priv/repo/migrations/` | **one new migration** dropping `telephony_events` (and `telephony_contacts` if `20260713040000_unify_contacts` left it) |
| `scripts/check_file_sizes.sh:179,213,220,221,227,232,412,497,684,729,1161` | eleven `check` lines, each removed with its reason in the commit |
| `assets/js/hooks/clinch.js`, `assets/js/audio/clipwave.js` | phone mentions — verify at build; likely comments |
| `README.md:25,31`, `docs/COMMAND_SURFACE.md:25,42,144–145`, `docs/ARCHITECTURE.md`, `docs/UML.md`, `user-guide/introduction.md` | the BusterPhone feature paragraph, the command count, the outbound-deleted note |
| Shared tests: `status_live_test` (88 matches), `jobs_test` (29), `contacts_test` (15), `sound_test` (13), `notify_settings_live_test` (12), `seed_test` (12), `app_keys_test` (9), `duty_live_test` (7), `commands_test` (6), `catalog_invariants_test` (6), `dialyzer_baseline_test` (5), `settings_live_test` (2), `media_nosniff_test` (1) | the phone cases; `catalog_invariants` and the Explained drift test will fail the build until the counts are retyped, which is their job |

---

## Part III — The seams

Where the phone reaches into things that stay. Each is a place the deletion
must cut cleanly rather than a thing to delete.

1. **Dispatch.** `enqueue_voicemail/2` is the only phone entry into the queue.
   Rows already there (`source: "voicemail"`) are history; `Dispatch.md`
   renders them by source string and needs no change. `commands/dispatch.ex`
   references the source in its docs.
2. **Jobs and seeds.** `voicemail-triage` and `sms-triage` were seeded into
   every workspace, with version digests so `Seed` can tell an unedited copy
   from an operator's. `Seed.retire/2` (built 09-19 for the cut-up seeds)
   removes unedited copies and leaves edited ones — the edited ones are the
   operator's and are named in the summary, not deleted.
3. **Notifications.** `voicemail` is a *source* (where the agent was) and
   `voicemail`/`sms` are *sound routes*. A stored route map naming a retired
   key is already tolerated on read (`sound.ex:386`); the Notify settings
   rows go; the `notify_*` command enum shrinks by one.
4. **Contacts.** Unified on 07-13 from the telephony contacts. Three
   non-phone readers: `StatusLive` (trusted toggle), `DutyDockLive`
   (readiness), `Status.Comms` (the widget). The widget's "two views onto the
   same contact list" becomes one view.
5. **The Clinch.** `twilio_account_sid`, `twilio_auth_token`,
   `twilio_phone_number` are app-key definitions with env fallbacks. Removing
   the definitions does not remove a stored secret; the Clinch panel will
   simply stop listing them. Clearing is the operator's ([Part VI](#part-vi--outside-the-repo)).
6. **Sentinel.** The `pin` redaction fragment guards the audit log against
   `phone_pin_set`'s plaintext. With the command gone, the fragment is dead;
   leaving it is harmless, removing it is honest.
7. **The work area.** `phone` is a panel key, and [D2](#d2--a-saved-layout-that-names-phone-loses-that-pane-not-the-layout)
   is the one place this map adds a rule instead of removing one.
8. **The Explained drift test** compares the registry's catalog counts to the
   live catalog. It will fail until the numbers move: 194 → 184, and the
   `read`/`safe` tier counts with them.

---

## Part IV — Decisions

### D1 — Subtraction only; no replacement is scoped here

The operator's "simpler, more customized route" is a separate map once it is
named. Nothing in this one adds a module, a command, a dependency or a
service connection. `Messages` (the Apple Messages probe) is left exactly as
it is.

### D2 — A saved layout that names `phone` loses that pane, not the layout

`WorkbenchState.restore/1` rejects a tree holding an unknown key by returning
`new()` — the whole layout resets to a lone Chat. After this removal every
operator who ever opened the Phone panel has `phone` in `bc:workbench:v1`.
`restore/1` learns a short list of **retired keys** that are pruned from the
tree before validation, so the rest of the arrangement survives. This is the
same shape as `retired_tabs.js` on the tab strip.

### D3 — Retire the seeds, do not delete the operator's edits

Per seam 2. `Seed.retire/2` with the recorded digests. The trusted-numbers
policy file (`memory/trusted-numbers.md` or wherever `TrustedNumbers.seed_contents/0`
puts it) goes the same way.

### D4 — One migration, forward only

A new migration drops `telephony_events` (and `telephony_contacts` if the
07-13 unification left the table behind). The four creating migrations stay
in history; `down` on the new one recreates nothing — there is no path back
to a feature that no longer has code.

### D5 — The Library keeps every recording and transcript

Files under the workspace are the operator's. The media route that *served*
recordings goes; the files do not. The Library documents that filed them
keep their frontmatter and tags (`voicemail`, `sms`) — the tag is history,
not a dependency.

### D6 — The size gate shrinks by eleven lines, each with its reason

`check_file_sizes.sh` says removing an entry "requires saying why in the same
commit". The reason is the same eleven times: the file is deleted by this
map. Say it eleven times.

---

## Part V — The phases

Each phase leaves `mix precommit` green and is its own commit. Order matters:
the intake is turned off before the code that reads it is removed, and the
data migration runs after nothing writes the tables.

### Phase 0 — Stop the intake (operator + one line)

- Operator: in the Twilio console, point the number's voice and SMS webhooks
  at nothing (or release the number — [Part VI](#part-vi--outside-the-repo)).
  Nothing new will arrive.
- Code: `BUSTER_CLAW_TELEPHONY_DRAIN` off in `.env`; confirm the drain child
  logs idle. One last `./buster-claw run phone_list` for the record.

### Phase 1 — Surfaces

- Delete `/phone`, `PhoneLive`, `PhoneComponent`, the greeting component,
  `components/phone/*`, `explained/phone.ex` and its registry entry, the
  recording controller and route, the Phone panel (`WorkbenchState` key +
  [D2](#d2--a-saved-layout-that-names-phone-loses-that-pane-not-the-layout)),
  the widget's activity column and `Status.Comms`, `StatusLive`'s relay
  clauses and subscription, `DutyLive`'s `phone_ready`.
- Tests: delete `phone_live_test`, prune `status_live_test`, `duty_live_test`,
  `settings_live_test`, `media_nosniff_test`; add the D2 restore test
  (a saved tree `chat | phone | clock` restores to `chat | clock`, active
  preserved).

### Phase 2 — Core, commands, config

- Delete `Telephony` and its five modules, `TrustedNumbers`, the ten
  commands and their catalog module, the drain child, the runtime and test
  config blocks, the Clinch key definitions, the Sentinel `pin` fragment,
  `Dispatch.enqueue_voicemail/2`, `DutyActivity`'s phone clause.
- Retype the catalog counts in `Explained.Registry`, README,
  `COMMAND_SURFACE`. Let `catalog_invariants_test` and the drift test be the
  gate.
- Tests: delete the telephony suite; prune `commands_test`, `app_keys_test`,
  `dialyzer_baseline_test`, `contacts_test`.

### Phase 3 — Seeds, notifications, data

- `Seed.retire/2` entries for `voicemail-triage`, `sms-triage`, the
  trusted-numbers policy; the briefs and digests leave `jobs.ex`.
- Remove the `voicemail` source and the `voicemail`/`sms` sound routes and
  their Notify rows; confirm a stored map naming them still loads.
- The drop migration ([D4](#d4--one-migration-forward-only)).
- Tests: `jobs_test`, `seed_test`, `sound_test`, `notify_settings_live_test`.

### Phase 4 — The relay and the record

- Delete `supabase/` whole, `priv/repo/seeds/telephony_demo.exs`, the eleven
  size-gate lines ([D6](#d6--the-size-gate-shrinks-by-eleven-lines-each-with-its-reason)),
  the phone mentions in `clinch.js` / `clipwave.js` if they are more than comments.
- Docs: README, `COMMAND_SURFACE`, `ARCHITECTURE`, `UML`,
  `user-guide/introduction`. Archive `BUSTERPHONE`, `PHONE_INTAKE`,
  `PHONE_ACCESS` with a one-line header pointing here. `SUPERMAP`: the
  BusterPhone rows become one line, this map.
- `.env`: the six keys (`SUPABASE_URL`, `SUPABASE_SERVICE_ROLE_KEY`,
  `TWILIO_MESSAGING_SERVICE_SID`, `TWILIO_ACCOUNT_SID`, `TWILIO_AUTH_TOKEN`,
  `BUSTER_CLAW_TELEPHONY_DRAIN`) — the operator removes them; `runtime.exs`
  no longer reads them after Phase 2, so a stale key is inert.

### Phase 5 — The walk

Fresh profile and an upgraded one. The upgraded profile had the Phone panel
open and both triage jobs unedited:

1. Launch → the layout restores minus Phone; nothing else moved (D2).
2. The sidebar has no Phone; `/phone` 404s; Explained has no phone line.
3. `./buster-claw commands | grep phone_` is empty; `jobs list` shows neither
   triage job; the workspace `jobs/` folder lost the two unedited briefs.
4. Settings → Notify lists no Voicemail or SMS row; chimes still play.
5. The Clinch panel lists no Twilio keys.
6. A Library doc from an old voicemail still opens, and its recording file is
   still on disk.
7. `on-duty` runs a shift without a phone reference in its log.

Expected size: about **−7,000 lines** across code, tests, the relay and docs,
with one new migration and one new restore rule.

---

## Part VI — Outside the repo

None of this is code, all of it costs money or leaves a door open if skipped.

- **The toll-free number, +1 844 484-8755.** Release it in Twilio, or keep
  paying for a line that rings into nothing. If it is kept for the new route,
  say so in that map.
- **The Twilio account.** Rotate or delete the auth token once the drain is
  gone; the Clinch may still hold a copy.
- **The Supabase project** dedicated to telephony (its `service_role` key sits
  on the Mac). Delete the project.
- **The Clinch.** Clear the three stored `twilio_*` secrets from the panel
  before Phase 2 removes their definitions, or they become unlisted entries.
- **busterclaw.lol.** The public copy describes BusterPhone (`G-45` in
  `WEBSITE`). Other repo.
- **The website's and README's pricing story.** See
  [Q2](#q2--what-is-the-paid-tier-now).

---

## Part VII — Risks

- **R1 — Layout wipe on upgrade.** Without D2, every profile that opened the
  Phone panel resets to a lone Chat on first launch. D2 is Phase 1, not a
  follow-up.
- **R2 — Edited seeds.** `Seed.retire/2` leaves an edited brief in place; an
  operator who customised `sms-triage` keeps a job that names a deleted
  command. The summary names them; the Jobs roster must not list them.
- **R3 — Stored sound routes.** Confirmed tolerated on read, but the Notify
  page must not render a row for a key it no longer knows.
- **R4 — The money leg.** [Q2](#q2--what-is-the-paid-tier-now). The deletion
  does not need the answer; the launch roadmap does.
- **R5 — Contacts.** The unification migration (07-13) is the one place a
  "telephony_contacts" table might still exist. Check before writing D4's
  migration rather than assuming.
- **R6 — The number keeps billing** if Part VI is skipped.

---

## Part VIII — Open questions for the operator

### Q1 — What is the simpler route?

Not needed to delete. Needed before anything is *added*. `Messages` (the
Apple Messages probe, `imsg`) already exists as a read-only readiness check
and is the obvious seed if the route is iMessage; if it is something else,
that map starts from zero. **Default:** this map ships without naming it.

### Q2 — What is the paid tier now?

Managed telephony was the only one. The options on record are the ones
`GO_TO_MARKET` already weighed: Option B (a paid signed DMG, Aseprite-style)
was kept as "a viable later second line"; on-duty stays free by construction;
GWS was ruled wrong as a subscription. **Default:** no change to the launch
documents in this map; `DISTRIBUTION` and `GO_TO_MARKET` get a one-line note
that the leg is gone and the question is open.

### Q3 — Does a contact keep its phone number?

The `phone` column is a fact about a person and costs nothing. Dropping it
means a migration and losing data the operator typed. **Default:** keep.

### Q4 — The keypad shaders

`keypad.wgsl.js` and `sevenseg_glyphs.wgsl.js` are smoke-background art that
came from the dialler. They reference nothing in the phone code.
**Default:** keep.
