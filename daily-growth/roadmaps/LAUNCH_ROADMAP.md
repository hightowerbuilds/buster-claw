# Shipping Buster Claw

**The release spine.** What the release *is*, what is true at HEAD, the order to
do it in, and what it costs. The detail lives in seven maps indexed below.

**Rewritten 2026-08-01 · Re-scoped 2026-08-01 (evening) · Split into per-area maps
2026-08-09 · App version 0.1.0 · Status: ACTIVE.**

> ### Read this before splitting anything further
>
> This document used to say *"the single release document… one file, because the
> last time this was four files they disagreed with each other and with the
> code."* **That warning was earned and it still applies.** The 08-09 split was
> made anyway, so that each area could be read from the section of the
> [Supermap](SUPERMAP.md) that owns it — with three mitigations, and they are the
> price of the split:
>
> 1. **No identifier changed.** Every `G-n` and every `III.x` kept its number and
>    its wording. Scripts and CI cite `III.E`, `III.F`, `III.G` and `III.J` by
>    name; commit messages cite `G-n`. **Nothing was renumbered.**
> 2. **Each number lives in exactly one map.** `G-1`–`G-20` in Apple, `G-21`–`G-24`
>    in Website, `G-25`–`G-35` in Trust, `G-36`–`G-41` in Release Gate. A number
>    appearing in two places is the failure mode from last time — check before
>    adding one.
> 3. **This file keeps status, order and cost.** The thing that disagreed last
>    time was *what state we are in*. That answer stays here, in one place.

> ### Two releases, not one
>
> **Release 1 — target: roughly one week.** A signed, notarized, stapled DMG for **both
> architectures**, handed directly to a handful of people we can email. It proves the entire
> Apple path on real hardware with real stakes and no strangers. **The updater does not
> block this** — a new link is an email.
>
> **Release 2 — public download.** A stranger visits **busterclaw.lol**, downloads a DMG,
> double-clicks it, and the app opens with **no dialog of any kind**. This is where the
> updater, telemetry, the download page, and the privacy policy become mandatory, because
> "please re-download" stops being a message you can send to everyone affected.
>
> Every gate item is tagged **[R1]** or **[R2]**. The split exists because the two
> have genuinely different risk: R1's audience can be told things, and R2's cannot.

> **We are not freezing the tree.** Feature work continues on `main` and the release gate
> runs against whatever is there at release time (operator call, 08-01). That is a real
> trade: every merge after a manual QA pass silently invalidates it.
>
> **So the gate is built to be cheap to re-run.** Prefer an assertion in CI over a paragraph
> in a checklist — an automated gate survives a merge and a manual one does not. Where a
> check can only be human (first launch on a clean machine, the III.J walk), **run it against
> the artifact you are actually shipping, as late as possible.**

> ### The trading stack was deleted 2026-08-08
>
> Trading, Portfolio, MarketData, Watchlist and Chart Build were removed whole
> (`293f47f`), and the extension mechanism built to re-home them followed
> (`a89163e`). **~24,000 lines.** Operator decision: size the app down and finish
> what remains.
>
> **This closes gate items and risks rather than completing them** — the honest
> distinction, and the reason each is marked *closed by deletion* rather than
> ticked. Affected: **G-38**, **R9**, **V.9**, **T-10**, two **G-40** manual
> checks, and the Trading rows in the QA checklist and the surface table.
>
> `finance_*` (SEC/Finnhub, public reads) survives; nothing else from that stack does.

---

## The seven maps

| Map | Holds | Numbers |
|---|---|---|
| [`APPLE_ROADMAP`](APPLE_ROADMAP.md) | the complete Apple acceptance path, artifact proof, clean-machine launch, the macOS floor, the updater | `III.0`–`III.J`, `G-1`–`G-20` |
| [`WEBSITE_ROADMAP`](WEBSITE_ROADMAP.md) | busterclaw.lol — download page, privacy, terms, the headline | `G-21`–`G-24` |
| [`TRUST_AND_SUPPORT_ROADMAP`](TRUST_AND_SUPPORT_ROADMAP.md) | telemetry, error surface, uninstall, diagnostics, and making the audit claims true | `G-25`–`G-35` |
| [`RELEASE_GATE_ROADMAP`](RELEASE_GATE_ROADMAP.md) | the dock as product, the human walkthrough, the steering flag, the repeatable checklist | `G-36`–`G-41` |
| [`DISTRIBUTION_ROADMAP`](DISTRIBUTION_ROADMAP.md) | tiers, margin, the five falsifiable claims, concept tests, the bill | `H1`–`H5`, `IX.1`–`IX.5` |
| [`GOOGLE_VERIFICATION_ROADMAP`](GOOGLE_VERIFICATION_ROADMAP.md) | restricted scopes, brand verification, CASA — deferred on purpose | — |
| [`FRONT_DOOR_ROADMAP`](FRONT_DOOR_ROADMAP.md) | one sentence across README, site, wizard and home screen | `VI-a`–`VI-g` |

