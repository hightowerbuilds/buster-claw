# busterclaw.lol — where the public finds the app

**Carved out of the launch roadmap 2026-08-09 · Status: ACTIVE, nothing built.**

> ### The one-sentence version
>
> **A stranger lands on busterclaw.lol, understands what this is in one sentence,
> and downloads a DMG that opens with no dialog of any kind.**

**This is a separate repo.** busterclaw.lol serves 200 from Vercel; the source is
not in this tree. Everything below is a change to *that* site, which is why it
kept getting deferred inside a roadmap about signing binaries — it is the only
part of the release that cannot be done from here.

> ### Measured against the live site 2026-08-16, and three of the four rows below were wrong
>
> **"Three 404s" was true and misleading.** The site is a **hash-routed canvas
> app**: the server only ever serves `/`, so every path except the static
> `public/` files 404s by construction. The pages the 404s implied were missing
> mostly exist, at addresses this map had guessed.
>
> | What this map said | What is actually true |
> |---|---|
> | `/download` 404 — no download page | **The download page exists** at `#/downloads/busterclaw`, with seven sub-tabs. But its button points at **`https://DOMAIN-TBD.invalid/BusterClaw-0.1.0-x86_64.dmg`** — verified live in the deployed bundle |
> | `/privacy` and `/terms` 404 | **Both exist and return 200** at `/busterphone/privacy.html` and `/busterphone/terms.html`, shipped for toll-free verification. They are **BusterPhone-scoped**, not site-wide |
> | Homepage has the wrong headline | It leads with *"A desktop runtime that gives an AI agent hands — and a record of what it did with them"* — **the README's first line, verbatim**. Two of `VI-a`'s four surfaces already agree |
>
> **A dead download button is worse than a 404**, and it is the sharpest thing
> this check produced. A 404 reads as "not built yet"; a Download button that
> resolves to `.invalid` reads as broken, and it is the last click before the
> product. It is now `G-21`'s real content.
>
> **And the site was carrying four false capability claims**, live: *"203
> commands"* (211), *"GitHub, Sentry, and Umami"* (Sentry and Umami were removed
> 08-14; only GitHub remains), *"Outbound calling is not built"* (shipped 08-15),
> and A2P 10DLC named as the SMS blocker (abandoned 08-15 for toll-free
> verification). **Fixed in the site repo 08-16 — `buster.md` and the `sr-only`
> block in `index.html` — built clean, not yet deployed.**
>
> **Why none of this was caught here:** the contradicting text lives in another
> repository, on a surface no test in this tree renders. Same structural blind
> spot that produced the two-week licence contradiction in August. **The site is
> a fifth front-door surface and nothing watches it.**

**Today, corrected:**

| Path | State |
|---|---|
| `/` | 200 — headline already matches the README; body copy corrected 08-16 |
| `#/downloads/busterclaw` | **exists — dead DMG link** (`DOMAIN-TBD.invalid`) |
| `/busterphone/privacy.html` · `/terms.html` | **200**, BusterPhone-scoped |
| `/download` · `/privacy` · `/terms` | 404 — hash routing, no rewrites configured |

**It gates more than the download.** `/privacy` at a matching domain is a hard
prerequisite for Google OAuth brand verification — see
[`GOOGLE_VERIFICATION_ROADMAP`](../integrations/GOOGLE_VERIFICATION_ROADMAP.md). The site is
therefore on two critical paths, not one.

**All of it is R2.** Release 1 hands a DMG to people we can email; none of this
is needed for that. It becomes mandatory the moment a stranger can arrive, which
is the whole definition of Release 2.

---

## The gate

*Numbers are stable and cited from commit messages — re-tagged and re-ordered,
never renumbered. `G-21`–`G-24` were carved out of the launch map and keep their
labels.*

### G-21 — Findable and trustworthy **[R2]**

- [ ] **G-21.** A **download page** offering both DMGs, architecture explained in a sentence
      a non-expert can act on ("Apple Silicon — most Macs since 2020" / "Intel").
      **Rewritten 08-16 against the live site: the page EXISTS** at
      `#/downloads/busterclaw`. What is missing is (a) **a real URL — the button points at
      `DOMAIN-TBD.invalid`**, (b) the arm64 build, and (c) a path-based `/download` that
      survives being typed or pasted. **(a) is the whole gate now** and it needs a hosted
      DMG, not copy.
- [ ] **G-22.** A **site-wide privacy policy** and **terms**. **Half done 08-16:** both exist
      and return 200 at `/busterphone/privacy.html` and `/busterphone/terms.html`, written for
      toll-free verification and scoped to BusterPhone. Whether a BusterPhone-scoped policy
      satisfies **Google OAuth brand verification** is an open question worth answering before
      writing a second one — see [`GOOGLE_VERIFICATION`](../integrations/GOOGLE_VERIFICATION_ROADMAP.md).
- [ ] **G-23.** The homepage leads with the same sentence as the README and the app's first
      screen (**VI-a**). **Half done, and this map had it backwards:** the site and the README
      already say the same sentence verbatim. The two that still disagree are the onboarding
      wizard ("Your assistant, reachable by email") and the home screen — **both in this repo**,
      so `G-23` is no longer blocked on another repository.
- [x] **The site's capability claims match the app.** Deliberately **not given a `G-` number**
      — every existing number has one home and `G-25` is already Trust and Support's, so this
      takes none. Four claims were false and live: 203 commands (211), Sentry/Umami
      integrations (removed 08-14), "outbound calling is not built" (shipped 08-15), and A2P
      10DLC as the SMS blocker (abandoned 08-15 for toll-free verification). Fixed 08-16 in
      `buster.md` and the `sr-only` block of `index.html`; built clean, **not yet deployed**.
      Recorded because it was never anyone's item, which is exactly how it survived.
