# The fresh-machine walk — installing Buster Claw somewhere it has never been

**A side-map of [`QA_BACKLOG`](QA_BACKLOG.md) · Scoped 08-18-26 · Status: NOT
RUN.**

> **Extended 08-22 with step `0b` — the download itself.** Everything scoped on
> 08-18 begins with the app already installed, because there was no artifact to
> download and no link that resolved — and as of this edit there still is not:
> busterclaw.lol's button points at `DOMAIN-TBD.invalid` and no release has been
> published. **`0b` is written ahead of the artifact on purpose**, because the
> decision it governs gets made in the thirty seconds before you mount a DMG and
> cannot be recovered afterwards. `DL-1` is the load-bearing one: without a
> quarantine flag on the arriving file, Gatekeeper never runs and `FM-2` reports
> a pass it did not earn.
>
> Until a real download exists, `DL-3`–`DL-5` cannot be walked at all — they
> describe a page that has not been fixed yet. Say so in the writeup rather than
> marking them passed.

> ### What this is for
>
> Every test we have runs on the machine that built the app. That machine has a
> workspace, a Keychain entry, a Clinch master key, Google tokens, an agent CLI
> on `PATH`, and eight months of state nobody remembers creating.
>
> **A fresh machine has none of that, and that is the only condition under which
> a whole class of code runs at all.** First-run paths are the least-tested code
> in the app for exactly the reason they are the most important: every user
> executes them exactly once, and it is the first thing they ever see.

> ### Read this before running it
>
> **This walk does NOT close `G-4`.** `G-4` is the two-arch exit test and needs
> an **Apple Silicon** Mac — the arch that has never been built outside CI,
> never signed, never launched. The Intel machine is the arch we already have
> covered. This walk is about *first run*, not about architecture, and the two
> are being confused because they happen to want the same spare Mac.
>
> **It also blocks nothing**, which is the entry criterion for `QA_BACKLOG`. If
> something here turns out to block a release, promote it into
> [`RELEASE_GATE_ROADMAP`](RELEASE_GATE_ROADMAP.md) rather than raising this
> document's status.

---

## Contents

