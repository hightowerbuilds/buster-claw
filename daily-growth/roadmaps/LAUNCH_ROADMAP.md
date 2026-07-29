# Getting Buster Claw to People

**The single launch document.** Apple, Google, money, focus, QA, testing, and concept
testing — one file, because four files disagreed with each other and with the code.

**Written 2026-07-27 · App version 0.1.0 · Status: ACTIVE — this is the live map.**

> **What this replaces.** This document supersedes and absorbs four roadmaps, all
> deleted on 2026-07-27 (git history retains them):
>
> | Merged in | What it contributed |
> |---|---|
> | `CRITICAL_PATH_ROADMAP.md` (07-20) | The ordered, costed stage list → Part X |
> | `DISTRIBUTION_ROADMAP.md` (07-11) | The Apple research → Part III |
> | `GO_TO_MARKET_ROADMAP.md` (07-04) | Locked business decisions, Google/CASA, the bill → Parts I, IV, V |
> | `FIRST_USER_REVIEW_ROADMAP.md` (07-17) | The 53 walk-the-user findings → Parts VI, VII |
>
> **What it does *not* replace.** Three roadmaps stay live and are referenced, not
> absorbed, because they are feature work rather than distribution:
>
> - `phone-maps/BUSTERPHONE_ROADMAP.md` — the money leg's build plan (Twilio, A2P, drain, costs)
> - `TRADING_TAB_CRITICAL_REVIEW_ROADMAP.md` — Trading safety remediation, Stages 1/2/4/5/6 still open
> - `LEFTOVERS.md` — small deferred items, one of them safety-adjacent and HIGH
>
> **Everything in Part II was re-verified against HEAD on 2026-07-27.** Several
> findings the source roadmaps treated as open are fixed; one new blocker was found
> that none of them knew about.

---

## Contents