Plus [`QA_BACKLOG`](QA_BACKLOG.md) — real QA debt that blocks nothing, kept out of
the gate so the gate stays honest.

---

## Contents

- [Part 0 — The short version](#part-0--the-short-version)
- [Part I — Locked decisions](#part-i--locked-decisions)
- [Part II — Verified status at HEAD](#part-ii--verified-status-at-head)
- [Part X — The order to do it in, and the bill](#part-x--the-order-to-do-it-in-and-the-bill)
- [Part XI — Risks](#part-xi--risks)
- [Appendix A — Sources](#appendix-a--sources)
- [Appendix B — Finding index](#appendix-b--finding-index)

*Parts III–IX moved to the maps above on 08-09 and kept their numbering there.*

---

## Part 0 — The short version

**The code is written. Enrollment has cleared. The certificate is the next click.**

**The one thing to do next: create the Developer ID Application certificate (G-2).** Nothing
else in Part III can start, and it is minutes of work.

Between HEAD and **Release 1** — a signed DMG in a few known hands — there are three things:

1. **The certificate does not exist yet.** The account is at the certificates page. Pick
   *Developer ID Application*, not *Installer*; generate the CSR locally so the private key
   stays on a machine you keep; export the `.p12` **with its private key**; back it up
   offline. Then two GitHub secrets and CI starts producing signed builds with no workflow
   edit. See **III.D**.
2. **Nothing has ever been notarized, stapled, or opened on a machine that didn't build
   it.** The pipeline is written against Apple's documented behaviour and Livebook's working
   implementation. That is a strong prior, not evidence. It will be wrong somewhere; budget
   rejection rounds (**III.H**).
3. **First launch on a clean machine is untested.** The TCC prompt, no-`claude`, no-Homebrew,
   and offline paths have never been watched by anyone (**G-9**–**G-15**).

**Deferred to Release 2, deliberately:** the updater, telemetry, the download page, and the
privacy policy. All are mandatory for strangers and none of them are for a group you can
email — which is exactly why Release 1 exists.

**What is no longer in the way.** The build blocker is fixed. Entitlements are correct and
asserted. Every Mach-O in the OTP tree is signed by a script that finds them by content. CI
imports a throwaway keychain, notarizes, staples, verifies all of **III.J**, and tears the
keychain down on failure. Two native architectures, no lipo. **The packaged app is verified
working end to end** — it boots, authenticates, and drives a real browser from inside the
artifact. **CI now proves the artifact, not just the source** (**G-5**), and **the advertised
macOS floor can no longer be a lie** (**G-16**). All of that was "the bulk of the week" in
the previous revision.

**Ordering principle, updated for where we actually are:** the slow external clock (Apple)
has already started and cleared. What remains is ordered by *what fails on someone else's
Mac* — sign it, notarize it, then watch a real person open it on hardware that has never
seen the repo.

**The honest estimate:** **Release 1 in about a week** is achievable, and the largest unknown
is not engineering — it is how many notarization rejection rounds Apple hands back. **Release
2 is a further week or so**, dominated by the updater, whose subtlety is the BEAM swap
described in **III.I**, not the plumbing.

**Money is deliberately not on this path.** The locked decision is *free beta first, charge
later*. Nobody needs to be able to pay for either release to be a success. See **Part VII**.

---
---

## Part I — Locked decisions

Settled in the 07-04, 07-12, and 07-18 operator sessions. Not reopened here; restated so
the rest of the document has a spine.

| Question | Decision | Locked |
|---|---|---|
| Pricing model | Free core + paid tier — **free beta first, charge later** | 07-04 |
| Who pays for Claude | **BYO.** Buyer brings their own Claude subscription. We never resell tokens | 07-04 |
| Target buyer | **Dev-first**, prosumer later | 07-04 |
| The paid tier | **BusterPhone managed telephony. We are the phone company.** | 07-12 |
| Never ship | **BYO-Twilio as the paid tier** — zero marginal cost means nothing to enforce | 07-12 |
| Source model | **Open core, MIT** (`LICENSE`), name/wordmark reserved (`TRADEMARK.md`) | 07-12 |
| Entitlement model | **Server-side by nature. No license-key DRM in the client, ever** | 07-04 |
| Domain | **busterclaw.lol** | 07-14 |
| Bundle ID | **`lol.busterclaw.desktop`** — shipped, one-way door now closed | 07-18 |
| Apple | **Enroll as an individual now** ($99/yr). Don't wait for an entity | 07-04 |
| Distribution | **Developer ID + notarization. Never the Mac App Store** (III.B) | 07-27 |
| Architectures | **Two native single-arch DMGs. Never lipo the ERTS** (III.G) | 07-27 |
| Payments | **Merchant of record** (Paddle or Lemon Squeezy) — they are the seller | 07-04 |
| Business entity | **Deferred.** With an MoR, the LLC is about liability, not tax plumbing | 07-04 |
| A2P registration | **Direct Sole Proprietor**, not a business brand | 07-18 |
| GWS | **Free forever.** Goodwill, not a paywall | 07-12 |
| on-duty | **Free forever, by construction.** It touches none of our infrastructure | 07-12 |
| Signature Feed | **CUT.** Don't re-propose | 07-14 |
| Browserbase | **DELETED.** Never shippable; don't rebuild | 07-12 |
| Whisper / local STT | **DEMOLISHED 06-28.** Don't reflex-rebuild | 06-28 |

**Why this hangs together.** BYO Claude means zero token liability and no AI backend. Open
core is safe because the money leg isn't defended by copyright — it's defended by *owning
the phone number*. A fork gets the engine and none of the business.

---

## Part II — Verified status at HEAD

**Every row below was checked against the working tree on 2026-08-01** by running the thing,
not by reading the previous revision. Where a claim could only be settled by a real
certificate or real hardware, it says so rather than guessing.

### Shipped since the 07-27 revision

| Item | Evidence |
|---|---|
| **BLOCKER-1 — `build_desktop.sh` didn't stage the release** | **Fixed.** The three staging lines are restored, plus a hard assertion that fails the build unless `bin/buster_claw` is executable *and* `erts-*` exists. The failure mode that shipped six days of empty DMGs now cannot exit 0 |
| **Entitlements (III.E)** | **Done.** `plutil -lint` clean; exactly four keys, confirmed by `plutil -convert json`: `allow-jit`, `allow-unsigned-executable-memory`, `disable-library-validation`, `allow-dyld-environment-variables`. `get-task-allow` appears only inside a warning comment, and `PlistBuddy` confirms it does not resolve as a key |
| **Signing every Mach-O (III.F)** | **Done.** `scripts/codesign_release.sh` finds Mach-O **by content**, not mode bits — Livebook's `find -perm +111` would sign 17 of 24 objects and miss seven NIFs that ship without an execute bit. Signs inside-out, `--force`, `--options runtime`, `--timestamp`, retries the flaky Apple timestamp service, verifies every signature, and asserts `allow-jit` actually landed on `beam.smp` |
| **CI signing + notarization (III.H)** | **Done.** Throwaway keychain in `RUNNER_TEMP` (never the login keychain), `set-key-partition-list` so codesign can't block on a GUI prompt, keychain search list **prepended** not replaced, both credential shapes supported, full III.J verification, and an `always()` teardown so a failed build can't leave a private key on shared infrastructure |
| **Info.plist / TCC usage strings (III.E)** | **Done.** `desktop/tauri/Info.plist` carries Desktop, Documents, and Downloads strings. It needs no wiring: verified in the `cargo-tauri` binary's own schema text — *"Tauri also looks for a `Info.plist` file in the same directory as the Tauri configuration file."* Microphone, camera, and Apple Events are deliberately **absent**, and the file explains why so nobody adds them on a hunch |
| **Two architectures (III.G)** | **Done.** `macos-15` (aarch64) + `macos-15-intel` (x86_64), each building its own native ERTS. No lipo anywhere |
| **tauri-cli version drift** | **Fixed 08-01.** CI pinned 2.8.0 while the crate resolved 2.11.1 — and the install step guarded on `command -v`, so with `rust-cache` persisting `~/.cargo/bin` the pin **could not be changed**; editing it would have been a silent no-op on every warm run. Now compares the version, passes `--force`, pinned to 2.11.4 |
| **Version single-sourcing** | **Done.** `VERSION` → `tauri.conf.json` + `Cargo.toml` via `scripts/sync_version.sh`; `mix.exs` reads `VERSION` directly. A release only ever requires editing one file |

> ### The one bug found in that work, and why it is worth recording
>
> `codesign_release.sh` guarded against a double hyphen inside XML comments — a real
> hazard, since AMFI rejects what `plutil` accepts. But the guard scanned the raw file, and
> `<!--` and `-->` **each contain a double hyphen themselves**. It matched every
> well-formed comment, so it could never pass.
>
> The first fix was worse: moving the scan into `OFFENDING_LINES="$(… | grep …)"` under
> `set -euo pipefail` meant a *clean* file made `grep` exit 1, `pipefail` propagated it to
> the assignment, and `set -e` killed the script — **exit 1, no output at all.** A guard
> that fails silently precisely when it has nothing to complain about.
>
> Both are fixed and verified in both directions (clean file passes; a real `--options` in
> a comment body is caught, reported at the correct line, showing the original text).
> **The lesson is the shape:** every guard in this pipeline must be tested against a
> *passing* input, not only a failing one. A guard is code, and untested code is untested
> whether or not it is short.

### Open, confirmed at HEAD

| Item | Evidence |
|---|---|
| **No Apple Developer membership** | No certificate exists. `HAVE_APPLE_CERT` is the CI gate and it is false. **This is the gate on everything in Part III** |
| **Nothing has been signed, notarized, or stapled — ever** | The entire path is written and unexercised. See the banner in III.0 |
| **No updater** | Zero references to `tauri-plugin-updater` in `desktop/tauri/Cargo.toml`. No minisign key exists. **Now P0** (III.I) |
| **No telemetry, no crash reporting** | The only Sentry code is the *integration* that reads the user's own project. Nothing reports our own crashes |
| ~~`minimumSystemVersion` claims macOS 11.0~~ | **Measured and corrected 08-01 → 14.0.** It was wrong by three major versions: the bundled OTP requires 14.0 while the bundle advertised 11.0, so macOS 11–13 got a launch that dies at dyld. Now asserted on every build (**G-16**). The *feature* floor (WebGPU) is still unmeasured — **G-17** |
| **No download page, no privacy policy, no terms** | busterclaw.lol serves 200 from Vercel (separate repo), but `/download`, `/privacy`, `/terms` are all **404**. The homepage leads with the runtime paragraph VI-a exists to replace |
| ~~Nothing proves the packaged app boots~~ | **Closed 08-01.** `smoke_release_boot.sh` is wired into `release-desktop.yml` ahead of signing and upload (**G-5**). The GUI-side `smoke_desktop.sh` is still manual and unvalidated on a hosted runner (**G-6**) |
| **Approval gate is a stub** | `lib/buster_claw/sentinel/pending.ex` — its own moduledoc: *"Approve/deny actions are Phase 2."* |
| **No kill-switch UI** | **Zero** occurrences of `STOP` or `kill_switch` anywhere in `lib/buster_claw_web/` |
| **Security is the last settings tab** | `settings_tabs.ex` — 8th of 8, after Get Started, Appearance, Voice, Notify, Integrations, Configuration, Cmd List |
| **Voice tab is a 58-line dead end** | `voice_live.ex` is 58 lines and tells you the control is elsewhere |
| **Phone tab is in the dock, unbuilt for a new user** | `phone_live.ex` is 1,275 lines; a new user has no number to give out |
| **Bundle size unmeasured post-cleanup** | Playwright and the PLTs are gone; nobody has measured what the DMG now weighs |
| **Two HIGH items in `LEFTOVERS.md`** | Walk a live signed-in checkout and confirm the payment gate fires; send `nosniff` on four pipeline-less media routes |
| **Full clone-to-DMG never run end to end** | **Half closed 08-01.** `build_desktop.sh` ran end to end locally and produced a working `.app` + DMG that passes both smokes. Never yet run from a *clean clone* — the run reused warm caches, which is the difference that hid BLOCKER-1 for six days (**G-7**) |
| **The packaged app is verified working** | **New, positive, 08-01.** `smoke_desktop.sh` PASSED against the real bundle: boots, authenticates, completes a full native-bridge round-trip (Phoenix → PubSub → LiveView → JS → Tauri invoke → POST back), renders a live page through the hidden webview, and drives a headless Chrome over CDP from inside the artifact. The Info.plist TCC strings were confirmed **present in the built bundle**, so Tauri's auto-merge works as documented |

---

---

## Part X — The order to do it in, and the bill

### Stage 0 — Done, and what it unblocked

| # | Task | State |
|---|---|---|
| 0a | Enroll in the Apple Developer Program | **DONE 08-01.** This was the gate on all of Part III |
| 0e | **Identify the Intel Mac** you will run III.J on | **Still owed**, and it is a scheduling dependency, not an engineering one. Every III.J test runs twice |

### Stage 1 — Release 1: get it signed (this week)

*The critical path. Everything else in this document waits behind 1a.*

| # | Task | Cost |
|---|---|---|
| **1a** | **G-2: create + export the Developer ID Application certificate**, back it up offline, add the GitHub secrets | **Minutes. THE NEXT ACTION** |
| 1b | G-2b: App Store Connect API key for notarization (`.p8` downloads once) | Minutes |
| 1c | **G-3: first real signed build.** Expect rejection rounds | Hours to days — the largest unknown here |
| 1d | **G-4: III.J exit tests, both arches, on real hardware** | A day, plus Intel-Mac scheduling |
| 1e | **G-9–G-15: first launch on a clean machine.** TCC prompt, no-`claude`, no-Homebrew, offline | A day. **Run this LAST, against the artifact you ship** |
| 1f | G-34/G-35: the two `LEFTOVERS` HIGH items — payment gate walk, `nosniff` | Hours. Safety, not presentation |
| 1g | **G-7: the clean-clone build.** Local end-to-end passed; a cold clone has not | Hours plus surprises |

### Stage 2 — Free work, any time (does not block Release 1)

| # | Task | Cost |
|---|---|---|
| 2a | **VI-a: pick one front door**; make README, site, wizard, and home agree | Hours. Highest leverage in the document |
| 2b | **Run the one-sentence test** (IX.1) before and after 2a | An afternoon |
| 2c | VI-b/VI-c: delete retired features from the user guide, fix the wizard docs | Hours |
| 2d | G-17/G-17b: the WebGPU feature floor, and stating the floor in the README | A morning |
| 2e | G-36/G-37: move Voice and Phone out of main navigation | Small diffs |

### Stage 3 — Release 2: the public download (the week after)

| # | Task | Cost |
|---|---|---|
| 3a | **G-18–G-20: the updater.** Minisign keypair, **offline key backup**, per-arch `latest.json`, the BEAM-safe swap | **Days. The subtle part is III.I, not the plumbing** |
| 3b | G-21–G-24: download page, `/privacy`, `/terms`, the stated floor and Claude requirement | Hours to a day |
| 3c | G-25–G-28: telemetry, user-facing error surface, uninstall, diagnostic bundle | Days |
| 3d | G-29–G-33: the trust claims — approval gate, kill switch, disclosure, Security tab | Days |
| 3e | 0b/0c/0d: decide on restricted Gmail scopes; start Google verification if yes | Free to decide; weeks to months if yes |

### Stage 4 — Ship, then watch

IX.3 sessions on the real signed DMG · publish · one question by email each week to whoever
shows up: *"What did you use it for this week?"* The answers are the roadmap.

### Explicitly off the critical path

- **SMS / A2P 10DLC** — code-complete, frozen on the Sole-Proprietor registration reset. Does
  not gate anything here.
- ~~**Trading Stages 1–7**~~ — **moot 08-08.** The surface was deleted rather than
  remediated, which closed G-38, R9 and V.9 together.
- **The iPhone companion and the newspaper reader** — separate products (III.K in the 07-27
  revision; retained in git history).
- **Everything in Part V.**

### The bill

| Item | Cost | Frequency |
|---|---|---|
| Apple Developer Program (individual) | **$99** | /yr |
| Developer ID certificate + notarization | $0 | included, unlimited |
| busterclaw.lol domain | ~$10–30 | /yr |
| Static site + download hosting (Vercel / GitHub Releases) | $0 | — |
| Telemetry endpoint (Cloudflare Worker or a $5 VPS) | ~$0–5 | /mo |
| CASA assessment (**only if we keep restricted Gmail scopes**) | ~mid-$100s–$3k+ | /yr |
| Apple's revenue cut on Developer ID | **0%** | vs 15–30% on the App Store |
| **Total to a public download** | **≈$110–130 for the first year** | CASA excluded by deferring Gmail scopes |

**$99 unlocks every Apple item on this page.** The real currency is engineering time — and the
expensive-looking item, App Store compliance, is the one we are deliberately not buying.

---
## Part XI — Risks

- **R1 — Everything Apple is written and unproven.** The whole pipeline is a strong prior, not
  evidence. *Mitigation:* it is guarded and self-asserting at every step, and III.J is checked
  in CI rather than trusted. Expect rejection rounds anyway; budget them.
- **R2 — Google says no, or says slow.** Verification for an agentic email app is genuinely
  uncertain territory. *Mitigation:* defer it entirely (Part VIII), and keep the BYO-OAuth
  developer-preview fallback alive **permanently**.
- **R3 — Public download means strangers on hardware you've never seen.** Every untested first-
  launch path (G-9 through G-15) becomes someone's first impression. *Mitigation:* G-25's
  telemetry and G-26's error surface are what convert an invisible failure into a fixable one.
- **R4 — The minisign key.** Leak it and anyone can push code to every install. Lose it and you
  can never update anyone again. **There is no rotation.** *Mitigation:* offline backup on the
  day it is generated, before the first signed release.
- **R5 — Unknown macOS floor.** Cheap to test, embarrassing to discover via refunds. The
  declared 11.0 is a guess. *Mitigation:* G-16, a morning's work.
- **R6 — Solo-dev support surface, now unbounded.** Autonomous agent + email + someone else's
  Mac, with no cap on who downloads. *Mitigation:* G-28's diagnostic bundle, and teaching users
  to read the Sentinel feed — it is the best support tool we have.
- **R7 — Intel is a one-year shelf.** Rosetta's removal means the Intel DMG has a limited life,
  and every hour spent on it is spent on a shrinking audience. *Mitigation:* ship it, don't
  invest in it, and revisit when macOS 28 lands.
- **R8 — The trust story is the product, and it is currently partly unbacked.** Shipping to
  strangers while `Sentinel.Pending` is a stub and there is no kill-switch UI is the one
  reputational risk that compounds. *Mitigation:* G-29 through G-32 are in the release gate for
  exactly this reason.
- ~~**R9 — Trading is in the dock while its remediation is open.**~~ **CLOSED BY DELETION
  08-08.** The financial surface no longer exists, so there is no unsafe path in it to find.
- **R10 — busterclaw.lol is an exotic TLD** some corporate mail filters treat badly, and it is
  baked into the bundle ID. The door is closed; this is a risk to watch, not a decision to reopen.

---

## Appendix A — Sources

Apple documentation and the July research pass. **Everything here should be re-verified against
Apple's live docs before acting on it** — Apple changes these pages without notice.

- [App Store Review Guidelines](https://developer.apple.com/app-store/review/guidelines/)
- [Apple Developer Program — Enroll](https://developer.apple.com/programs/enroll/)
- [Developer ID](https://developer.apple.com/developer-id/)
- [Notarizing macOS Software Before Distribution](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)
- [Resolving Common Notarization Issues](https://developer.apple.com/documentation/security/resolving-common-notarization-issues)
- [Customizing the Notarization Workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow)
- [Hardened Runtime](https://developer.apple.com/documentation/security/hardened-runtime)
- [Apple Forums 683158 — NSTask in a sandboxed app](https://developer.apple.com/forums/thread/683158)
- [Apple Dev News — Sequoia runtime protection](https://developer.apple.com/news/?id=saqachfa)
- [Tauri v2 — macOS code signing](https://v2.tauri.app/distribute/sign/macos/)
- [Tauri v2 — Updater plugin](https://v2.tauri.app/plugin/updater/)
- [tauri-bundler `macos/app.rs` — proof resources go unsigned](https://github.com/tauri-apps/tauri/blob/dev/crates/tauri-bundler/src/bundle/macos/app.rs)
- [Livebook — `App.entitlements`](https://github.com/livebook-dev/livebook/blob/main/rel/app/src-tauri/App.entitlements)
- [Livebook — two-arch release workflow](https://github.com/livebook-dev/livebook/blob/main/.github/workflows/release.yml)
- [ElixirKit — `Release.codesign/1`](https://github.com/livebook-dev/elixirkit/blob/main/lib/elixirkit/release.ex)
- [Erlang Forums — why a universal ERTS breaks the JIT](https://erlangforums.com/t/is-it-possible-to-build-a-universal-binary-of-erlang-on-macos-arm-intel/975)
- ["Code Signing and Notarization: Sparkle and Tears"](https://steipete.me/posts/2025/code-signing-and-notarization-sparkle-and-tears)
- [Termius docs — no local terminal on MAS](https://docs.termius.com/organize-and-connect-to-hosts/connecting-to-a-server)
- [MacRumors — macOS 27 is the last with Rosetta 2](https://www.macrumors.com/2026/06/10/macos-golden-gate-last-to-support-intel-apps/)
- [Eclectic Light — Gatekeeper & notarization in Sequoia](https://eclecticlight.co/2024/08/10/gatekeeper-and-notarization-in-sequoia/)

**In-repo cross-references:** `BUILD.md` · `docs/DESKTOP_PACKAGING.md` · `docs/QUALITY.md` ·
`docs/LOCAL_TRUST.md` · `phone-maps/BUSTERPHONE_ROADMAP.md` ·
`TRADING_TAB_CRITICAL_REVIEW_ROADMAP.md` · `LEFTOVERS.md`

---

## Appendix B — Finding index

The `F-n` numbering came from the 07-17 first-user review and is preserved so older notes
resolve. `G-n` items are this revision's release gate (Part IV).

| # | Finding | Where it lives now |
|---|---|---|
| F-1 | Unsigned | **Written, unexercised** — III.0, G-1→G-4 |
| F-2 | Intel-only | ✅ **Two-arch CI built** — III.G |
| F-3 | Bundle waste (PLTs, Playwright) | ✅ fixed |
| F-4 | Bundle ID is a personal handle | ✅ fixed 07-18 |
| F-5, F-47 | No updater, no update notification | **G-18→G-20** — now P0 |
| F-6, F-17 | Wizard and README pitch different products | VI-a, **G-23** |
| F-7, F-53 | Homebrew assumed; "Re-check" has no failure detail | **G-10, G-11** |
| F-8 | "You'll do this once" vs 7-day beta tokens | Part VIII |
| F-9 | Max-permission onboarding in one click | VI-e |
| F-10, F-18 | Two agent entry points | VI.1 |
| F-11 | Unauthenticated loopback scopes · key reveal | **G-33** |
| F-12 | `Sentinel.Pending` is a stub with no gate | **G-29** |
| F-13, F-28 | README omits/misdescribes the home chat | VI-d |
| F-14, F-52 | `bypassPermissions` undisclosed | **G-31** |
| F-16 | Trusted-senders gate hidden in a corner widget | V.2 |
| F-19, F-25, F-26, F-27 | Documentation drift | VI-b, VI-c |
| F-20 | Phone in the dock, unbuilt for a new user | **G-37** |
| F-21 | Voice tab is a dead end | **G-36** |
| F-22, F-23, F-38 | Wallets over-built | ✅ removed `db10a58` |
| F-24, F-39 | Multiple independent shader systems | V.6, **G-17** |
| F-29, F-50, F-51 | Retired trial number; two live Supabase functions | ✅ fixed 07-18 |
| F-30, F-31 | Security buried; no refusal badge | **G-32** |
| F-32 | No kill-switch UI | **G-30** |
| F-33, F-46 | No agent-orientation check; empty first run | VI-f, VI-g |
| F-34 | `auth_status` dead signal | ✅ column dropped |
| F-41 | No telemetry or crash reporting | **G-25** |
| F-43 | No user-facing error recovery | **G-26** |
| F-44 | No workspace move/reset/export from the UI | V.6 |
| F-45 | macOS floor undetermined | **G-16** |
| F-48 | "Shipped = compiles" browser features | ✅ walked 07-22 |
| F-49 | Webview cache shared across builds | V.6 |
| **BLOCKER-1** | `build_desktop.sh` no longer stages the release | ✅ **fixed** — Part II |

---

*The app in here is good, and the pipeline to let it out is now written. What remains is the
part no amount of code can do for you: buy the certificate, run the thing, and watch a stranger
open it on a Mac you have never touched.*