- [ ] **G-24.** The communicated macOS floor and the "you need your own Claude subscription"
      requirement are both stated **before** the download button, not after.

**G-23 is not a website task in isolation** — it is one quarter of a four-way
agreement between the README, this site, the onboarding wizard, and the home
screen's primary action. Doing it here alone produces a fourth different pitch.
It belongs to [`FRONT_DOOR_ROADMAP`](../distribution/FRONT_DOOR_ROADMAP.md) and is listed here
because this is one of the four surfaces that has to change.

**G-24 exists because of a specific failure mode.** The measured macOS floor is
**14.0**, and the app requires the user's own Claude subscription. A visitor who
learns either of those *after* downloading has been wasted, and tells people so.

> ### Measured 08-18: this is worse than G-24 describes, and G-24 should be re-read
>
> `G-24` is written as a **placement** problem — state the floor *before* the
> download button rather than after. The site does not have a placement problem
> with the floor. **It has a wrong number.**
>
> `documentation.md` says *"Minimum macOS version: 10.15 (Catalina)."*
> `desktop/tauri/tauri.conf.json:38` says `"minimumSystemVersion": "14.0"`.
> **That is nine major versions apart**, and the failure it produces is the exact
> one `scripts/check_macos_floor.sh` was written to prevent — quoted from its own
> header:
>
> > *"macOS refuses to load a Mach-O whose minimum-OS load command is newer than
> > the running system. So on macOS 11, 12, or 13 that bundle installs, passes
> > Gatekeeper, launches the shell — and then dyld rejects `beam.smp` and Phoenix
> > never starts. The user gets a window that never becomes an app."*
>
> So a visitor on Catalina through Ventura reads a supported-version claim,
> downloads, installs, launches, and gets **a window that never becomes an app**.
> There is a build gate asserting this invariant inside the bundle. **The public
> claim sits outside every gate we have**, which is how it got to be nine
> versions stale.
>
> **Moving a correct number earlier on the page is a different job from replacing
> a false one, and only the second is urgent.** Nothing here can fix it — the
> site is a different repository — but the number to put there is `14.0`, and it
> should be taken from `tauri.conf.json` rather than retyped.

### G-45 — `documentation.md` states two more things that are not true **[R2]**

- [ ] **G-45.** Correct or remove the platform-support table and the auto-update
      paragraph in the public `documentation.md`.

Found 08-18 while checking whether busterclaw.lol serves the current build. Both
were verified against the code, not inferred:

| The site says | The code says |
|---|---|
| *"Linux \| Supported \| AppImage, .deb"* | `tauri.conf.json:32` — `"targets": ["app", "dmg"]`. **macOS only.** No Linux bundle is produced by anything in the repo |
| *"iOS / Android \| Research"* | nothing in the tree targets mobile. Harmless as aspiration, misleading in a table whose other rows are read as fact |
| *"Auto-updates are delivered through GitHub Releases via the **Tauri updater plugin**. The app checks for updates on launch and downloads them in the background."* | **there is no updater plugin** — `grep updater` over `tauri.conf.json` and `Cargo.toml` returns nothing. The real mechanism is a minisign-signed `latest.json` feed (`scripts/build_update_feed.sh`), `G-19` — the button — **is unbuilt**, and nothing checks anything on launch |

**Why this is filed as a gate rather than a typo.** The update sentence is not
merely wrong, it is *reassuring*: a reader who believes updates arrive in the
background will not go looking for them, and there is no mechanism that will ever
bring one. That is the same shape as the `Explained.Phone` problem this codebase
spent 08-18 deleting — **a page describing a feature that does not exist, in the
confident present tense.** The difference is that this one is public.

**Sequencing note.** `G-45` cannot be finished before `G-19` and the update feed
exist, because the honest sentence today is *"updates are manual: download the
new DMG."* Write that sentence now and revise it when the feed ships, rather than
leaving the false one standing until it happens to become true — which is exactly
how `README.md:31` survived being wrong for three days.

---

## The landing test

The download page is the only place we can measure whether the pitch works, and
it needs building anyway — so build it once and get the experiment free.

**IX.2 — The landing-page test.** busterclaw.lol needs a download page anyway
(**G-21**). Ship two headline variants at the same URL: **A** = "Buster Claw
answers your phone," **B** = the runtime pitch. Measure visit → download per
variant. **If neither clears ~3–5% from a warm audience, the problem is the
pitch, not the product.**

This tests **H2** in [`DISTRIBUTION_ROADMAP`](../distribution/DISTRIBUTION_ROADMAP.md) — the
claim that the phone pitch beats the runtime pitch. It is falsifiable and cheap,
and the answer changes what the homepage says.

---

## What this map does not cover

- **The DMG itself** — signing, notarization, stapling, both architectures:
  [`APPLE_ROADMAP`](../platform/APPLE_ROADMAP.md).
- **The updater and `latest.json`** — also [`APPLE_ROADMAP`](../platform/APPLE_ROADMAP.md).
  The site links to releases; it does not serve updates.
- **Telemetry, the error surface, uninstall docs** —
  [`TRUST_AND_SUPPORT_ROADMAP`](../platform/TRUST_AND_SUPPORT_ROADMAP.md).
- **Pricing pages.** There is nothing to sell yet; the locked decision is free
  beta first. See [`DISTRIBUTION_ROADMAP`](../distribution/DISTRIBUTION_ROADMAP.md).

---

## One risk that lives here

**R10 — busterclaw.lol is an exotic TLD** some corporate mail filters treat
badly, and it is baked into the bundle ID. The door is closed; this is a risk to
watch, not a decision to reopen.