- [Part 0 — The short version](#part-0--the-short-version)
- [Part I — Locked decisions](#part-i--locked-decisions)
- [Part II — Verified status at HEAD](#part-ii--verified-status-at-head)
- [Part III — Apple: the complete acceptance path](#part-iii--apple-the-complete-acceptance-path)
- [Part IV — Google verification and CASA](#part-iv--google-verification-and-casa)
- [Part V — Money](#part-v--money)
- [Part VI — Focus: the product story](#part-vi--focus-the-product-story)
- [Part VII — The QA program](#part-vii--the-qa-program)
- [Part VIII — Testing](#part-viii--testing)
- [Part IX — Concept testing](#part-ix--concept-testing)
- [Part X — The order to do it in, and the bill](#part-x--the-order-to-do-it-in-and-the-bill)
- [Part XI — Risks](#part-xi--risks)
- [Appendix A — Sources](#appendix-a--sources)
- [Appendix B — Finding index](#appendix-b--finding-index)

---

## Part 0 — The short version

The software is built. The business around it is not, and — as of this pass — **the
build is broken in a way nobody noticed.**

Three things stand between Buster Claw and a stranger using it:

1. **It cannot be built.** `scripts/build_desktop.sh:76` reads `rm -rf deskt`. The
   three lines that stage the Elixir release into the Tauri bundle were destroyed by
   a truncated edit in commit `2886f96`. Every DMG produced from HEAD — including
   everything `release-desktop.yml` uploads — ships with an empty `Resources/release/`
   and cannot boot Phoenix. See **BLOCKER-1**.
2. **It cannot be opened.** Unsigned, un-notarized. On macOS Sequoia and later the
   Control-click bypass is gone; the user's only buttons are *Move to Trash* and
   *Done*. This is Apple's $99 door, and it is about a week of work behind it.
3. **It cannot be paid for.** No checkout, no number provisioning, no subscription
   lifecycle. A customer literally cannot give us money today.

**Ordering principle, unchanged and still right:** start the slow clocks you don't
control on day one, do the free high-leverage work while they tick, then spend real
engineering on the two things that gate a sale — *openable* (Apple) and *purchasable*
(billing).

**The punchline:** roughly **$99 in cash** and **~3 focused weeks** gets a stranger to
*download → trust → pay for BusterPhone voice*. Google verification and CASA are a
separate, slower, pricier pole that **only the autonomous-email pitch needs** — and can
be deferred entirely if voice is the first paid product.

**The one decision that changes everything, already made and worth restating:** commit
to **BusterPhone voice as the first paid product.** That defers CASA (months, thousands),
turns Google verification into a background task instead of a launch gate, and collapses
the path to revenue.

---

## Part I — Locked decisions

These were settled in the 07-04 and 07-12 operator sessions. They are not reopened here;
they are restated so the rest of the document has a spine.

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
| Payments | **Merchant of record** (Paddle or Lemon Squeezy) — they are the seller | 07-04 |
| Business entity | **Deferred.** With an MoR, the LLC is about liability, not tax plumbing | 07-04 |
| A2P registration | **Direct Sole Proprietor**, not a business brand | 07-18 |
| GWS | **Free forever.** Goodwill, not a paywall — a dev can make their own OAuth client in 20 minutes | 07-12 |
| on-duty | **Free forever, by construction.** It touches none of our infrastructure; there is nothing to withhold | 07-12 |
| Signature Feed | **CUT.** Don't re-propose | 07-14 |
| Browserbase | **DELETED.** Never shippable; don't rebuild | 07-12 |

**Why this hangs together.** BYO Claude means zero token liability and no AI backend.
Open core is safe because the money leg isn't defended by copyright — it's defended by
*owning the phone number*. A fork gets the engine and none of the business.

---

## Part II — Verified status at HEAD

Every row below was checked against the working tree on 2026-07-27, not inherited from
the source roadmaps. **Six things the old roadmaps list as open are already fixed. One
new blocker was found.**

### Fixed since the roadmaps were written

| Old finding | State at HEAD |
|---|---|
| Bundle ID is `com.hightowerbuilds.busterclaw` | **Fixed.** `tauri.conf.json:5` → `lol.busterclaw.desktop` |
| No two-arch CI; arm64 build doesn't exist | **Built.** `.github/workflows/release-desktop.yml` runs `macos-15` (aarch64) + `macos-15-intel` (x86_64), each with its own native ERTS. No lipo. Unsigned, with a `TODO(payday)` marker for the signing steps |
| 8.69 MB of Dialyzer PLTs ship to every user | **Fixed.** `mix.exs:30-31` puts PLTs in `_plts/`, outside `priv/`. `priv/` now holds only `gettext`, `repo`, `static` |
| 17 MB Playwright sidecar in the bundle | **Fixed.** Playwright deleted 07-18. No references remain in `lib`, `scripts`, or `package.json` |
| 900-line Wallets surface in the dock | **Fixed.** Removed in `db10a58`. Dock is now Home · Workspace · Browser · Terminal · Phone · Trading · Settings |
| Retired trial phone number in the docs | **Fixed 07-18.** Live number recorded; old relay torn down |
| Browser primitives "shipped = compiles" | **Fixed 07-22.** Walked against the *packaged* app, agent side and GUI side |

### The new blocker

> ### BLOCKER-1 — `build_desktop.sh` no longer stages the Elixir release
>
> **What.** Commit `2886f96` replaced three lines with one truncated line:
>
> ```diff
> -rm -rf desktop/tauri/resources/release
> -mkdir -p desktop/tauri/resources
> -cp -R "$REPO_ROOT/_build/prod/rel/buster_claw" desktop/tauri/resources/release
> +rm -rf deskt
> ```
>
> **Why it matters.** `tauri.conf.json` maps `resources/release` → `release` in the
> bundle, and `desktop/tauri/src/main.rs:704` looks for `release/bin/buster_claw` to
> spawn Phoenix. `resources/release/` is gitignored except for `.gitkeep`. So a clean
> clone — which is exactly what CI is — bundles an empty directory and produces a DMG
> whose app cannot start.
>
> **Why nobody noticed.** On the operator's machine a previously staged release tree
> was still sitting in `resources/release/`, so local builds kept working. `rm -rf
> deskt` silently removes a directory that does not exist.
>
> **The fix.** Restore the three deleted lines. One-line severity, total-blocker impact.
>
> **The lesson for the QA program.** Nothing in CI proves the packaged app *boots*.
> `release-desktop.yml` uploads a DMG and asserts only that the file exists. See
> **QA-1** and **T-6**.

### Still open, confirmed

| Item | Evidence at HEAD |
|---|---|
| Nothing is signed or notarized | No cert, no signing steps; `HAVE_APPLE_CERT` is the CI gate and it is false |
| **`Entitlements.plist` exists and is empty** | `<dict></dict>`. It is wired into `tauri.conf.json`, so the pipeline *looks* complete — this is the exact "notarization passes, the BEAM crashes on the user's Mac" trap. See **III.E** |
| `minimumSystemVersion` claims macOS 11.0 | `tauri.conf.json:38`. The real floor is set by WebGPU-in-WKWebView and has never been measured. The declared floor is almost certainly wrong |
| No updater | No `tauri-plugin-updater`, no Sparkle, no version check anywhere |
| No telemetry, no crash reporting | Confirmed: the only analytics code is the Umami *integration* (reads the user's own site) |
| Approval gate is a stub | `Sentinel.Pending` is a bounded in-memory list. Its own moduledoc: *"Approve/deny actions are Phase 2."* The README implies refusals are actionable; they are only visible |
| No kill-switch UI | `Orchestration.engage_kill_switch/0` exists; zero references to `STOP` anywhere in `lib/buster_claw_web` |
| Security is the last settings tab | `settings_tabs.ex` — 8th of 8, after Notify was added |
| Voice tab is a 58-line dead end | Static explainer that tells you the control is somewhere else |
| Phone tab is in the dock, unbuilt for a new user | 1,273 lines of polish; a new user has no number to give out |
| Recovery-key reveal in Settings | `settings_live.ex:462` — plaintext key on screen |
| Unauthenticated loopback scopes | `/browser/*`, `/ws/*`, `/finance/api/*` take no token — deliberate and documented in `docs/LOCAL_TRUST.md`, but it is a decision to defend, not an accident |
| Full `build_desktop.sh` → installable DMG never run end-to-end | Still true, and now doubly true given BLOCKER-1 |

---

## Part III — Apple: the complete acceptance path

*This is the section the rest of the launch waits on. Read it once end to end before
touching a certificate.*

### III.A — What "accepted by Apple" actually means for us

The phrase collapses three unrelated approvals. Getting them straight saves weeks.

| Acceptance | Who decides | How long | Do we need it? |
|---|---|---|---|
| **Enrollment** into the Apple Developer Program | Apple, identity check | ~24–48h for individuals (no published SLA) | **Yes — everything waits on it** |
| **Notarization** of each build | An automated malware scanner. No human | Minutes to an hour | **Yes — every release, forever** |
| **App Review** against the App Store Review Guidelines | A human reviewer | ~24–48h typical, plus rejection rounds | **No — and we cannot pass it** |

**Buster Claw takes doors 1 and 2 and never door 3.** Notarization is *not* App Review.
Apple's own wording: *"The Apple notary service is an automated system that scans your
software for malicious content, checks for code-signing issues, and returns the results
to you quickly."* No human looks at the UI, the features, or the business model. Nothing
about the terminal, the agent, or `bypassPermissions` is a problem on this path.

### III.B — Why the Mac App Store is permanently closed

Worth stating precisely, because three of the obvious objections are false and the real
blocker is narrow and absolute.

| Trait | Ruling | Why |
|---|---|---|
| Bundles the Erlang VM, spawns it as a child | **Red herring** | Allowed. Sandboxed apps may spawn helpers inside their own bundle with `com.apple.security.inherit`. Every Electron app does this |
| BEAM's JIT | **Red herring** | `com.apple.security.cs.allow-jit` exists; V8 uses it daily |
| Tauri as the framework | **Red herring** | Tauri v2 has an official MAS distribution guide |
| User-chosen workspace folder | **Fine** | Security-scoped bookmarks |
| **Executes the user's `claude` / shell from `$PATH`** | **Fatal** | The sandbox grants *read* and *read-write* extensions to user-selected files. **There is no execute extension.** And even if exec succeeded, the child inherits our container and could not see `~/.claude` |
| PTY running the user's `/bin/zsh` | **Fatal** | Same root cause. A terminal *UI* can ship; the user's *shell* cannot |
| `--permission-mode bypassPermissions` | **Fatal** | Guideline 2.5.2, independently — and to a reviewer the name alone reads as a sandbox-escape vector |

Apple DTS, on whether a sandboxed app can execute a user-chosen binary:

> The sandbox extension issued by the open panel is either a read extension or a
> read/write extension. **Neither of these will let you execute code from that
> directory.** — Quinn "The Eskimo!", Apple DTS, forums thread 683158

**The receipt that settles it:** Termius ships a local terminal on every platform
*except* the Mac App Store, and says so in its own docs. Panic's Nova stays off the store
entirely. The one local-shell app on MAS, *rootshell*, ships its own WASM-compiled
utilities and never touches `/bin/zsh`.

> Making Buster Claw store-legal means bundling the agent, replacing the user's shell
> with a WASM shell, and deleting `bypassPermissions`. At that point the reason the
> product exists has been removed. **Not a trade worth making.**

### III.C — Enrollment: the exact checklist

**Cost: $99/year, auto-renewing. One membership covers Developer ID, the Mac App Store,
and iOS — there is no separate purchase.**

- [ ] **An Apple Account with two-factor authentication enabled.** Not optional.
- [ ] **Enroll as an Individual / Sole Proprietor.** No D-U-N-S number, no entity, no
      website requirement. Clears in about a day or two.
      - Organization enrollment instead requires a D-U-N-S number, verified legal entity
        status, legal authority to bind the entity, and a website on the org's domain —
        weeks, not days. **We are not doing this.**
- [ ] **Accept the cost of the public seller name.** As an individual, the certificate
      reads `Developer ID Application: Luke Hightower (TEAMID)`. For a dev tool
      distributed outside the store, nobody will care. Migrating to an organization later
      is a support ticket plus a re-signing exercise — accepted.
- [ ] **Be prepared for identity verification.** Apple may ask for a government ID.
      Budget an extra couple of days for this path.
- [ ] **Accept the Apple Developer Program License Agreement** in the account portal.
      When Apple publishes a new version it must be re-accepted, and services stall until
      it is. Check this before every release cycle.
- [ ] **Skip Agreements, Tax, and Banking.** Those are required only for paid App Store
      sales. Developer ID distribution needs none of it, and our MoR is the seller anyway.
      This trips people up; don't spend a day on it.
- [ ] **Note that enrollment makes you the Account Holder.** Only the Account Holder can
      create Developer ID certificates. There is no delegating this.
- [ ] **Treat the Apple Account as a production credential.** Losing it means losing the
      ability to sign anything. Back up the recovery contacts and 2FA path the same way
      you'd back up a signing key.

**Renewal is load-bearing.** If the membership lapses, existing notarized builds keep
working, but you cannot sign or notarize anything new until it's restored.

### III.D — Certificates and identifiers

- [ ] **Create a Developer ID Application certificate.** This is the only certificate we
      need. It signs the `.app` and the `.dmg`.
- [ ] **Skip the Developer ID Installer certificate.** That signs `.pkg` installers. We
      ship a DMG.
- [ ] **Export the certificate and private key as a `.p12` and back it up offline.**
      Apple limits Developer ID Application certificates per account (currently five).
      Losing the private key burns one of a small number.
- [ ] **Store the `.p12` and its password as GitHub Actions secrets** (`APPLE_CERTIFICATE`,
      `APPLE_CERTIFICATE_PASSWORD`) — `release-desktop.yml` already reads
      `secrets.APPLE_CERTIFICATE` to flip `HAVE_APPLE_CERT`.
- [ ] **No provisioning profile is required** for plain Developer ID + hardened runtime.
      You only need one if you later adopt a capability like APNs or iCloud, at which
      point you register the App ID and embed the profile. Worth knowing so you don't go
      looking for a step that doesn't exist.
- [ ] **Bundle identifier is already locked:** `lol.busterclaw.desktop`. Do not change it.

**On expiry:** Developer ID certificates expire (five years). A signature that carries a
**secure timestamp** stays valid after the certificate expires — which is precisely why
`--timestamp` is not optional. A *revoked* certificate invalidates un-timestamped
signatures immediately.

### III.E — Hardened runtime and entitlements (where we will get burned)

**Notarization rejects any build without the hardened runtime.** It is a flag on every
signature: `codesign --options runtime`.

Entitlements then punch specific holes back through the hardened runtime. The BEAM needs
four, and this is the battle-tested set from Livebook — a Tauri v2 app shipping an
Elixir/OTP release, i.e. *the same architecture*, already notarized and in the wild:

| Entitlement | Why the BEAM needs it |
|---|---|
| `com.apple.security.cs.allow-jit` | BEAM has had a real JIT (BeamAsm) since OTP 24; it needs W^X executable mappings |
| `com.apple.security.cs.allow-unsigned-executable-memory` | Required in practice alongside the above for BEAM's code allocation |
| `com.apple.security.cs.disable-library-validation` | **Required.** BEAM `dlopen`s NIFs — `crypto.so`, `sqlite3_nif.so`, `asn1rt_nif.so`. To the loader, a NIF is a plug-in from another team |
| `com.apple.security.cs.allow-dyld-environment-variables` | OTP's launcher scripts rely on `DYLD_*`-driven dyld behavior |

> ### The subtle one, and it is live in our tree right now
>
> **`desktop/tauri/Entitlements.plist` is an empty `<dict>`.** It is already referenced
> from `tauri.conf.json`, so the build pipeline looks finished.
>
> **Entitlements do not inherit across process boundaries.** `beam.smp` is spawned as a
> separate process from `Contents/Resources/` — it does *not* inherit the Tauri shell's
> entitlements. It must carry `allow-jit` on **its own signature**.
>
> Sign the ERTS binaries without `--entitlements` and here is what happens:
> **notarization passes, the DMG ships, and the BEAM crashes at launch on the user's
> machine under hardened runtime.** It fails nowhere in your pipeline and everywhere in
> theirs. Pass `--entitlements` to *every* binary, not just the app.

**Also required, and easy to forget — Info.plist usage strings.** Under the hardened
runtime, a missing usage description doesn't produce a prompt; the request silently
fails. Audit what the app actually touches:

- [ ] `NSMicrophoneUsageDescription` — if the embedded webview is ever allowed to request
      the mic (WebRTC on a visited page will try).
- [ ] `NSCameraUsageDescription` — same reasoning.
- [ ] `NSAppleEventsUsageDescription` + `com.apple.security.automation.apple-events` —
      only if the app itself scripts other apps. (`scripts/smoke_desktop.sh` uses
      `osascript`, but that runs *outside* the bundle, so it doesn't count.)
- [ ] **TCC Files & Folders.** The default workspace is `~/Desktop/BusterClawCLI`, and
      macOS gates Desktop, Documents, and Downloads behind a user consent prompt. First
      run will show that prompt, and the app must behave correctly if the user says no.
      This is a first-90-seconds experience nobody has tested. See **QA-2**.
- [ ] **No `com.apple.security.get-task-allow` anywhere.** That's the debug entitlement;
      its presence is a hard notary failure.

Point *both* the mix-release signing step and `tauri.conf.json → bundle → macOS →
entitlements` at the same file, so they can never drift.

### III.F — Signing every Mach-O (the trap that eats a day)

> **Tauri does not sign `bundle.resources`.** Confirmed in Tauri's bundler source: it
> signs frameworks, sidecars, and the main executable, and it *copies* resources without
> adding them to the sign list. Its recursive walker descends into six hardcoded folders
> — `MacOS`, `Frameworks`, `Plugins`, `Helpers`, `XPCServices`, `Libraries` — and
> `Resources` is not one of them.

So the naïve path fails in the most misleading way available: **the build succeeds, the
app runs fine locally, and notarization comes back rejected once per unsigned Erlang
binary**, each reading *"The binary is not signed with a valid Developer ID certificate."*

The shipped 0.1.0 bundle contained **25 separate Mach-O objects** — 17 executables plus 8
NIF shared libraries. That count is now stale (Playwright is gone), so **re-measure at
build time**; the discipline is what matters, not the number.

**The fix — Livebook's, exactly.** Sign the OTP tree as a step inside `mix release`,
before Tauri ever bundles it:

```sh
files=$(find <release> -perm +111 -type f \
  -exec sh -c 'file "$1" | grep --silent Mach-O && echo "$1"' _ {} \;)
echo "$files" | xargs -n 1 -I {} codesign --force --options runtime \
  --entitlements Entitlements.plist --sign "$APPLE_SIGNING_IDENTITY" --timestamp {}
```

*Source: `livebook-dev/elixirkit` → `lib/elixirkit/release.ex`*

Rules that go with it:

- [ ] Sign **inside-out**: nested binaries first, the enclosing `.app` last.
- [ ] **Never use `--deep`.** It signs everything with the same entitlements and skips
      things it shouldn't. Apple's own guidance says don't.
- [ ] `--force` so re-signing an already-signed binary replaces rather than errors.
- [ ] `--timestamp` on every single signature.
- [ ] Sign the `.dmg` too, after it's created.

> **Copy Livebook wholesale; invent nothing.** `livebook-dev/livebook`
> (`rel/app/src-tauri/`, `.github/workflows/release.yml`) plus `livebook-dev/elixirkit`
> — same framework, same VM, same bundling problem, public and solved. Everything in
> III.E–III.H is a port, not a design.

### III.G — Two architectures, and never lipo

**Buster Claw is Intel-only today and Rosetta 2 is being switched off.**

- **macOS 26.4** (shipped) — already warns the user when launching an Intel app.
- **macOS 27 "Golden Gate"** (this fall) — the last release with Rosetta 2. Its installer
  *removes* Rosetta; users must deliberately reinstall it.
- **macOS 28** (fall 2027) — Rosetta retained only for a narrow set of legacy games.
  Everything else Intel-only simply fails to open.

Essentially every Mac sold in the last five years is Apple Silicon, so **the app is
already degraded for nearly all prospective users** and has roughly a one-year shelf life
before it stops launching for them at all.

`cargo tauri build --target universal-apple-darwin` makes the *Rust shell* universal —
but the bundled Erlang VM is a separate Mach-O in `Resources/`, and Tauri does nothing to
your resources. A "universal" app with an x86_64-only BEAM inside is an x86_64 app with
extra steps.

> **Do not lipo the ERTS.** Apple restricts dynamic executable-memory mapping in
> universal binaries, so the x86_64 slice of a lipo'd ERTS cannot allocate JIT memory:
>
> ```
> beam/jit/x86/beam_asm.cpp:168: pick_allocator():
> Internal error: jit: Cannot allocate executable memory
> ```
>
> Making a universal ERTS work at all requires building the Intel half **with the JIT
> disabled** — knowingly shipping a materially slower emulator. There is no `configure`
> option for a universal OTP build.

**Two runners, two native ERTS builds, two single-arch DMGs.** This is already
implemented in `release-desktop.yml` and is the one piece of Part III that is done.

**Verdict: arm64 is not a follow-up to shipping. It is a prerequisite.** There is no
point notarizing a DMG most Macs will refuse to run next year.

### III.H — Notarization mechanics

**Credentials.** Two options; the API key is better for CI.

- App Store Connect API key: Issuer ID + Key ID + `.p8` private key, or
- Apple ID + an **app-specific password** + Team ID.

Store either once: `xcrun notarytool store-credentials "busterclaw" …` writes a keychain
profile so no secret appears in a command line.

**The loop.**

```sh
xcrun notarytool submit "Buster Claw_0.1.0_aarch64.dmg" \
  --keychain-profile "busterclaw" --wait

# on rejection — this is the only useful diagnostic:
xcrun notarytool log <submission-id> --keychain-profile "busterclaw"

xcrun stapler staple "Buster Claw_0.1.0_aarch64.dmg"
```

Staple **both** the `.app` (before building the DMG) and the `.dmg`. Stapling attaches
the notarization ticket to the artifact so Gatekeeper can validate it **offline** — a
first launch on a machine with no network still opens clean.

**The good news:** Tauri auto-notarizes. If `APPLE_SIGNING_IDENTITY`, `APPLE_ID`,
`APPLE_PASSWORD`, and `APPLE_TEAM_ID` are present during `tauri build`, it signs, submits,
and staples with no extra step. Once the ERTS tree is pre-signed in the mix-release step,
most of this is already wired.

**Notary's actual requirements, as a checklist:**

- [ ] Signed with a valid Developer ID Application certificate
- [ ] Hardened runtime enabled on every executable (`--options runtime`)
- [ ] A secure timestamp on every signature (`--timestamp`)
- [ ] No `com.apple.security.get-task-allow`
- [ ] Every Mach-O signed individually, inside-out, no `--deep`
- [ ] Built against a reasonably current SDK
- [ ] Code signatures intact *after* bundling (this is what BLOCKER-1's neighbouring
      resources problem is about)

**The five rejections to expect, and their causes:**

| Rejection text | Cause |
|---|---|
| "The binary is not signed with a valid Developer ID certificate" | An unsigned resource — almost always the OTP tree |
| "The signature does not include a secure timestamp" | Missing `--timestamp` |
| "The executable does not have the hardened runtime enabled" | Missing `--options runtime` |
| "The signature of the binary is invalid" | Modified after signing — e.g. a build step that touches files post-`codesign` |
| "The executable requests the com.apple.security.get-task-allow entitlement" | Debug entitlement left in |

### III.I — The updater (do it in the same breath as signing)

There is no updater today. An agentic app that can read and act on your email *will*
someday need a fix shipped fast, and "please re-download" is not a patch channel.

**Two signatures, not one.** The most-missed fact about Tauri's updater:

| Signature | Protects | Verified by |
|---|---|---|
| Apple Developer ID | Gatekeeper / notarization | macOS, at every exec |
| **Minisign (Ed25519)** | Update authenticity | The updater, before it installs |

They are unrelated. Apple's certificate does not satisfy the updater; the minisign key
does not satisfy Gatekeeper. Verification cannot be turned off.

- [ ] Add `tauri-plugin-updater`, generate a minisign keypair, set
      `createUpdaterArtifacts: true`, publish a static `latest.json` on GitHub Releases.
- [ ] **Back up the minisign private key somewhere you'd still have it after your laptop
      is stolen.** Anyone holding it can push arbitrary code to every install. And there
      is no revocation: the public key is compiled into every shipped binary, so a
      rotated key is *rejected* by existing installs. It is dangerous to leak and
      dangerous to lose.
- [ ] **Accept full downloads.** Tauri has no delta updates on macOS, and the
      Sparkle bridge is a signing tarpit whose failures surface at notarization.
      Full downloads over free GitHub Releases bandwidth, a few times a year, is the
      correct trade. Re-measure the bundle first — with PLTs and Playwright gone it is
      well under the old 88 MB.

> **The BEAM gotcha — undocumented, and the one place to diverge from Livebook.**
>
> Tauri's updater renames the running `.app` out from under the live Erlang VM, drops the
> new bundle at the same path, and `rm -rf`s the old one. Open file descriptors survive
> that, so `beam.smp` keeps running — which is what makes it dangerous. **The BEAM loads
> modules lazily, from absolute paths into the bundle.** After the swap, any not-yet-loaded
> module resolves against the *new* release: mixed-version code loading inside a live VM,
> and the same hazard for lazily `dlopen`ed NIFs.
>
> Use the split API, never `download_and_install()`:
> **`download()` and verify → cleanly stop the OTP release and wait for the child to
> actually exit → `install()` → `restart()`.** Make sure the child is *reaped*, not
> orphaned — an orphaned `beam.smp` still holding the SQLite file makes the relaunched
> app fail in a deeply confusing way.

### III.J — Exit tests: the definition of "Apple is done"

Not "it built." These, in order, on hardware that has never seen the repo:

- [ ] `codesign --verify --deep --strict --verbose=2 "Buster Claw.app"` → valid on disk
- [ ] `codesign -dv --verbose=4` shows the Developer ID authority, a timestamp, and
      `runtime` in the flags
- [ ] `spctl -a -t exec -vvv "Buster Claw.app"` → *accepted, source=Notarized Developer ID*
- [ ] `stapler validate` passes on both the `.app` and the `.dmg`
- [ ] **Download the DMG over the web** (so it carries the `com.apple.quarantine`
      attribute — copying via USB does not reproduce the real path), double-click, drag,
      launch: **no dialog at all**
- [ ] **The in-app terminal opens and runs a command.** This is the test that proves
      `beam.smp` got its entitlements — everything upstream can pass while this fails
- [ ] Launch once **with networking disabled** — proves the ticket is stapled
- [ ] Repeat all of the above on the **Intel** DMG on an Intel Mac
- [ ] Verify the arm64 DMG is genuinely arm64: `lipo -archs` on `beam.smp`, not just on
      the shell binary

### III.K — If we ever want a storefront: the reader and the phone

Two doors stay open, and both are separate products, not this one.

**A pure content reader** — no terminal, no subprocesses, no Erlang VM, just HTTP and a
renderer — has none of the sandbox problems. It needs one entitlement
(`com.apple.security.network.client`). It could ship on both the Mac App Store and iOS.
Two catches: it must be genuinely separate (the moment it bundles the VM you're back in
the trap), and it must clear guideline 4.2 "minimum functionality" — Apple rejects thin
readers that are repackaged websites.

**An iPhone companion.** iOS apps cannot spawn child processes — `fork()`, `exec()`, and
`system()` are unavailable and no entitlement restores them. But 2.5.2 forbids executing
code that changes *the app's* functionality; **code running on a remote host does
neither**, which is why Blink, Termius, and a whole cohort of Claude-Code companion apps
ship today.

If it's ever built, three rules decided up front:

- **Do** speak a structured JSON/WebSocket protocol to a daemon on the Mac and render
  **native iOS UI** — task list, diff viewer, approval prompts, streamed logs.
- **Don't** mirror the window as pixels or stream the PTY as a screen. That triggers
  **guideline 4.2.7** (Remote Desktop Clients), whose clause (a) forces the app to be
  **LAN-only** — which annihilates the entire point.
- **Never** execute, interpret, or preview agent-generated code on the device. In March
  2026 Apple pulled "Anything" and blocked updates to Replit and Vibecode citing 2.5.2,
  and that is the active tripwire in exactly our category.

Going through App Review — for either — adds work that Developer ID never asks for:
an App Store Connect record, screenshots for every device size, App Privacy "nutrition
label" disclosures, an age rating, export-compliance answers, a working demo account for
the reviewer, and a rejection loop measured in days.

> **The sequencing insight:** the load-bearing work for a phone app is *not iOS work.*
> It's the Mac-side daemon and a well-specified remote protocol — platform-agnostic,
> useful on its own, and something Buster Claw arguably wants regardless.

---

## Part IV — Google verification and CASA

The app reads and sends Gmail. Those are **restricted scopes**, which means three gates:

1. **OAuth brand verification** — requires a homepage and a privacy policy at a matching
   domain. **busterclaw.lol must be live before this can even start.**
2. **Restricted-scope review** by Google.
3. **CASA security assessment** — an independent lab assessment, **annual**, typically
   mid-hundreds to a few thousand dollars per year. Recurring forever, for as long as we
   touch Gmail scopes.

**Honest timeline: weeks to months.** An app whose pitch is "an AI autonomously reads and
answers your email" should expect extra scrutiny, possibly a rejection round or demands
for scope justification. Budget for one rewrite of the consent screens.

> **The beta-cap gotcha.** While the OAuth app is unverified ("Testing"), only **100
> explicitly listed test users** can connect — and **their refresh tokens expire every 7
> days.** Beta users must reconnect Google weekly until verification clears. The
> onboarding says "you'll do this once," which is false for every beta tester. Say it out
> loud in the beta messaging, and fix the wizard copy (**F-8**).

**Fallback if verification stalls:** GWS ships as "developer preview — bring your own
OAuth app" while the rest of the beta is public. The flagship feature dark for non-dev
users is bad; it is not a launch blocker for the app as a whole.

**The decision that makes this a background task:** if BusterPhone voice is the first paid
product, **CASA can be deferred entirely** and Google verification stops being on the
critical path. This is the single biggest cost you can choose not to pay yet.

- [ ] **Decide explicitly:** does launch need restricted Gmail scopes? Write the answer
      down. If no, close this part and revisit after the first paying user.

---

## Part V — Money

### V.1 — The paid tier is BusterPhone. We are the phone company.

We hold the Twilio account. We provision the number. The user never learns Twilio exists.
They pay us one bill; we pay the wholesaler.

| Tier | What you get | Our marginal cost |
|---|---|---|
| **Free / Channel A** | Bring your own Twilio + Supabase; wire the webhook yourself. Documented in the repo | **$0** — so it's free. Same principle as BYO Claude |
| **Paid** | We are your phone company. A number, the relay, zero setup | **Real, recurring, per-user** — which is what honestly earns a recurring price |

**Why this also fixes the marketing problem.** Today the pitch is *"a desktop runtime
where an agent manages your web interactivity through one auditable command surface"* — a
paragraph, aimed at people who already know they want it. The paid pitch is **"Buster Claw
answers your phone."** Five words. And a phone number is the one thing nobody questions
paying *monthly* for — telephony has been priced that way for a century, so we never have
to teach the customer why it recurs.

**Inbound voice does not require A2P 10DLC.** That registration grind is an *SMS* gate. The
paid tier can ship as "Buster answers your phone" without touching a campaign registration.

### V.2 — What has to be built before anyone can pay

Independent of Apple and Google. This is the actual revenue unlock, and the gap every
review flagged. Rough estimate — the BusterPhone roadmap notes this work "is not in the
phases yet," so treat it as softer than the rest of this document.

- [ ] **Merchant-of-record checkout** (Paddle or Lemon Squeezy). ~5% + fees, no upfront
      cost. They are the seller of record and handle global sales tax. Days.
- [ ] **Number provisioning per paying account**, tied to subscription lifecycle: buy on
      subscribe, **release on cancel** or we pay for that number forever. Several days.
- [ ] **Twilio subaccount isolation** so one user's traffic can't poison everyone's number
      reputation.
- [ ] **Usage caps and an abuse kill switch.** An agent with a phone can be socially
      engineered into recording or calling something it shouldn't, and it is *our* carrier
      reputation. **Caps are a pricing requirement, not a nice-to-have** — a chatty or
      abused account is unbounded minutes against a flat subscription.
- [ ] **In-app "get a number" UI.** Today credentials come only from boot env vars.
- [ ] **An entitlement check** the client asks ("what am I entitled to?") — server-side by
      nature, no license key in the client.

### V.3 — Margin

Measured, not guessed: every voicemail on record costs **$0.0525**, of which
**transcription is $0.0500 — 95% of the total.**

> **Open decision, and it shapes the price:** turn `<Record transcribe="true">` off in the
> voice edge function (~one line; drops a voicemail to ~$0.0025), or keep Twilio
> transcription as COGS at ~5¢/message. A local-STT replacement would be a *fresh*
> decision — Whisper was deliberately demolished 06-28; don't reflex-rebuild. **Decide
> this before pricing anything.**

At $10–15/mo against a number (~$1–2/mo) plus usage, gross margin is roughly 80–85% —
healthy *and honest*, which is the entire premise. Verify every figure against current
Twilio pricing at build time.

### V.4 — The bill

| Item | Cost | Frequency |
|---|---|---|
| Apple Developer Program (individual) | $99 | /yr |
| Developer ID certificate + notarization | $0 | included, unlimited |
| CASA assessment (**only if we keep restricted Gmail scopes**) | ~mid-$100s–$3k+ | /yr |
| busterclaw.lol domain | ~$10–30 | /yr |
| Static site (GitHub Pages) | $0 | — |
| Telemetry endpoint (Cloudflare Worker or a $5 VPS) | ~$0–5 | /mo |
| Twilio number + usage, per paying user | ~$1–2 + usage | /mo |
| Merchant of record | ≈5% + ~$0.50 | per sale |
| Apple's revenue cut on Developer ID | **0%** | vs 15–30% on the App Store |
| **Beta total, ignoring time** | **≈$150/yr without CASA · ≈$3,200/yr with it** | dominated entirely by CASA |

**$99 unlocks every Apple item on this page.** The real currency is engineering time — and
the expensive-looking item, App Store compliance, is the one we are deliberately not buying.

---

## Part VI — Focus: the product story

*From the 07-17 walk-the-user review. The cheapest high-leverage work in this document,
because it is mostly deletion and rewording. Findings are numbered `F-n` and indexed in
Appendix B.*

### VI.1 — The core problem: no front door

Buster Claw is several products sharing one shell, and a new user cannot form a single
mental model in the first session:

| Surface | What it pitches |
|---|---|
| README | "Agent runtime + audit trail" |
| Onboarding wizard | "Your assistant, reachable by email" |
| Home screen | "Chat with Claude" |
| Phone tab | "An answering machine for your agent" (mostly unbuilt for a new user) |
| Trading tab | "A portfolio dashboard" (read-only, remediation in progress) |

**F-17.** A user cannot answer "what is Buster Claw?" after a full session — the answer
changes with the screen. The competitor that wins the comparison is the one whose
one-sentence pitch matches its first screen.

**F-18. Two agent entry points with contradictory docs.** The terminal `on-duty` loop
(durable, queued, auditable) and the home headless chat (ephemeral, conversational) are two
ways to use the same agent, with different state, different trust presentation, and
different docs. The wizard routes you to one; the default tab shows you the other. **Pick
one as the front door and make the other an advanced mode.**

### VI.2 — The trust story is hollow where it should be loudest

The product is sold on auditability. Two independent reviews found the pitch currently
unbacked in the UI:

- **F-12.** `Sentinel.Pending` is an in-memory stub with no approve/deny and no UI. Either
  build the approval gate or stop implying it exists. (~1 day to be honest; more to build.)
- **F-30.** Security is the **last** settings tab. The product's reason for existing is the
  eighth click.
- **F-31.** The refusal queue has no dock badge. "Nothing is invisible" — except the
  refusals.
- **F-32.** No kill-switch UI at all. The emergency brake is a file on disk the user learns
  about from a markdown doc.
- **F-14 / F-52.** `bypassPermissions` is never disclosed. A one-line disclosure on the
  first on-duty or chat run converts a hidden risk into a visible feature.
- **F-11.** The in-app plaintext recovery-key reveal (`settings_live.ex:462`) should be
  reconsidered before strangers run this.

### VI.3 — Half-built surfaces in main navigation

A new user judges maturity by the weakest surface they click.

- **F-20. Phone is in the dock** with 1,273 lines of polish and nothing a new user can do:
  no number to give out, no outbound, and filter tabs that lead to empty states.
- **F-21. Voice is a 58-line dead end** that tells you the control is somewhere else.
- **F-24. Multiple independent shader systems** — each an independent WebGPU render loop
  that can break on a WKWebView bump. Art-project density in a tool whose value prop is
  reliability.

**The dock should be the product, not the roadmap.**

### VI.4 — Documentation drift

The fastest way to destroy trust: tell the user to click something that isn't there.

- **F-19 / F-25.** `user-guide/introduction.md` lists Scheduler, Webhooks, Delivery, and
  Memory as "Advanced." All four are retired.
- **F-26.** `user-guide/setup.md` describes a 3-step wizard; the app has five steps and
  never asks for a name.
- **F-13.** The README says in bold *"There is no LLM inside Buster Claw"* — technically
  true, practically misleading when the default tab is a chat box driving the user's
  Claude. Reword.
- **F-28.** The README never mentions the home chat.

### VI.5 — The focus worklist

| # | Task | Cost |
|---|---|---|
| VI-a | Pick one front door. Make README + wizard welcome + home primary action say the same sentence | Hours. **Highest leverage in this document** |
| VI-b | Delete retired features from `introduction.md` and the user guide | Hours |
| VI-c | Move Phone and Voice out of main nav or behind a labs toggle | Small diffs |
| VI-d | Surface the audit feed: move Security up, add a refusal badge | A day or two |
| VI-e | Add a visible "shift running / STOP" control | A day |
| VI-f | Build the approval gate, or remove the claim | 1 day to be honest; more to build |
| VI-g | Disclose `bypassPermissions` on first run | Hours |
| VI-h | Least-privilege onboarding: Gmail read-only first, widen later (**F-9**) | A day |
| VI-i | Seed a test dispatch item so the first run isn't an empty box (**F-46**) | Hours |
| VI-j | Agent-orientation health check: "your agent found its workspace guide" (**F-33**) | A day |

---

## Part VII — The QA program

*The source roadmaps had QA scattered across three documents as prose. This is the list.*

**Conventions.** `[ ]` items are work. **P0** blocks any external download; **P1** blocks a
credible beta; **P2** is pre-1.0. Every item is meant to be executable by a person with the
app in front of them — if you can't tell whether it passed, it's written wrong.

### QA-0 — Blockers (P0)

- [ ] **Restore the release-staging lines in `build_desktop.sh`** (BLOCKER-1). Nothing
      below matters until a DMG contains an Erlang VM.
- [ ] **Run `build_desktop.sh` clone-to-DMG on a clean machine, once, end to end.** This
      has never been done. It *will* surface surprises. Schedule real time, not an
      afternoon.
- [ ] **Sign + notarize + staple**, both arches (Part III).
- [ ] **Pass every exit test in III.J.**

### QA-1 — Build and packaging (P0)

- [ ] A clean clone with no `_build`, no `node_modules`, no `deps` produces a DMG.
- [ ] `resources/release/` is populated *by the script*, verified with a file-count
      assertion, not by eye.
- [ ] The produced `.app` contains `Contents/Resources/release/bin/buster_claw`.
- [ ] `release-desktop.yml` **boots the packaged app and hits `/_health`** before
      uploading. A DMG that can't start must fail CI. *(This is the gap BLOCKER-1 walked
      through.)*
- [ ] Bundle size measured and recorded post-Playwright, post-PLT. Set a size budget and
      fail the build if it regresses more than ~10%.
- [ ] `lipo -archs` on `beam.smp` in each DMG matches the runner's arch.
- [ ] Version is single-sourced: `VERSION` → `tauri.conf.json`, `Cargo.toml`, `mix.exs`
      all agree in the artifact.
- [ ] The release refuses to boot with a compiled-in dev/test token (already implemented —
      **verify it in the packaged artifact**, not just in a unit test).
- [ ] No `.env`, no dev database, no PLT, no `.d.ts`, no source maps in the bundle.
- [ ] DMG opens, shows the drag-to-Applications layout, and unmounts cleanly.

### QA-2 — Install and first launch, clean machine (P0)

*Run on a Mac that has never seen Buster Claw. A VM snapshot you can roll back is worth an
hour of setup.*

- [ ] Downloaded **over the web** so the quarantine attribute is real.
- [ ] Double-click → no Gatekeeper dialog of any kind.
- [ ] First launch with **no `claude` installed**: the app explains, does not crash
      (**F-7**).
- [ ] First launch with **no Homebrew**: the Tools step gives an actionable message, not
      "Re-check" with no detail (**F-7**, **F-53**).
- [ ] First launch **offline**: opens (stapled ticket), and every network-dependent
      surface degrades with a message rather than a spinner.
- [ ] **TCC prompt** for `~/Desktop` appears when the default workspace is created; the app
      behaves correctly if the user clicks **Don't Allow**.
- [ ] Keychain prompt appears once, is named intelligibly, and "Always Allow" sticks.
- [ ] The API token is generated per-machine at `~/Library/Application
      Support/BusterClaw/api_token`.
- [ ] Data directory created under the new bundle ID; no orphaned directory from the old ID.
- [ ] Second launch is fast and prompts for nothing.
- [ ] Two launches at once → single-instance behavior, not two BEAMs on one SQLite file.
- [ ] Force-quit mid-session → relaunch recovers; no orphaned `beam.smp`, no stale
      `epmd`, no locked database.
- [ ] Log out / log back in; reboot. App relaunches cleanly.

### QA-3 — Onboarding wizard (P1)

- [ ] All five steps complete on a clean machine.
- [ ] Every step can be backed out of and re-entered.
- [ ] Quitting mid-wizard and relaunching resumes sanely.
- [ ] Workspace picker: default path, custom path, a path with spaces, a path with unicode,
      a read-only path, an iCloud-synced path (this repo has been bitten by iCloud
      eviction before), an external volume.
- [ ] "You'll do this once" copy is corrected for the 7-day beta token reality (**F-8**).
- [ ] Google step: consent screen lists only the scopes we actually ask for; the
      least-privilege path exists (**F-9**).
- [ ] Denying Google entirely leaves a usable app.
- [ ] The wizard's final destination and the home screen agree on what to do next
      (**F-10**).
- [ ] `user-guide/setup.md` matches the wizard, step for step (**F-26**).

### QA-4 — Per-surface functional QA (P1)

**Home**
- [ ] Chat send / stream / interrupt / error path; a hung run is killed and reported.
- [ ] Shader background renders, and **degrades to a blank canvas without an error** on a
      machine that lacks WebGPU.
- [ ] SVG sketchpad: renders, zooms, keyboard-navigates, and refuses malicious SVG
      (script tags, external refs, `foreignObject`).
- [ ] Notify widget: timer, alarm, reminder — each fires, rings, and dismisses.
- [ ] Journal note saves to disk and survives restart.

**Terminal**
- [ ] PTY opens with the user's shell; survives tab switches; survives app-window resize.
- [ ] Multiple terminals; close-with-busy-process confirmation.
- [ ] ANSI/color/unicode/wide-glyph rendering; large scrollback doesn't wedge the UI.
- [ ] `./buster-claw` resolves inside the workspace on an installed build.

**Browser**
- [ ] Navigate, back/forward, reload, new tab, close tab, ⌘1–9, ⌘W, ⌘F count.
- [ ] Tab eviction at the cap; popup-as-tab; download + reveal in Finder.
- [ ] Bookmarks round-trip including folders; history dedup and clear.
- [ ] Agent co-presence badge fires on every agent-driven call.
- [ ] SSRF guard: agent-supplied `localhost`, `127.0.0.1`, `169.254.169.254`, an IPv6
      literal, and a DNS-rebinding host are all refused.
- [ ] Agent Mode: run starts, mirror streams, run stops, run survives the command call
      that started it.
- [ ] **The commerce payment gate halts a real signed-in checkout** — the HIGH item in
      `LEFTOVERS.md`. Tested but never walked; the failure mode is an agent proceeding
      through a real payment page.

**Workspace**
- [ ] File tree lists, opens, renders markdown; drag-and-drop import.
- [ ] A file deleted on disk disappears from the UI without an error.
- [ ] Path traversal via a crafted filename is refused.

**Trading**
- [ ] Read-only enforcement holds: no free-form model turn can place, amend, or cancel an
      order. *(Stage 0 complete; Stages 1/2/4/5/6 open — see the Trading roadmap.)*
- [ ] Dashboard renders with zero agent runs on open (cached market data).
- [ ] Rapid account / symbol / range switching never shows stale data or a phantom spinner.
- [ ] Two accounts with identical last-four fail closed.

**Phone**
- [ ] Inbound call → greeting → record → transcript → Library doc + `/phone` row.
- [ ] Voicemail audio plays in the panel.
- [ ] A call while the Mac is asleep drains on wake.
- [ ] Inbound SMS from a trusted number creates a Dispatch item; from a stranger, archives
      only.
- [ ] Outbound `sms_send` respects the kill switch and the daily cap.
- [ ] Empty states for Texts and Calls read as "nothing yet," not as a broken app
      (**F-20**).

**Calendar / Integrations / Security / Settings / Manual**
- [ ] Calendar renders events, handles all-day and multi-day, and an empty month.
- [ ] GitHub / Sentry / Umami: manual poll, webhook with a good signature, webhook with a
      bad signature (**must fail closed**), webhook with no configured secret (**must fail
      closed**).
- [ ] Security feed streams live, redacts secrets, and paginates without falling over at
      10k rows.
- [ ] Every settings toggle persists across restart.
- [ ] Every link in the Manual resolves to a page that exists (**F-19**).

### QA-5 — The agent loop (P1)

- [ ] `on-duty` → item claimed → work → `dispatch reply` → `done`, end to end.
- [ ] The STOP file halts an unattended shift within one tick.
- [ ] The crash-loop brake trips and stops the shift instead of burning tokens.
- [ ] The budget cap stops the shift and records a Sentinel event.
- [ ] Killing the agent process mid-run reclaims the orphaned item immediately.
- [ ] A wall-clock timeout kills the **whole process group** — no orphaned Bash or MCP
      grandchildren.
- [ ] `shift/Dispatch.md` projection matches the database after every state change.
- [ ] Two agents cannot claim the same item.
- [ ] A malicious dispatch item body cannot escalate the caller's trust tier.

### QA-6 — Google Workspace (P1)

- [ ] Connect, disconnect, reconnect; a revoked token surfaces a clear reconnect prompt.
- [ ] Refresh-token expiry (the 7-day beta case) produces a real message, not a silent
      failure.
- [ ] Gmail sync with 0, 1, and thousands of messages.
- [ ] `gmail_send` from an `agent_untrusted` caller is refused and queued.
- [ ] Attachments, unicode subjects, and HTML-only mail don't break the reader.
- [ ] A trusted sender's mail queues; a stranger's mail archives and never queues.
- [ ] Calendar/Drive/Docs/Contacts each survive an empty account and a rate-limited response.

### QA-7 — Security and trust (P0/P1)

- [ ] **Tier matrix, exhaustively:** every one of the ~133 catalog commands, against each
      of `trusted` / `agent_untrusted` / `agent` / `mcp`. Automate this — see **T-3**.
- [ ] A `restricted` command from `mcp` is refused, recorded, and **not executed**.
- [ ] Operator `policy.md` rules tighten but can never loosen a baseline protection.
- [ ] Sentinel redaction: an API key, a Bearer token, an OAuth `code` in a URL, and a card
      number all land redacted — by key name *and* by value shape.
- [ ] A phone PIN never appears in `security_events` in the clear.
- [ ] The unauthenticated loopback scopes (`/browser/*`, `/ws/*`, `/finance/api/*`) are
      re-reviewed and either defended in writing or closed (**F-11**).
- [ ] CSP holds on every page; no inline-script violations in the console.
- [ ] Prompt injection: a hostile web page, a hostile email body, and a hostile SMS body
      each fail to make the agent run a gated command.
- [ ] The recovery-key reveal is reconsidered, and whatever survives is defended in
      `LOCAL_TRUST.md`.
- [ ] `mix sobelow --config` clean; dependency audit clean or every exception documented
      (the earmark advisory already is).

### QA-8 — Data durability and migration (P1)

- [ ] Every migration runs forward on a database seeded with 0.1.0 data.
- [ ] Kill the app mid-write; relaunch; no corruption, no lost dispatch item, no lost
      voicemail.
- [ ] The workspace can be moved, and the app finds it (**F-44** — there is no UI for this
      today).
- [ ] Deleting the workspace out from under a running app produces an error, not a crash
      loop.
- [ ] A full-disk condition is handled.
- [ ] Encrypted secrets survive a restart, and a wrong key fails closed.
- [ ] SQLite WAL files are checkpointed; the app doesn't leave a multi-GB `-wal` behind
      (the dev database currently carries a 4 MB WAL — worth watching in a long-running
      session).

### QA-9 — Performance and resources (P2)

- [ ] Idle CPU with the app open and no work: measure it. The homepage shader is a
      continuous render loop.
- [ ] Battery impact over an hour idle, on battery, lid open.
- [ ] Memory after an 8-hour session; check for leaks in the LiveView processes and the
      screencast caster.
- [ ] The Phone tab's per-row shaders under 100+ rows (**F-24**).
- [ ] Cold start time from double-click to interactive.
- [ ] A 10k-row Security feed and a 5k-item Dispatch queue still render.

### QA-10 — Platform matrix (P1)

Every cell needs at least one full smoke pass.

| | Apple Silicon | Intel |
|---|---|---|
| **Oldest supported macOS** | must be determined (**F-45**) | must be determined |
| **Current macOS** | required | required |
| **Latest beta macOS** | before each release | best effort |

- [ ] **Determine the real macOS floor empirically** and put it in `tauri.conf.json`, the
      README, and the download page. The declared 11.0 is unverified and probably wrong —
      WebGPU-in-WKWebView sets the true floor.
- [ ] Test on a machine with WebGPU unavailable; confirm the blank-canvas fallback and a
      user-visible explanation.
- [ ] Test under a non-admin user account.
- [ ] Test with a non-English system locale and a non-US date format.

### QA-11 — Accessibility (P2)

- [ ] Full keyboard navigation of the dock and every primary surface.
- [ ] VoiceOver can read the audit feed and the chat.
- [ ] Contrast passes for the hazard-orange accent on both backgrounds.
- [ ] Gain/loss and success/refusal are never communicated by color alone.
- [ ] `prefers-reduced-motion` disables the shader animation.

### QA-12 — Support, recovery, uninstall (P1)

- [ ] A user-facing error surface exists: "something went wrong, here's what to do"
      (**F-43** — today the only path is a stderr log in Application Support).
- [ ] A "restart Buster Claw" control.
- [ ] A one-command diagnostic bundle for support tickets (versions, log tail, no secrets).
- [ ] Documented clean uninstall: app, Application Support, Keychain items, WebKit cache.
- [ ] **Webview cache is not shared across builds in a way that shows a beta user stale UI**
      (**F-49**).
- [ ] Update path: 0.1.0 → 0.1.1 preserves workspace, settings, database, and Google
      connection.

### QA-13 — The repeatable release checklist

Everything above is find-the-bugs work. This is the gate that runs every release.

- [ ] `mix precommit` green (compile-as-errors, format, credo --strict, 1,638 tests,
      `check_rust.sh`)
- [ ] `bun test assets/js` green
- [ ] `mix dialyzer` green · `mix sobelow --config` green
- [ ] `scripts/check_docs_drift.sh` green
- [ ] `mix test --include browser_engine` green on a machine with a browser
- [ ] Deno tests for the edge functions green
- [ ] Two-arch DMGs built, signed, notarized, stapled
- [ ] `scripts/smoke_desktop.sh` green against **each** packaged artifact
- [ ] `scripts/smoke_command_surface.sh` green against the packaged app
- [ ] III.J exit tests passed on real hardware, both arches
- [ ] Update from the previous release tested, not assumed
- [ ] `VERSION` bumped, changelog written, `latest.json` published
- [ ] Minisign key backup confirmed to still exist

---

## Part VIII — Testing

### VIII.1 — The baseline, measured today

| Layer | Command | Result |
|---|---|---|
| Elixir | `mix test` | **1,638 tests, 0 failures, 22 excluded**, 20.9s |
| Rust | `scripts/check_rust.sh` | 34 tests incl. `acl_lockstep.rs`; fmt + clippy `-D warnings` |
| JS | `bun test assets/js` | 6 pure-logic suites (ANSI, URL heuristics, tab state, caret keys, shader params, sky) |
| Deno | edge functions | 1 suite (`supabase/functions/sms/index_test.ts`) |
| Static | credo --strict · dialyzer · sobelow · docs-drift | all wired into CI |

**This is a genuinely strong base for a solo project.** Zero warnings, five CI jobs, and a
static ACL lockstep test that catches a class of bug that only appears in the packaged app.
The gaps below are about *where* the confidence sits, not about volume.

### VIII.2 — The gaps, in priority order

| # | Gap | Why it matters |
|---|---|---|
| **T-1** | **No test proves the packaged app boots.** | BLOCKER-1 shipped through five green CI jobs. This is the single highest-value test to add |
| **T-2** | `:browser_engine` tests are excluded by default **and in CI** | The browser engine is one of the largest subsystems and its tests never run automatically |
| **T-3** | No exhaustive tier×command authorization matrix | The trust model is the product's differentiator; it deserves a generated test over the whole catalog, not spot checks |
| **T-4** | No end-to-end LiveView/browser tests | Findings like the Trading stale-SVG defect are invisible to server-rendered-HTML assertions |
| **T-5** | No migration test from a real 0.1.0 database | First update to a real user is the first time this runs |
| **T-6** | `smoke_desktop.sh` is manual and not in CI | The only check that exercises production ACL resolution end to end |
| **T-7** | No soak/leak test | An always-on app with continuous render loops and long-lived LiveViews |
| **T-8** | No prompt-injection regression suite | The most likely real-world attack on an agent runtime |
| **T-9** | Rust `browser/` modules are thinly tested relative to size | 934-line `mod.rs`, 582-line `js.rs` |
| **T-10** | Trading Stage 6 confidence tests | Listed and mostly unchecked in the Trading roadmap |

### VIII.3 — What to add, and in what order

1. **T-1: a packaged-app boot test in CI.** After `build_desktop.sh`, launch the `.app`
   headlessly, poll `/_health`, assert 200, assert the catalog returns ~133 commands, quit.
   This would have caught BLOCKER-1 in the commit that introduced it. *Half a day.*
2. **T-3: generate the authorization matrix.** Iterate `Catalog.entries()` × the four
   caller tiers and assert the decision against the declared `tier`/`gated` metadata. A new
   command is then covered the moment it's added. *Half a day.*
3. **T-2: run `:browser_engine` in a nightly CI job** with a browser installed. Keep it out
   of the PR path for speed; stop letting it rot.
4. **T-6: wire `smoke_desktop.sh` into the release workflow** once signing lands.
5. **T-5: check in a fixture database** captured from a real 0.1.0 install and migrate it in
   CI.
6. **T-4: pick a browser-test tool and cover five paths** — first launch, chat send, tab
   switching under load, Trading account switch, Security feed live update.
7. **T-8: a prompt-injection corpus** — hostile page, hostile email, hostile SMS, hostile
   workspace markdown — asserting no gated command executes.
8. **T-7: a soak job** — run the app for an hour under load, assert memory and process count
   are flat.

### VIII.4 — Principles worth keeping

- **Test at the boundary that fails.** The Trading review's lesson: 131 passing tests
  concentrated on prompt text and pure math missed a stale-DOM defect and an unsafe
  execution boundary.
- **Every bug found in QA gets a regression test before the fix is merged.** The QA lists in
  Part VII are one-time discovery; the tests are what make them permanent.
- **A gate that can be skipped is not a gate.** `mix precommit | tail && git push` shipped a
  red suite once. Use `set -o pipefail` on any `&&` chain that depends on a piped gate.

---

## Part IX — Concept testing

*None of the source roadmaps had this, and it is the cheapest way to avoid building the
wrong thing. Everything here can start before Apple enrollment clears.*

### IX.1 — What we are actually testing

Not "do people like it." Five falsifiable claims, each with a way to be wrong:

| # | Hypothesis | Falsified if |
|---|---|---|
| **H1** | Developers who already pay for Claude want a runtime that gives it hands *plus a receipt* | Interviewees can't name a moment they wished they had an audit trail |
| **H2** | **"Buster Claw answers your phone"** is a stronger hook than the runtime pitch | The runtime pitch converts at least as well on a landing test |
| **H3** | The audit trail is the differentiator against Open Claw / Zero Claw / Hermes | Users say "nice" and rank other features above it |
| **H4** | BYO Claude is not a purchase blocker | Prospects balk at needing their own subscription |
| **H5** | $10–15/mo for a managed number is acceptable | The price sits above "expensive but I'd consider it" for most of the sample |

**A sixth, and the one this document's Part VI exists to answer:** can a new user say what
Buster Claw is, in one sentence, after five minutes? Today the honest expectation is no.

### IX.2 — Method 1: the one-sentence test (this week, free)

The cheapest study available. Show ten people — devs in your network, not friends being
kind — the README's first paragraph and the home screen screenshot, for **fifteen seconds
each**, then ask:

1. What does this do?
2. Who is it for?
3. What would you do first?

**Pass:** seven of ten give the same answer to Q1, and it's the answer you intended.
**Today's likely result is a fail**, and that's the point: it is evidence for VI-a that
costs an afternoon. **Re-run it after the front-door rewrite.** The delta is the finding.

### IX.3 — Method 2: the landing-page test (parallel with Apple's queue)

busterclaw.lol has to exist anyway for Google verification. Make it earn double.

- [ ] Ship two variants at the same URL, alternated: **A** = "Buster Claw answers your
      phone," **B** = "A desktop runtime that gives an AI agent hands — and a full audit
      trail."
- [ ] One call to action: **Join the beta** (email capture). No download yet.
- [ ] Post once to each of two or three places the buyer actually reads. Don't spam.
- [ ] Measure: visit → email conversion per variant, and time-on-page.
- [ ] **Threshold:** if neither variant converts above ~3–5% from a warm audience, the
      problem is the pitch, not the product. Fix the pitch before writing the checkout.

This directly tests **H2**, and every captured email is beta-cohort recruiting.

### IX.4 — Method 3: five moderated first-run sessions (P0 before wide beta)

Five users finds most usability problems; a sixth mostly repeats. Recruit developers who
have used a competing agent runtime — the exact POV of the 07-17 review.

**Setup.** A clean Mac or VM, a signed DMG, screen recording, 45 minutes. You watch and say
nothing beyond "what are you thinking?"

**Tasks, in order, timed:**
1. Install and open the app. *(Measures QA-2 for real.)*
2. Without asking me — what is this for?
3. Get the agent to do one useful thing.
4. Find out what the agent did. *(This is the audit-feed test. **H3** lives or dies here.)*
5. Stop the agent immediately. *(The kill-switch test — **F-32**.)*
6. Find out what the agent is **not allowed** to do.

**Record for each:** completed / gave up / needed a hint; time; the exact words they used
for features (that's your marketing copy); every moment of visible confusion.

**Pass bar:** 4/5 complete tasks 1, 3, 4, and 5 unaided. **Task 4 and task 5 are the ones
that matter** — they are the product's claim.

### IX.5 — Method 4: unmoderated first-ninety-seconds

Cheaper and more brutal. Ten people, no facilitator, recorded. One prompt: *"You've just
downloaded this. Talk out loud."* Stop the tape at ninety seconds.

Measures exactly what the 07-17 review measured by inspection, but with strangers.

### IX.6 — Method 5: pricing research (before the checkout, not after)

Run **Van Westendorp** on the beta list — four questions, ten minutes, ~30 respondents is
enough to be directionally useful:

1. At what price is this **too expensive** to consider?
2. At what price is it **expensive but you'd consider it**?
3. At what price is it a **bargain**?
4. At what price is it **so cheap you'd doubt the quality**?

The crossings give an acceptable range. Sanity-check it against the margin math in **V.3** —
if the acceptable range sits below COGS plus a real margin, the answer isn't a lower price,
it's a different product shape.

Then a blunter question, because stated preference lies: **"Would you pay for this today?
Here's a checkout link."** A pre-order or a paid waitlist deposit is worth more than fifty
survey responses.

### IX.7 — Method 6: the concierge test for BusterPhone

The paid tier needs number provisioning, subscription lifecycle, and abuse controls before
it can be sold. **You do not need any of that to test whether people want it.**

- [ ] Take three to five beta users. Provision their numbers **by hand**, in the Twilio
      console. Invoice them manually — or give it free for a month and ask them to say out
      loud whether they'd have paid.
- [ ] Run it for four weeks.
- [ ] Measure: do they give the number out? How many real calls arrive? Do they read the
      transcripts? Do they ask for it back when you say you're turning it off?

**That last question is the entire test.** If nobody asks for it back, the money leg is
wrong and you'll have learned it for the cost of five phone numbers instead of a month of
provisioning code.

### IX.8 — Method 7: competitive teardown

- [ ] Actually install Open Claw, Zero Claw, and Hermes. Do the six tasks from IX.4 in each.
- [ ] Write down, honestly, the three things each does better.
- [ ] Confirm or kill **H3** with evidence: does any of them have a per-command, redacted,
      trust-tiered audit log with refusal queueing? If one does, the differentiation story
      needs rewriting before launch, not after.

### IX.9 — The beta cohort

- **Size: 10–20.** Small enough to answer every email personally, which is the actual moat
  at this stage. The Google test-user cap is 100, so it isn't the constraint.
- **Recruit** from the landing-page list, prioritising people who already pay for Claude
  (**H4** pre-filters the market either way — better to know now).
- **Tell them up front:** the 7-day Google reconnect (**F-8**), the macOS floor, what
  telemetry collects, and that support is one human.
- **Instrument it:** consent-gated, anonymous, default-off. An install ID and a handful of
  events — app opened, feature touched (terminal / on-duty / browser / phone), crash. A
  retention thermometer, not analytics. Without it the beta is unmeasurable (**F-41**).
- **Qualitative channel:** one shared inbox or channel, and a standing 20-minute call offer.
- **Weekly:** one question by email. *"What did you use it for this week?"* The answers are
  the roadmap.

### IX.10 — Decision gates

| Gate | Signal | Action if it fails |
|---|---|---|
| **After IX.2** | 7/10 same one-sentence answer | Don't build; rewrite the story (VI-a) |
| **After IX.3** | Landing converts >3–5% | Change the pitch, or the buyer |
| **After IX.4** | 4/5 complete the audit + kill tasks | Fix Part VI before inviting anyone |
| **After IX.7** | Users ask for the number back | **Re-open the paid-tier question** before building provisioning |
| **After 30 days of beta** | Users open the app in week 4 | Retention, not acquisition, is the problem — and BusterPhone alone has to answer it |

> **On month six.** The subscription now stands on BusterPhone alone (the Signature Feed
> was cut 07-14). The honest answer to *"why is someone still paying in month six?"* is
> "because the phone keeps answering." If month-six churn says that isn't enough, that is a
> new problem to solve **then** — not a reason to resurrect the feed.

---

## Part X — The order to do it in, and the bill

### Stage 0 — Start the external clocks (day 1, then you wait)

Minutes of work, days or months of queue. They go first for that reason alone.

| # | Task | Cost |
|---|---|---|
| 0a | **Enroll in the Apple Developer Program** (individual, no D-U-N-S) | **$99/yr**, ~1–2 days |
| 0b | **Decide:** does launch need restricted Gmail scopes? | Free. Determines whether CASA exists |
| 0c | If yes to 0b — start Google OAuth verification | $0 for basic; weeks |
| 0d | Stand up busterclaw.lol with privacy policy + terms | Hours. **Blocks 0c** |

### Stage 1 — Unbreak the build (day 1, in parallel)

| # | Task | Cost |
|---|---|---|
| 1a | **Restore the release-staging lines in `build_desktop.sh`** (BLOCKER-1) | Minutes |
| 1b | Add the packaged-app boot check to CI (**T-1**) | Half a day |
| 1c | Run `build_desktop.sh` clone-to-DMG, end to end, once | Hours plus surprises |

### Stage 2 — The story, for free (same week)

| # | Task | Cost |
|---|---|---|
| 2a | Pick one front door; make README, wizard, and home agree (VI-a) | Hours |
| 2b | Delete retired features from the user guide (VI-b) | Hours |
| 2c | Move Phone and Voice out of main nav (VI-c) | Small diffs |
| 2d | **Run the one-sentence test** (IX.2) before and after | An afternoon |

### Stage 3 — The trust story (a day or two)

| # | Task | Cost |
|---|---|---|
| 3a | Build the approval gate, or stop implying it exists (VI-f) | 1 day honest, more to build |
| 3b | Surface the audit feed + refusal badge (VI-d) | A day or two |
| 3c | Visible shift-running / STOP control (VI-e) | A day |
| 3d | Disclose `bypassPermissions` on first run (VI-g) | Hours |

### Stage 4 — Make it openable (~1 week, gated on 0a)

| # | Task | Cost |
|---|---|---|
| 4a | Fill in `Entitlements.plist` (III.E) | Minutes — and it is load-bearing |
| 4b | Add the mix-release codesign pass over every Mach-O (III.F) | The bulk of the week |
| 4c | Wire the `TODO(payday)` steps in `release-desktop.yml` | A day |
| 4d | Notarize + staple, both arches (III.H) | Hours plus rejection rounds |
| 4e | Add the updater, minisign keypair, `latest.json` (III.I) | Days |
| 4f | Pass every III.J exit test on real hardware | A day |

### Stage 5 — Make it purchasable (~1 week+, parallel with Stage 4)

Estimate, not roadmap-sourced. See **V.2** for the item list.

### Stage 6 — QA and beta (days each)

Part VII in priority order, then the IX.4 sessions, then invite the cohort.

### Stage 7 — Credible-beta table stakes

Telemetry (**F-41**) · user-facing error recovery (**F-43**) · the communicated macOS floor
(**F-45**) · a seeded first dispatch item (**F-46**) · update notification (**F-47**).

### Explicitly off the critical path

- **SMS / A2P 10DLC** — code-complete, frozen on the Sole-Proprietor registration reset. It
  does not gate voice revenue.
- **Trading Stages 1–7** — real safety work, tracked in its own roadmap, but the tab is
  read-only today and does not gate a phone sale.
- **The iPhone companion and the newspaper reader** — separate products (III.K).
- **The `LEFTOVERS.md` items**, with one exception: **walk the signed-in checkout gate.**
  It is safety-adjacent and belongs in QA-4.

> **One thing to say out loud.** The Google/CASA clock is slower, costlier, and riskier
> than everything Apple asks for. Apple is a week of work and $99. Google is months and
> possibly thousands per year, forever. If both queues are starting, Google should have
> started yesterday — and Apple should not be what's blocking you.

---

## Part XI — Risks

- **R1 — The build was broken and CI said green.** Five jobs pass on a tree that cannot
  produce a working DMG. *Mitigation:* **T-1**, this week. The deeper lesson is that every
  gate we have tests source, and none tests the artifact.
- **R2 — Google says no, or says slow.** Verification for an agentic email app is genuinely
  uncertain territory. *Mitigation:* start now, write scope justifications carefully, keep
  the BYO-OAuth developer-preview fallback alive permanently.
- **R3 — The market is "people who already pay for Claude."** BYO Claude was right, but
  every customer is pre-filtered by an existing Anthropic relationship. Dev-first works
  *because* devs already have Claude Code; the prosumer expansion eventually collides with
  this.
- **R4 — Solo-dev support surface.** Autonomous agent + email + payments + someone else's
  Mac. *Mitigation:* keep the beta small enough to answer every email personally. Teach
  users to read the Sentinel feed — it's the best support tool we have.
- **R5 — One unfinished feature funds all the fixed costs.** CASA, Apple, domain, and the
  MoR cut are underwritten entirely by BusterPhone. If it doesn't convert, nothing else
  does. *Mitigation:* IX.7's concierge test, before the provisioning code.
- **R6 — The minisign key.** Leak it and anyone can push code to every install. Lose it and
  you can never update anyone again. There is no rotation. *Mitigation:* offline backup,
  today, before the first signed release.
- **R7 — Unknown macOS floor.** Cheap to test, embarrassing to discover via refunds. The
  declared 11.0 is a guess.
- **R8 — busterclaw.lol.** Memorable and on-brand; also an exotic TLD that some corporate
  mail filters treat badly. It is now baked into the bundle ID. The door is closed; this is
  a risk to watch, not a decision to reopen.
- **R9 — Trading is in the dock while its remediation is open.** A user who finds an unsafe
  path in a financial surface will not care that it was labelled a prototype.

---

## Appendix A — Sources

Apple documentation and the July research pass. **Everything dated after this repo's
knowledge horizon should be re-verified against Apple's live docs before acting on it** —
Apple changes these pages without notice, and several items below are recent enough to move.

- [App Store Review Guidelines](https://developer.apple.com/app-store/review/guidelines/)
- [Apple Developer Program — Enroll](https://developer.apple.com/programs/enroll/)
- [Compare Memberships](https://developer.apple.com/support/compare-memberships/)
- [Developer ID](https://developer.apple.com/developer-id/)
- [Notarizing macOS Software Before Distribution](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)
- [Resolving Common Notarization Issues](https://developer.apple.com/documentation/security/resolving-common-notarization-issues)
- [Customizing the Notarization Workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow)
- [Hardened Runtime](https://developer.apple.com/documentation/security/hardened-runtime)
- [Protecting User Data with App Sandbox](https://developer.apple.com/documentation/security/protecting-user-data-with-app-sandbox)
- [Apple Forums 683158 — NSTask in a sandboxed app](https://developer.apple.com/forums/thread/683158)
- [Apple Forums 747499 — iOS and fork()](https://developer.apple.com/forums/thread/747499)
- [Apple Dev News — Sequoia runtime protection](https://developer.apple.com/news/?id=saqachfa)
- [Tauri v2 — macOS code signing](https://v2.tauri.app/distribute/sign/macos/)
- [Tauri v2 — App Store distribution](https://v2.tauri.app/distribute/app-store/)
- [Tauri v2 — Updater plugin](https://v2.tauri.app/plugin/updater/)
- [tauri-bundler `macos/app.rs` — proof resources go unsigned](https://github.com/tauri-apps/tauri/blob/dev/crates/tauri-bundler/src/bundle/macos/app.rs)
- [Livebook — `App.entitlements`](https://github.com/livebook-dev/livebook/blob/main/rel/app/src-tauri/App.entitlements)
- [Livebook — two-arch release workflow](https://github.com/livebook-dev/livebook/blob/main/.github/workflows/release.yml)
- [ElixirKit — `Release.codesign/1`](https://github.com/livebook-dev/elixirkit/blob/main/lib/elixirkit/release.ex)
- [Erlang Forums — why a universal ERTS breaks the JIT](https://erlangforums.com/t/is-it-possible-to-build-a-universal-binary-of-erlang-on-macos-arm-intel/975)
- [Sparkle — delta updates](https://sparkle-project.org/documentation/delta-updates/)
- ["Code Signing and Notarization: Sparkle and Tears"](https://steipete.me/posts/2025/code-signing-and-notarization-sparkle-and-tears)
- [Termius docs — no local terminal on MAS](https://docs.termius.com/organize-and-connect-to-hosts/connecting-to-a-server)
- [9to5Mac — Apple pulls "Anything," blocks Replit/Vibecode (Mar 2026)](https://9to5mac.com/2026/03/30/apple-steps-up-crackdown-on-vibe-coding-apps-pulls-anything-from-the-app-store/)
- [MacRumors — macOS 27 is the last with Rosetta 2](https://www.macrumors.com/2026/06/10/macos-golden-gate-last-to-support-intel-apps/)
- [Eclectic Light — Gatekeeper & notarization in Sequoia](https://eclecticlight.co/2024/08/10/gatekeeper-and-notarization-in-sequoia/)

**In-repo cross-references:** `BUILD.md` · `docs/DESKTOP_PACKAGING.md` · `docs/QUALITY.md` ·
`docs/LOCAL_TRUST.md` · `phone-maps/BUSTERPHONE_ROADMAP.md` ·
`TRADING_TAB_CRITICAL_REVIEW_ROADMAP.md` · `LEFTOVERS.md`

---

## Appendix B — Finding index

Numbering preserved from the 07-17 first-user review so older notes and summaries still
resolve. Findings marked ✅ were verified fixed on 2026-07-27.

| # | Finding | Where it lives now |
|---|---|---|
| F-1, F-2 | Unsigned · Intel-only | III, Stage 4 |
| F-3 | Bundle waste (PLTs, Playwright) | ✅ fixed — Part II |
| F-4 | Bundle ID is a personal handle | ✅ fixed 07-18 |
| F-5, F-47 | No updater, no update notification | III.I |
| F-6, F-17 | Wizard and README pitch different products | VI.1, VI-a |
| F-7, F-53 | Homebrew assumed; "Re-check" has no failure detail | QA-2, QA-3 |
| F-8 | "You'll do this once" vs 7-day beta tokens | Part IV, QA-3 |
| F-9 | Max-permission onboarding in one click | VI-h |
| F-10, F-18 | Two agent entry points | VI.1 |
| F-11 | Unauthenticated loopback scopes · key reveal | QA-7 |
| F-12 | `Sentinel.Pending` is a stub with no gate | VI-f |
| F-13, F-28 | README omits/misdescribes the home chat | VI.4 |
| F-14, F-52 | `bypassPermissions` undisclosed | VI-g |
| F-15 | SVG viewer unexplained | VI.3 |
| F-16 | Trusted-senders gate hidden in a corner widget | VI.2 |
| F-19, F-25, F-26, F-27 | Documentation drift | VI-b |
| F-20 | Phone in the dock, unbuilt for a new user | VI-c, QA-4 |
| F-21 | Voice tab is a dead end | VI-c |
| F-22, F-23, F-38 | Wallets over-built; entangled with Phone | ✅ removed `db10a58` |
| F-24, F-39 | Multiple independent shader systems | QA-9 |
| F-29, F-50, F-51 | Retired trial number; two live Supabase functions | ✅ fixed 07-18 |
| F-30, F-31 | Security buried; no refusal badge | VI-d |
| F-32 | No kill-switch UI | VI-e |
| F-33, F-46 | No agent-orientation check; empty first run | VI-i, VI-j |
| F-34 | `auth_status` dead signal | ✅ column dropped (migration `20260718165510`) |
| F-35, F-36, F-37, F-40 | Redundancy and over-engineering | VI.3 |
| F-41 | No telemetry or crash reporting | IX.9, Stage 7 |
| F-42 | No static first-run tour | VI-i |
| F-43 | No user-facing error recovery | QA-12 |
| F-44 | No workspace move/reset/export from the UI | QA-8 |
| F-45 | macOS floor undetermined | QA-10 |
| F-48 | "Shipped = compiles" browser features | ✅ walked 07-22 |
| F-49 | Webview cache shared across builds | QA-12 |
| **BLOCKER-1** | `build_desktop.sh` no longer stages the release | **New 07-27** — Part II, Stage 1a |

---

*The app in here is good. The work left is letting it out: unbreak the build, get Apple's
signature on it, remove the surfaces that don't support one sentence, and lead with the
audit trail that no competitor has.*
