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

---

# The Clinch: Phases 3 and 4, in one sitting

**Credentials can now be entered in the app, rotated, revoked, and seen when they
break — and an agent with a shell can no longer manage any of them.**

| Shipped | Commits |
|---|---|
| 3a — `:app_key`, a second writable kind | `6415825` |
| 3b — live resolution, environment as fallback | `121f954` |
| 3c — the drain self-gates | `43f61e2` |
| 3d — the service-credentials panel | `1a705a2` |
| 3e — the tutorial points at it | `7ec5f52` |
| 4 — one vault, re-key, visibility, revocation, invocable, terminal token | `2f157d1` `6b36f42` `3efe94e` `c683f00` `0e289de` `b8721aa` |

**Phase 3 exists because a packaged app cannot see your shell.** A double-clicked
`.app` inherits launchd's environment, so Twilio and Supabase credentials exported
in `.zshrc` were invisible to the shipped product — which is why BusterPhone had
never been configurable outside a dev terminal. That is the paid tier.

## Three times the code refused a wrong design

**A test rejected my data model.** I put app credentials in the existing
`:service_key` kind and made `managed?` per-entry. `Clinch`'s invariant test
refused it: that forces `list/1` to restate `managed?` as a literal, the
coincidence-not-derivation bug it exists to prevent. Its message read *"the write
boundary has two answers again"*. `Types` already said a kind decides **where it
lives and who may manage it** — two stores with two managers is two kinds. Hence
`:app_key`.

**A phase turned out to be a deletion.** 3c asked for children that "start and
stop when a credential appears or disappears, without an app restart", which reads
like a DynamicSupervisor. `Drain.drain/1` had always opened with
`Relay.configured?()` — the *work* was already gated. Gating the *child* at boot
was a second answer to the same question, and the one that could go stale, since a
credential stored after boot could never flip it. **Removing the boot gate was the
whole change.**

**A tripwire fired at exactly the commit it was written for.** `clinch_test`
asserted the app vault must *not* read a Google column, warning that if it could,
*"the vaults were merged without the Phase 4 migration and existing installs are
about to lose their Google credentials"*. That is precisely what I was doing. It
now asserts the inverse, and records that the migration is what earned the flip.

## The bug that outranks everything built today

`Sentinel.Event` validates `category` against a whitelist, and `Sentinel.observe/4`
is **best-effort by design** — the audit write must never raise on the hot path.

So both new revocation categories were **silently dropped**. Invalid changeset,
warning logged, caller told nothing. The full suite passed. The new tests passed.
**A security feature the roadmap says exists was recording precisely nothing**, and
the only evidence was one `Logger` line in the middle of green output.

`SentinelCategoryTest` now scans every `observe/4` call site against
`Event.categories/0` — source text, not runtime, because a category in a branch no
test took is exactly the one that gets dropped in production. It carries a
non-empty check so a broken scan cannot read as a clean codebase, and a positive
control proving the whitelist rejects anything.

**The general lesson is worth more than the fix: any best-effort write is a place
a feature can be absent and green.** Worth auditing wherever else that pattern
lives here.

## A documentation error that would have destroyed credentials

`Clinch.Vault`'s table gave the Google AAD as `google:v1`. That is the **key
derivation prefix**; the AAD was `buster_claw.google.vault.v1`.

The two vaults' frames were byte-identical — version 1, 12-byte IV, 16-byte tag —
differing only in key and AAD. **A migration written from that table would have
produced ciphertext that fails GCM authentication forever, with no error until
someone needed the value.** I caught it because I read the code before trusting
the doc that described it.

**When two things differ only in constants, naming one of them wrongly is
invisible.**

## Two failures that are not the same

The re-key's central design call. A value that will not decrypt under the old key
is **not** evidence the rotation is broken — it is evidence that value was
*already* unreadable, which is exactly the state a previous bad key change leaves
behind. Aborting on it would make the tool refuse to run on the machine that most
needs it. And overwriting it would destroy the only copy of something a restored
key might still recover.

