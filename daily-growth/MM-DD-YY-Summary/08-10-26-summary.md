# 08-10-26 — Apple said yes, and the website had been lying for two weeks

**A distributable macOS app exists.** Signed, notarized, stapled, zero issues, first
attempt. Alongside it: the repo and the public website were found stating opposite
legal terms, the site was telling users to read a file that doesn't exist, and the
telephony relay turned out to be an archive nobody knew they were keeping.

| Shipped | Commits |
|---|---|
| `G-2` — Developer ID certificate, and the three traps the map didn't predict | `5e897c6` |
| `G-2b` — notary credentials, proven by an authenticated round-trip | `eee5359` |
| **`G-3` — a signed, notarized, stapled x86_64 DMG** | `6b39379` `19afedd` |
| `G-35` — `nosniff` on every raw-byte route (one of two HIGH items) | `e9888ce` |
| The wizard promised a one-time Google connect it cannot keep | `bc6c535` |
| The tester-list failure, named — plus the runbook that grants access | `a8db05d` |
| MIT → PolyForm Shield 1.0.0, resolving a two-week contradiction | `e572247` |
| Command counts were wrong in three places; gated against the catalog | `13d11e7` |
| The relay kept every voicemail forever; now it erases | `797cabd` `0128423` `af77bae` |
| busterclaw.lol aligned with what the app actually does | `1824993` *(website repo)* |

---

## Apple: nothing here had ever been run before today

`III.0`'s "exercised against a real cert" column had **zero** entries this morning.
It has **seven** tonight. Every one was earned by running the thing rather than
reading it, and each verification caught something inspection would not have.

**The map's instructions could not be followed as written**, three times over:

1. **There is no Certificate Assistant on macOS 26.** Keychain Access still exists
   but moved out of `/System/Applications/Utilities/`, and `mdfind` doesn't index
   it — so it reads as deleted, and searching *inside* its window finds nothing
   because the menu is a menu-bar item. Generated the CSR with `openssl` instead,
   which changes something durable: **the private key is now a file**, so "back it
   up offline" stops being housekeeping.
2. **Apple's certificate page defaults to the wrong Sub-CA.** *Previous Sub-CA*
   expires **2027-02-01** — a fixed date, under six months out. Taking the default
   would have burned one of five certificates on something dying in spring.
3. **A `.p12` from OpenSSL 3 cannot be imported by macOS.** It fails with `MAC
   verification failed (wrong password?)` when the password is perfectly correct,
   sending you to re-export and doubt the one thing that was right. Needs `-legacy`.

