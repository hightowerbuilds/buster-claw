# busterclaw.lol — where the public finds the app

**Split out of `LAUNCH_ROADMAP.md` 2026-08-09 · Status: ACTIVE, nothing built.**

> ### The one-sentence version
>
> **A stranger lands on busterclaw.lol, understands what this is in one sentence,
> and downloads a DMG that opens with no dialog of any kind.**

**This is a separate repo.** busterclaw.lol serves 200 from Vercel; the source is
not in this tree. Everything below is a change to *that* site, which is why it
kept getting deferred inside a roadmap about signing binaries — it is the only
part of the release that cannot be done from here.

**Today it is three 404s and a wrong headline:**

| Path | State |
|---|---|
| `/` | 200 — leads with the runtime paragraph, which is the sentence [`FRONT_DOOR_ROADMAP`](FRONT_DOOR_ROADMAP.md) exists to replace |
| `/download` | **404** |
| `/privacy` | **404** |
| `/terms` | **404** |

**It gates more than the download.** `/privacy` at a matching domain is a hard
prerequisite for Google OAuth brand verification — see
[`GOOGLE_VERIFICATION_ROADMAP`](GOOGLE_VERIFICATION_ROADMAP.md). The site is
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

- [ ] **G-21.** A **download page** on busterclaw.lol offering both DMGs, with the
      architecture explained in a sentence a non-expert can act on ("Apple Silicon — most
      Macs since 2020" / "Intel"). Today: 404.
- [ ] **G-22.** A **privacy policy** and **terms**. Today: both 404. Also a hard prerequisite
      for Google OAuth verification.
- [ ] **G-23.** The homepage leads with the same sentence as the README and the app's first
      screen (**VI-a**). It currently leads with the runtime paragraph.
- [ ] **G-24.** The communicated macOS floor and the "you need your own Claude subscription"
      requirement are both stated **before** the download button, not after.

**G-23 is not a website task in isolation** — it is one quarter of a four-way
agreement between the README, this site, the onboarding wizard, and the home
screen's primary action. Doing it here alone produces a fourth different pitch.
It belongs to [`FRONT_DOOR_ROADMAP`](FRONT_DOOR_ROADMAP.md) and is listed here
because this is one of the four surfaces that has to change.

**G-24 exists because of a specific failure mode.** The measured macOS floor is
**14.0**, and the app requires the user's own Claude subscription. A visitor who
learns either of those *after* downloading has been wasted, and tells people so.

---

## The landing test

The download page is the only place we can measure whether the pitch works, and
it needs building anyway — so build it once and get the experiment free.

**IX.2 — The landing-page test.** busterclaw.lol needs a download page anyway
(**G-21**). Ship two headline variants at the same URL: **A** = "Buster Claw
answers your phone," **B** = the runtime pitch. Measure visit → download per
variant. **If neither clears ~3–5% from a warm audience, the problem is the
pitch, not the product.**

This tests **H2** in [`DISTRIBUTION_ROADMAP`](DISTRIBUTION_ROADMAP.md) — the
claim that the phone pitch beats the runtime pitch. It is falsifiable and cheap,
and the answer changes what the homepage says.

---

## What this map does not cover

- **The DMG itself** — signing, notarization, stapling, both architectures:
  [`APPLE_ROADMAP`](APPLE_ROADMAP.md).
- **The updater and `latest.json`** — also [`APPLE_ROADMAP`](APPLE_ROADMAP.md).
  The site links to releases; it does not serve updates.
- **Telemetry, the error surface, uninstall docs** —
  [`TRUST_AND_SUPPORT_ROADMAP`](TRUST_AND_SUPPORT_ROADMAP.md).
- **Pricing pages.** There is nothing to sell yet; the locked decision is free
  beta first. See [`DISTRIBUTION_ROADMAP`](DISTRIBUTION_ROADMAP.md).

---

## One risk that lives here

**R10 — busterclaw.lol is an exotic TLD** some corporate mail filters treat
badly, and it is baked into the bundle ID. The door is closed; this is a risk to
watch, not a decision to reopen.