- [Part I — The hazard to read before you start](#part-i--the-hazard-to-read-before-you-start)
- [Part II — What only a fresh machine can test](#part-ii--what-only-a-fresh-machine-can-test)
- [Part III — The walk](#part-iii--the-walk)
- [Part IV — Traps this walk exists to catch](#part-iv--traps-this-walk-exists-to-catch)
- [Part V — What to capture](#part-v--what-to-capture)
- [Part VI — What this deliberately does not cover](#part-vi--what-this-deliberately-does-not-cover)

---

## Part I — The hazard to read before you start

**Do not configure BusterPhone on the second machine while the first is
running.** This is the one step in the walk that can destroy real data rather
than merely fail.

`Telephony.Drain` persists a relay row locally and then **deletes it from the
relay** — `drain.ex:333`: *"Deletion IS the ack: a deleted row cannot be listed
again, so it needs no `synced` flag."* That is exactly right for one machine and
actively harmful with two. Both drains poll the same Supabase project; whichever
wins **permanently takes the event**, and the other never sees it.

The failure is silent. The primary Mac does not error — a voicemail simply never
arrives.

| Option | Cost | Use when |
|---|---|---|
| **Enter no Twilio/Supabase credentials on machine 2** | free | the default. Onboarding never asks for them anyway (Part III) |
| **`BUSTER_CLAW_TELEPHONY_DRAIN=false` on machine 2** | one env var | you want to walk the Clinch credential-entry path without draining |
| Quit the app on machine 1 | free, easy to forget | a short supervised walk |
| A second Supabase project + second Twilio number | real setup | only if this becomes routine |

**Default to the first.** The phone is not what this walk is testing.

> `BUSTER_CLAW_TELEPHONY_DRAIN` is read in `config/runtime.exs:107`; anything
> other than `1/true/TRUE/yes/YES` disables it, and an *unset* variable means
> **enabled**. So the disable must be explicit — there is no "safe by default"
> here.

---

## Part II — What only a fresh machine can test

The reason to spend a machine on this. Each of these executes exactly once per
install and **never again on the dev Mac**:

| | Path | Why it is invisible otherwise |
|---|---|---|
| `FM-1` | **Keychain token generation** | The packaged shell generates the API token straight into the Keychain on first run, and migrates-then-**deletes** any legacy plaintext file (`desktop/tauri/src/main.rs`). On a machine that already has the entry, the generation branch never runs |
| `FM-2` | **Gatekeeper on a naive machine** | The dev Mac has trusted this developer for months. A machine that has never seen the certificate is the only honest test of notarization + stapling |
| `FM-3` | **Workspace scaffolding from nothing** | `Workspace.ensure/0` declares ~20 top-level entries across `:core` and `:on_demand` tiers. Only an empty disk exercises the create path for all of them, in order |
| `FM-4` | **Seed `:created`, all four job files** | `BusterClaw.Seed` shipped 08-18. The dev Mac can only ever exercise `:current`/`:upgraded`/`:kept`. **`:created` has no other test bed** |
| `FM-5` | **Clinch master key generation** | A first-run key derivation that cannot repeat once a key exists |
| `FM-6` | **Migrations from an empty database** | `Ecto.Migrator` runs at boot for releases (`application.ex`). The dev DB has been migrated incrementally since May; a release runs *every* migration in order against nothing, and that ordering has never been walked end to end |
| `FM-7` | **No agent CLI installed** | The dev Mac has `claude` on `PATH`. A buyer's may not. What the app *says* in that state is the whole first impression, and nothing tests it |
| `FM-8` | **Google OAuth from zero tokens** | The consent screen, the scope list, and the callback, with no vault to fall back on |
| `FM-9` | **Onboarding with no prior state** | `RequireOnboarding` should force `/setup`. On the dev Mac onboarding is complete, so the redirect never fires |

**`FM-4` and `FM-7` are the two worth the trip on their own.** The first is a
mechanism that shipped today with a hole in its test coverage that only this can
fill. The second is the most likely real-world first-run failure and has zero
coverage anywhere.

---

## Part III — The walk

Onboarding is `[:welcome, :workspace, :tools, :google, :live]`
(`setup_live.ex:32`). **There is no phone step**, which is why Part I's default
costs nothing.

### 0. Before you touch the machine

- [ ] Machine 1's app is **quit**, or machine 2 will get no Twilio credentials
      (Part I).
- [ ] Note the DMG's SHA-256 so what you install is provably what CI built.
- [ ] Decide: real Google account, or skip step 4? Both are valid walks; say
      which you did.

### 0b. The download itself — `DL-1`–`DL-5`

**Added 08-22.** Everything below step 1 tests an app that is *already on the
machine*. Nobody has ever tested how it gets there, and the way it gets there
decides whether step 1 means anything at all.

- [ ] **`DL-1`. The DMG arrives carrying a quarantine flag.** Before mounting:

      xattr -p com.apple.quarantine "$HOME/Downloads/<name>.dmg"

      **This must print a value.** If it errors with *"No such xattr"*, the file
      did not arrive the way a stranger's does and **`FM-2` is void** — Gatekeeper
      simply does not run on an unquarantined file, so the walk will report a
      pass it did not earn.
- [ ] **`DL-2`. The bytes match what was built.** `shasum -a 256` on the arrived
      file equals the checksum recorded in step 0. A DMG that was re-zipped,
      re-hosted or resaved somewhere in the chain is a different artifact.
- [ ] **`DL-3`. The macOS floor stated before the button is `14.0`.** Not after
      it, and not `10.15`. See `WEBSITE_ROADMAP` `G-24` — the public claim was
      nine major versions stale, and the failure it produces is a window that
      never becomes an app. **Read the page as a stranger and write down the
      number it actually told you**, rather than checking that the right number
      appears somewhere on it.
- [ ] **`DL-4`. The page said you need your own Claude subscription** *before*
      the download, and named which architecture you were getting in a sentence
      a non-expert can act on.
- [ ] **`DL-5`. You reached the file by clicking, not by being handed a path.**
      A URL pasted from this repo is not the download path; the download path is
      whatever busterclaw.lol actually links to on the day you walk it.

> **The trap that will void this whole section.** `unzip` from the command line
> **does not propagate quarantine** to the files it extracts; Finder's Archive
> Utility does. So a DMG pulled out of a CI artifact zip with `unzip` looks
> identical to one downloaded normally and behaves completely differently at
> `DL-1`. Extract in Finder, or set the attribute by hand before mounting:
>
>     xattr -w com.apple.quarantine \
>       "0083;00000000;Safari;" "<name>.dmg"
>
> Same hazard for AirDrop and USB from the build machine: both produce a file
> Gatekeeper waves through, and neither tells you it did.

### 1. Install — `FM-2`

- [ ] DMG mounts; drag to Applications; first open.
- [ ] **Record the exact Gatekeeper text**, verbatim. "It worked" is not a
      finding; the sentence a stranger reads is.
- [ ] App window appears. Note **time from double-click to first paint** — the
      shell waits on `/_health` before showing the window, so a slow boot is a
      blank screen of unknown duration.

### 2. First run — `FM-1`, `FM-5`, `FM-6`, `FM-9`

- [ ] The app opens on **`/setup`**, not the homepage (`FM-9`).
- [ ] `security find-generic-password -s BusterClaw -a api_token -w` returns a
      token (`FM-1`).
- [ ] **No plaintext `api_token` file exists** anywhere in the app's data dir.
- [ ] No migration error in the log (`FM-6`).

### 3. Onboarding, all five steps — `FM-3`, `FM-7`

- [ ] **welcome** → reads correctly to someone who has never seen the app.
- [ ] **workspace** → choose a folder. Then **look in it**: compare against
      `Workspace.entries/0` and note anything created that is not declared, or
      declared `:core` and missing (`FM-3`).
- [ ] **tools** → *this is `FM-7`.* If no agent CLI is installed, **record
      exactly what the step says.** Does it name the three supported CLIs? Does
      it say how to install one? Can you proceed past it? A dead end here is a
      dead product for that user.
- [ ] **google** → consent screen lists the scopes; callback returns; the app
      says connected (`FM-8`). Skipping is a valid walk — say so.
- [ ] **live** → completes and lands on the homepage.

### 4. The seeded workspace — `FM-4`

The one thing the dev Mac cannot test, and it shipped today.

- [ ] `jobs/` contains **four** files: `mail-triage.md`, `voicemail-triage.md`,
      `sms-triage.md`, `README.md`.
- [ ] **`grep -r sms_send jobs/` returns nothing.** This is the whole point of
      the 08-18 seed work — a fresh install must never receive a brief naming a
      deleted command.
- [ ] `grep -r phone_call jobs/` returns nothing.
- [ ] `memory/policy.md` exists (still create-only by design — see
      `QA_BACKLOG` V.8).

### 5. The app actually works

- [ ] Terminal opens; `./buster-claw commands` returns **215**.
- [ ] Chat sends and streams, if an agent CLI is installed.
- [ ] Phone tab renders and says **"No number configured"** — the `nil` branch
      added 08-18, which the dev Mac cannot show while a number is configured.
- [ ] Settings → Security shows an audit feed with the run's own events in it.

### 6. Restart

- [ ] Quit and reopen. Onboarding does **not** run again.
- [ ] Workspace, token, and settings all survive.
- [ ] Nothing was re-seeded that should not have been — `jobs/` files keep any
      edit you made in step 4.

---

## Part IV — Traps this walk exists to catch

Named so a failure is recognised rather than debugged from scratch.

1. **A misbuilt DMG refuses to boot, and that is correct.**
   `Application.verify_release_token_safety!/0` raises if a release carries a
   compiled-in dev/test token. If the app dies at launch with that message,
   **the build is wrong, not the machine** — it was built with dev config
   instead of `MIX_ENV=prod`.
2. **The workspace is chosen, not assumed.** Anything that only works because a
   path resolved to the dev machine's `~/Developer/buster-claw` will surface
   here and nowhere else.
3. **`FM-7` has no failure mode we have ever seen.** Nobody has watched this app
   start without an agent CLI present. The honest expectation is that we do not
   know what it does.
4. **Non-admin and non-English are untested** and `QA_BACKLOG` V.7 already says
   so. If the spare machine happens to be either, that is a bonus finding — say
   which it was, because "it worked" means something different on an admin
   account in `en_US`.
5. **A slow first paint reads as a hang.** The window is withheld until
   `/_health` answers. There is no progress indication during that window.

---

## Part V — What to capture

A walk that produces a feeling produces nothing. Capture:

- **The `xattr -p com.apple.quarantine` output** from `DL-1`, pasted. It is the
  one line that says whether the Gatekeeper result below is worth anything.
- **The macOS floor the download page told you**, quoted (`DL-3`).
- **The Gatekeeper sentence, verbatim.**
- **The `tools` step's text when no agent CLI is present** — screenshot.
- **A listing of the workspace folder** after step 3, to diff against
  `Workspace.entries/0`.
- **`./buster-claw commands | wc -l`** — should be 215.
- **Every log line at `warning` or above** during first boot. A fresh install is
  the only time some of them can fire.
- **Anything that made you pause**, even briefly. First-run friction is
  invisible to anyone who has used the app before, and you get exactly one
  chance to notice it on this machine.

> **Every bug found becomes a regression test before the fix is merged.**
> `QA_BACKLOG` V.1 states this as the house rule: the QA lists are one-time
> discovery, the tests are what make them permanent. A finding from this walk
> that lands as a fix with no test has been half-fixed.

---

## Part VI — What this deliberately does not cover

- **`G-4` / the arm64 walk.** Different arch, different machine, different map
  ([`RELEASE_GATE`](RELEASE_GATE_ROADMAP.md)). Do not let this walk's completion
  be read as progress on it.
- **BusterPhone end-to-end.** Part I. The phone is configured after onboarding
  and is not part of first run.
- **The update path.** There is nothing to update *from* — no tag, no release,
  and the download URL on the website is still `DOMAIN-TBD.invalid`. `G-19` is
  unbuilt. A fresh install today is a manual DMG install and cannot be anything
  else.
- **Performance and soak.** `QA_BACKLOG` V.6.