**The third would have detonated in CI, not here** — on the first signed build, on a
machine you can't inspect, blaming a password that was fine, alongside every other
never-exercised step. It was caught by replaying the workflow's own `security
import` commands in a throwaway keychain first. **That is now the recorded rule:
replay a CI credential step locally before trusting it to CI.**

## The pipeline worked on the first attempt, which was not the plan

The map budgets rejection rounds. It needed none. `build_desktop.sh` with
`APPLE_SIGNING_IDENTITY` set produced a signed `.app` and a signed 27 MB DMG, and
Apple returned **`Accepted` / "Ready for distribution", zero issues.**

**Two confirmations came from outside**, which is what makes them worth more than
our own checks:

- **Apple issued 27 ticket entries** — the app, the Tauri binary, `beam.smp`, and
  every other Mach-O individually. That is Apple agreeing that
  `codesign_release.sh` found them all **by content**. No local check could
  establish that; we could only confirm our method agreed with itself.
- **`beam.smp` carries its own cdhash in the ticket.** The notary specifically
  blessed the JIT-enabled BEAM — the likeliest thing in this bundle to be refused.

**And a check got upgraded from "passes" to "discriminates".** `spctl` read
`rejected — source=Unnotarized Developer ID` before, and `accepted / Notarized
Developer ID` after stapling. Observing both halves is the difference between a
guard and decoration. It also beat what III.J anticipated: the gate warned that
"accepted" alone is meaningless because a self-signed local build is accepted too —
the real pre-notarization answer was sharper than that.

**The staging assertion held.** Before any of this, the build answered the question
nobody had checked: **does current `main` still package?** The last DMG was from
08-01, and `main` had moved **254 commits and +50k/−15k lines** since, including
deleting ~24,000 lines of Trading. The guard that exists because a staging
regression once shipped six days of empty DMGs passed on the first run.

## Two things I was wrong about, and one the repo had backwards

**Notarization took about five and a half hours**, against published guidance of
"minutes to an hour", with the notary service green throughout and zero issues in
the verdict. I called 68 minutes "the edge of normal" and set a two-hour escalation
threshold. **The correct answer was to keep waiting.** Recorded in III.H as *budget
hours, not minutes*, with the honest framing that the best explanation — 2,876
files, 2,451 of them `.beam`, where a typical Mac app is a handful of binaries — is
a **hypothesis to re-measure on the second submission**, not a finding.

**The architecture dependency was recorded backwards.** This map and the release
gate both said *"identify the Intel Mac — still owed."* The development machine
**is** the Intel Mac (i9-9980HK), and every DMG in the tree is `x64`. Nothing was
owed. What is owed is an **Apple Silicon** Mac — the worse gap, because the download
page is meant to say "most Macs since 2020", so the untested slice is the majority
one. It inverts `R7` in practice too: Intel is a one-year shelf, but today it is the
only slice with evidence behind it.

---

## The website had been contradicting the repo since 07-27

Asked for "total alignment with the site and what BusterClaw is actually capable
of." Audited every factual claim. **Eight were wrong. Two were actively harmful.**

**The API token file does not exist.** The site told readers to `cat ~/Library/
Application Support/BusterClaw/api_token` — in two places. The desktop shell writes
the token straight to the **Keychain** and *deletes* any plaintext copy it migrates.
Anyone following those instructions got nothing and no explanation.

**"Refusals are queued for you"** implied an approval flow. `Sentinel.Pending` is an
in-memory **Phase 0 visibility stub**; the approval gate is Phase 2 and unbuilt.
That is the product's headline security claim — the one that must not outrun the
code.

Also: BusterPhone presented as a working SMS relay (voice is live; SMS is
code-complete but **not activated**, and outbound calling doesn't exist), `~160`
commands against a real 203, `shift/Dispatch.md` — a path that isn't merely stale
but is in `@stale_machine_files` and gets actively cleaned up — OpenCode missing
from the backends, and a footprint of 64 MB against a measured **70 MB (BEAM 52,
Tauri 18)**, where "the BEAM is half" understated it at about three quarters.

### The finding that outranks all of them

**Nothing in this repo could have caught any of it.** The app runs a docs-drift gate
that fails specifically on `api_token` **file** references — the exact bug the site
was shipping. That gate scans `README`, `docs/`, and `user-guide/`. **The website
lives in another repository.** The guard existed and the bug sat outside its reach.

The front-door problem is normally described as four surfaces telling four stories.
Today it was that, with **legal consequences attached** — see below.

## The licence contradiction

The repo shipped **MIT** — public since April, README reading *"Fork it, sell it,
build on it."* The website had said **"source-available, not open source —
redistribution is not granted"** since website commit `c8e731e`, *"Retire the
open-source positioning for source-available"*, dated **07-27**.

A decision was made on 07-27, the website was updated, and **the repo never was**.
The roadmap's locked-decisions table still recorded "Open core, MIT, 07-12", which
that reversal superseded.

**Resolved in the site's favour** (operator call) as **PolyForm Shield 1.0.0** — a
standard, lawyer-drafted instrument rather than bespoke text, matching the already-
published wording, fetched from polyformproject.org rather than reproduced from
memory. `TRADEMARK.md` was **rewritten rather than patched**: it was built entirely
around MIT and would have contradicted the new `LICENSE` in its opening line.

**The MIT grant cannot be withdrawn, and all three documents say so out loud.**
Every commit published April→08-10 stays MIT for anyone who has it, permanently,
including redistribution and resale. **The cost of the fortnight's delay is exactly
that window, and it is permanent** — which is the argument for a decision reaching
the code the day it is made.

---

## The relay was an archive nobody knew they were keeping

The telephony drain acked a row by flipping `synced` to true. `list_unsynced/1`
filters on that flag — so a drained row became **invisible rather than gone**. Every
voicemail's audio object and every transcript stayed in Supabase permanently, and
nothing anywhere collected them.

**Found while establishing facts for the privacy policy.** That is the argument for
writing one: it forces you to state what happens to data, and the statement turned
out to be false. **No test caught it** — every test asserted the ack happened, and it
did.

**Deletion is now the ack, and that choice is load-bearing rather than cosmetic.** A
flag and a delete both stop a row being listed, but only the delete makes the
drain's existing retry loop the *erasure's* retry loop: a failed delete leaves the
row listed, so the next tick retries. With a flag, a failed cleanup stranded the
data forever with nothing to notice.

**What made the retry safe to rely on:** on a duplicate, `persist/1` returns `:ok`
*without* calling `maybe_enqueue_dispatch` — so re-reading a drained row can never
resurrect an old voicemail as agent work. Checked before designing around it.

**Automating the backlog sweep was refused with a reason.** Rows acked before the
fix carry `synced = true` and are invisible to the new path too; widening the query
to catch them would mean a lost local database replays every voicemail ever received
back through the enqueue path. It is an inspect-first runbook instead
(`supabase/one-time-sweep-drained.sql`), and it may be a no-op —
`SUPABASE_URL`/`SUPABASE_SERVICE_ROLE_KEY` are unset here and the drain is gated on
both, so it has probably never run outside tests.

---

## Onboarding: two things a trial user would have hit on step 3 of 4

**The wizard contradicted itself.** Three copy strings promised *"you'll do this
once"* while a fourth, twelve lines away, correctly warned about reconnecting
weekly. While Google has the OAuth app in Testing — the default, and the state today
— only 100 hand-added testers can connect and their refresh tokens expire every 7
days. **The cheerful version was a promise the app breaks on day eight**, made to
exactly the people being handed a trial build. Fixed with one source of truth
(`GoogleOAuth.reconnect_sentence/0`), returning a finished sentence rather than a
boolean because a caller cannot render half of it correctly.

**The tester-list gap needed copy and a runbook, not error handling** — because no
app code can rescue it. An address not on Google's approved list **never reaches our
callback**: Google ends the flow on its own "Access blocked" page, so
`GoogleOAuthController.callback/2` is never invoked. The app cannot detect it, log
it, report it, or tell it apart from a user who wandered off. The wizard just sits
there. Naming the symptom in advance is the only available lever, and the operator
half — how to *grant* access — had never been written down at all.

### The guard found something on the way in

The beta note is gated on `@bundled_available`, and with no bundled client
configured in test **it never rendered** — so a test asserting its copy would have
passed against an empty string. The earlier weekly-reconnect assertion only passed
because that sentence lives in the main paragraph. **The note itself had never had
any coverage.**

---

## Smaller, and worth keeping

**`G-35`, one of only two items ever marked HIGH in leftovers.**
`X-Content-Type-Options` appeared **nowhere** in the codebase until `RangeResponse`
started sending it for audio. Fixed as a `:media` pipeline over all nine raw-byte
scopes rather than nine `put_resp_header` calls — because patching them
individually is *how four drifted out of coverage*, and a scope missing
`pipe_through :media` is now visible in the router beside eight that have it. Stated
in three places what it does **not** fix: `/ws/file`'s `:show` serves workspace
`.html` as `text/html` deliberately, so nothing is sniffed there — that route's
exposure is the missing CSP, still open.

**Command counts: four statements, three different numbers, none right.** The site
said ~160, README said 191 twice, `docs/COMMAND_SURFACE.md` said 191, the catalog
has 203. Now gated — and **the gate found the third location on its first run**,
immediately after I'd finished "fixing" the counts by hand. It also prints a warning
it cannot enforce: busterclaw.lol states this number too and lives in another
repository. Naming a gate's blind spot in its own output is the cheapest available
mitigation for the failure mode that produced the `api_token` bug.

**Four guards were broken before being trusted** — the Google contradiction, the
tester-list symptom, the `nosniff` pipeline, and the relay erasure. Each defect was
reintroduced verbatim, the suite watched to fail, then restored. A test written in
the same sitting as its fix inherits the fix's blind spot.

---

## Where Release 1 actually stands

**The Apple path is finished for x86_64.** There is a DMG you could hand to someone
with an Intel Mac tonight.

Everything remaining is physical, not code:

1. **An Apple Silicon Mac.** The arm64 slice has never been built outside CI, never
   signed, never launched — and it is most of the user base.
2. **First launch on a machine that did not build the app** (`G-9`–`G-15`). The TCC
   prompt, no-`claude`, no-Homebrew, and offline paths have never been watched by
   anyone. **The pipeline was a strong prior and it held; first-launch behaviour has
   no such prior.**
3. **`/download`, `/privacy`, `/terms` are still 404.** `/privacy` gates Google OAuth
   verification — a months-long external clock — and must be **real HTML at a real
   path**: the site is canvas-rendered with hash routing, and a reviewer cannot read
   `#/privacy`.