So: **unreadable is counted and left byte-for-byte; an actual error rolls back the
lot.** A partial rotation — some values under the old key, some the new, no single
key that reads them all — is the worst outcome available.

## Invariant 5 needed both halves

*"A rotated key never **silently** unconfigures anything."* `Encrypted` fails
closed and loads an unreadable value as `nil`, so two states rendered identically:
*"you have not configured anything"* and *"everything you configured is
unreadable."* Both look like an empty app. One is fine and one is an emergency.

Re-keying gave a bad key change a way **out**; the visibility check gave it a way
to be **seen**. And **my own test caught that I had built the distinction and then
ignored it** — `{:error, :no_key}` was added to the vault specifically to separate
"no key configured" from "damaged", then matched as `{:error, _}` one function
away and counted as damage.

The warning leads with **recoverability**, not breakage, because a warning that
only says "broken" invites the one action that makes it permanent: re-entering
everything and discarding a key that would have brought it all back.

## The terminal was a hole in the codebase's own argument

`RequireTrusted` justifies the full token by saying an attacker *"gets no shell and
therefore no Keychain."*

**The in-app terminal is a shell, and it had the full token.** An agent running
there — the ordinary way this product is used — could store, delete, and (after
that morning's work) rotate credentials. *Use, never manage* was untrue wherever an
agent had a prompt, and Phase 5 would have made it untrue **remotely**.

The fix is a fourth token, and **the load-bearing half is that it is
trusted-equivalent for commands**. The terminal runs the operator's own agent; it
must keep doing dispatch work, sends and deletes. Scoping it further would close
the hole by breaking the loop the product is built on — so a test asserts
`gmail_send` still passes for `:terminal` and says why. **That is the regression a
future "tighten this up" change would cause, and it is the direction nobody thinks
to guard.**

Two more worth keeping: `clinch.rs` reads `BUSTER_CLAW_API_TOKEN` from the Tauri
*process* env to reach management routes on the operator's behalf, so downgrading
that variable would have broken the credential panel itself. And
`secret_provisioning.rs` **refused the new secret until it was declared** — the
named inventory written after `agent_token` was provisioned nowhere and quietly
wrote itself to disk in cleartext on every packaged install. It worked.

## What is implemented and what is operable are different questions

Re-key passed its tests and **nothing could call it**. No command, no button, and
the shell must sequence re-key-then-adopt with nothing orchestrating it. A phase
whose acceptance is *"rotating the recovery key preserves every integration"* is
not finished while rotating it is something only a test can do — so it was recorded
as a red banner rather than filed as done, then closed with
`./buster-claw clinch rotate --confirm`.

**A CLI verb, not a catalog command**, because rotation is *management* and the
Clinch's split is structural: no agent can reach it because there is nothing to
reach. **The new key is printed before anything is re-encrypted** — a failed
rotation leaves a key that opens nothing, which is harmless; a successful one whose
key was never seen leaves a database nobody can open.

Key custody stays manual by operator decision, and the ordering for a future
one-click flow is now written down: **neither naive order is safe**, and the shape
that works is write the new key as a *second* Keychain entry, re-key, then promote
— so at every instant at least one stored key opens the data.

## The shared tree, and an error of mine

**Commit `2f157d1` swept in three of the Phone agent's untracked files.** I staged
explicit paths and verified the index immediately before committing — it showed
exactly my nine files. Then a bare `git commit` took **whatever the index held at
that moment**, and the agent staged into the shared index in between.

The defence is a pathspec commit, `git commit -- <paths>`, which I had used earlier
the same day for this exact hazard and then stopped using. **Verifying the index
and committing the index are two moments**, and in a shared tree that gap is real.
Not reverted — history was pushed and the content was final.

I also **gave the agent a confident, wrong diagnosis**: I said `asset_url/2` would
format a path for a file that does not exist. It calls `resolve/2` first and
returns `nil`. I inferred it from `resolve/2` existing rather than reading the
function, and the agent had to disprove it.

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
