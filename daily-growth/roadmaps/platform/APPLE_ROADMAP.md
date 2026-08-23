# Apple — the complete acceptance path

**Carved out of the launch roadmap 2026-08-09 · Status: ACTIVE. G-1 through G-3 DONE
08-10 — a notarized, stapled x86_64 DMG exists. G-4 needs an Apple Silicon Mac.**

> ### The one-sentence version
>
> **Sign it, notarize it, staple it, and watch it open on a Mac that has never
> seen the repo — twice, once per architecture.**

**Enrollment cleared 2026-08-01.** That was the gate on everything here, and it
is open: the constraint has moved from *waiting on Apple* to *doing the work*.

**The certificate exists as of 2026-08-10** — Team `KD977J8NF6`, G2 issuer, valid
to 2031. Signing is real and its CI import path has been exercised (III.D, G-2).

> ### 🎉 2026-08-10: Apple is done, for one architecture
>
> **`Buster Claw_0.1.0_x64.dmg` is signed, notarized, and stapled**, and every one
> of III.J's eight machine-checkable exit tests passes — including the two that
> only a real notarization can produce: `spctl` reporting
> **`source=Notarized Developer ID`** (not merely "accepted") and `stapler
> validate` on both the `.app` and the `.dmg`.
>
> **Apple's verdict: `Accepted`, "Ready for distribution", zero issues, first
> attempt.** The map budgeted rejection rounds and none were needed.
>
> Two things the ticket independently confirms. Apple issued **27 ticket entries**
> — the app, the Tauri binary, `beam.smp` and every other Mach-O individually —
> which is outside verification that `codesign_release.sh` found them all *by
> content*. And **`beam.smp` carries its own cdhash in the ticket**, so the notary
> specifically blessed the JIT-enabled BEAM. That was the likeliest thing in the
> bundle to be refused, and it wasn't.

**The one thing to do next: an Apple Silicon Mac.** Everything proven above covers
the Intel slice only, and the arm64 slice — most of the user base — has never been
built outside CI, signed, or launched. See the arch note in III.J; **this map had
that dependency recorded backwards until 08-10.**

> ### Stable anchors — do not renumber
>
> **`III.E`, `III.F`, `III.G` and `III.J` are cited by name in code comments** —
> `desktop/tauri/Entitlements.plist`, `scripts/codesign_release.sh`,
> `scripts/build_desktop.sh`, `.github/workflows/release-desktop.yml`. Renaming
> them silently breaks documentation that lives next to the thing it documents.
> **They kept their numbers through the 08-09 split for this reason.** Add
> sections; don't renumber these four.
>
> The same rule holds for `G-n`: stable, cited from commit messages, re-tagged
> and re-ordered but never renumbered.

> ### Written versus exercised — substantially closed 2026-08-10
>
> This banner used to read *"nothing has ever been signed, notarized, stapled, or
> opened on a machine that did not build it."* **The first two clauses are now
> false for x86_64**: a signed DMG exists and is with the notary.
>
> **The last clause is still entirely true, on both architectures.** Nothing has
> been opened on a machine that did not build it, and that is where the remaining
> risk lives — the TCC prompt, no-`claude`, no-Homebrew and offline paths
> (`G-9`–`G-15`), plus every human III.J test. The pipeline was a strong prior and
> it held; **first-launch behaviour has no such prior.**

**Release 1 is this map plus a clean-machine launch.** Everything else in the
release — the website, telemetry, the trust surface — is Release 2 and lives in
its own map. See the [Supermap](../SUPERMAP.md) for which is next.

---

## Part III — Apple: the complete acceptance path

*Read this once end to end before touching a certificate.*

### III.0 — Written versus exercised

The single most important distinction in this document.

| | Written & committed | Exercised against a real cert |
|---|---|---|
| **Credential import (III.D)** | ✅ | ✅ **08-10** |
| Entitlements (III.E) | ✅ | ✅ **08-10** — all four keys on `beam.smp` itself |
| OTP tree signing (III.F) | ✅ | ✅ **08-10** — 24/24 Mach-O, first try |
| Two-arch build (III.G) | 🟡 | 🟡 **x86_64 signed 08-10; aarch64 never built outside CI** |
| **Notary credentials (G-2b)** | ✅ | ✅ **08-10** |
| Notarization + stapling (III.H) | ✅ | ✅ **08-10 — Accepted, zero issues, stapled** |
| Updater (III.I) | ❌ | ❌ |
| Exit tests (III.J) | ✅ asserted in CI | ✅ **all 8 machine checks green on x86_64**; the human four unrun |

*Every mark in the right column arrived on 08-10; the column was empty that morning.*

**A certificate does not flip this column; running things does.** That was the 08-10
lesson and it arrived immediately: the certificate existed and the credential row still
would not have gone green, because the `.p12` macOS produced was one OpenSSL 3 could
write and `security import` could not read (III.D). **On 08-10 this column went from
zero ✅ to seven**, every one earned by running the thing rather than reading it.

**What is left is no longer written-versus-exercised at all.** The updater is unwritten,
and the rest is four tests that need a human in front of hardware — on an architecture
we do not have. No amount of code closes those.

Do not treat the left column as progress toward the right one; it is a prerequisite for
*starting* it. The purpose of the left column is that when the certificate arrives, the
remaining work is *running* the pipeline and fixing what Apple objects to — not writing it
under time pressure with a paid membership ticking.

### III.A — What "accepted by Apple" actually means for us

The phrase collapses three unrelated approvals. Getting them straight saves weeks.

| Acceptance | Who decides | How long | Do we need it? |
|---|---|---|---|
| **Enrollment** into the Apple Developer Program | Apple, identity check | ~24–48h for individuals (no published SLA) | **Yes — everything waits on it** |
| **Notarization** of each build | An automated malware scanner. No human | Minutes to an hour | **Yes — every release, forever** |
| **App Review** against the App Store Review Guidelines | A human reviewer | ~24–48h typical, plus rejection rounds | **No — and we cannot pass it** |

**Buster Claw takes doors 1 and 2 and never door 3.** Notarization is *not* App Review.
Apple's own wording: *"The Apple notary service is an automated system that scans your
software for malicious content, checks for code-signing issues, and returns the results to
you quickly."* No human looks at the UI, the features, or the business model. Nothing about
the terminal, the agent, or `bypassPermissions` is a problem on this path.

### III.B — Why the Mac App Store is permanently closed

Stated precisely, because three of the obvious objections are false and the real blocker is
narrow and absolute.

| Trait | Ruling | Why |
|---|---|---|
| Bundles the Erlang VM, spawns it as a child | **Red herring** | Allowed. Sandboxed apps may spawn helpers inside their own bundle with `com.apple.security.inherit` |
| BEAM's JIT | **Red herring** | `com.apple.security.cs.allow-jit` exists; V8 uses it daily |
| Tauri as the framework | **Red herring** | Tauri v2 has an official MAS distribution guide |
| User-chosen workspace folder | **Fine** | Security-scoped bookmarks |
| **Executes the user's `claude` / shell from `$PATH`** | **Fatal** | The sandbox grants *read* and *read-write* extensions. **There is no execute extension.** And even if exec succeeded, the child inherits our container and could not see `~/.claude` |
| PTY running the user's `/bin/zsh` | **Fatal** | Same root cause. A terminal *UI* can ship; the user's *shell* cannot |
| `--permission-mode bypassPermissions` | **Fatal** | Guideline 2.5.2, independently |

> The sandbox extension issued by the open panel is either a read extension or a read/write
> extension. **Neither of these will let you execute code from that directory.**
> — Quinn "The Eskimo!", Apple DTS, forums thread 683158

**The receipt that settles it:** Termius ships a local terminal on every platform *except*
the Mac App Store, and says so in its own docs. The one local-shell app on MAS, *rootshell*,
ships its own WASM-compiled utilities and never touches `/bin/zsh`.

> Making Buster Claw store-legal means bundling the agent, replacing the user's shell with
> a WASM shell, and deleting `bypassPermissions`. At that point the reason the product
> exists has been removed. **Not a trade worth making.**

### III.C — Enrollment: the exact checklist

**Cost: $99/year, auto-renewing. One membership covers Developer ID, the Mac App Store, and
iOS — there is no separate purchase.** This is item 0a in Part X and the single highest-
leverage thing on this page, because it is the only one whose clock you don't control.

- [ ] **An Apple Account with two-factor authentication enabled.** Not optional.
- [ ] **Enroll as an Individual / Sole Proprietor.** No D-U-N-S number, no entity, no
      website requirement. Clears in about a day or two.
      - Organization enrollment instead requires a D-U-N-S number, verified legal entity
        status, and a website on the org's domain — weeks, not days. **Not doing this.**
- [ ] **Accept the cost of the public seller name.** As an individual the certificate reads
      `Developer ID Application: Luke Hightower (TEAMID)`, and that string is visible to
      anyone who inspects the signature. For a dev tool outside the store, nobody will care.
      Migrating to an organization later is a support ticket plus re-signing — accepted.
- [ ] **Be prepared for identity verification.** Apple may ask for a government ID. Budget
      an extra couple of days for this path.
- [ ] **Accept the Apple Developer Program License Agreement** in the account portal. When
      Apple publishes a new version it must be re-accepted, and services stall until it is.
      **Check this before every release cycle** — it is a silent stall, not an error.
- [ ] **Skip Agreements, Tax, and Banking.** Required only for paid App Store sales.
      Developer ID needs none of it, and our MoR is the seller anyway. This trips people up.
- [ ] **Note that enrollment makes you the Account Holder.** Only the Account Holder can
      create Developer ID certificates. There is no delegating this.
- [ ] **Treat the Apple Account as a production credential.** Losing it means losing the
      ability to sign anything.

**Renewal is load-bearing.** If the membership lapses, existing notarized builds keep
working, but you cannot sign or notarize anything new until it's restored.

### III.D — Certificates and identifiers

**DONE 2026-08-10.** The certificate exists, is installed locally, and its CI import
path has been *exercised* rather than assumed. What follows is what actually
happened, because three steps of the original instructions could not be followed
as written.

| | |
|---|---|
| Team ID | `KD977J8NF6` |
| Subject | `Developer ID Application: Luke Hightower (KD977J8NF6)` |
| Issuer | `Developer ID Certification Authority`, **OU=G2** |
| Valid | 2026-08-10 → **2031-08-11** |
| SHA-1 | `21D1A27D1D2ACB03DF693708BA7D30F4B15F641D` |
| Material | `~/Desktop/apple-dev-skills/` (`developer_id.key`, `.p12`, `.cer`, password) |

- [x] **Created a Developer ID Application certificate.** The only certificate we need. It
      signs the `.app` and the `.dmg`.
- [x] **Skipped the Developer ID Installer certificate.** That signs `.pkg` installers.
- [x] **Exported as `.p12`.** Apple limits Developer ID Application certificates per
      account (currently five). Losing the private key burns one.
- [x] **Stored as GitHub Actions secrets.** `release-desktop.yml` reads
      `secrets.APPLE_CERTIFICATE` to flip `HAVE_APPLE_CERT`, and the workflow header
      documents the full secret list. Adding them is the *only* change needed to turn CI
      from unsigned to signed — no workflow edit. Confirmed: no edit was needed.
- [x] **No provisioning profile is required** for plain Developer ID + hardened runtime.
      Worth knowing so you don't go looking for a step that doesn't exist.
- [ ] **Bundle identifier is locked:** `lol.busterclaw.desktop`. Do not change it.
- [ ] **Back the `.p12` and its password up somewhere off this machine.** Currently on an
      iCloud-synced Desktop — an operator decision on 08-10, recorded because a signing
      key in cloud sync is a choice, not an accident.

#### Three things that stopped the written instructions, in order

**1. There is no Keychain Access → Certificate Assistant on macOS 26.** The app still
exists but moved out of `/System/Applications/Utilities/` to
`/System/Library/CoreServices/Applications/`, and `mdfind` does not index it — so it
looks deleted, and searching *inside* its window finds nothing because Certificate
Assistant is a **menu-bar** item, not a keychain entry.

**Generate the CSR with `openssl` instead.** It produces an equivalent request and
keeps the private key on this Mac, which was the only property that mattered:

```
openssl req -new -newkey rsa:2048 -nodes \
  -keyout developer_id.key \
  -out CertificateSigningRequest.certSigningRequest \
  -subj "/emailAddress=<you>/CN=<Your Name>/C=US"
```

The trade is that **the private key is now a file rather than a keychain entry**, so
the "back it up offline" step stops being optional housekeeping and becomes the only
thing standing between you and a burned certificate.

**2. Apple's certificate page defaults to the wrong Sub-CA.** The *Select a Developer ID
Certificate Intermediary* step offers **G2 Sub-CA** and **Previous Sub-CA**, and lands on
**Previous** — which the page itself says expires **2027-02-01**, a fixed date, not five
years out. Taking the default on 08-10 would have bought a certificate with **under six
months of life** and burned one of five to do it. **Pick `G2 Sub-CA`.** Verify after the
fact with `openssl x509 -noout -issuer`: it must read `OU=G2`.

**3. A `.p12` from OpenSSL 3 cannot be imported by macOS.** OpenSSL 3 defaults to
AES-256-CBC with a SHA-256 MAC; `security import` only understands the legacy
PBE-SHA1-3DES form and fails with:

```
SecKeychainItemImport: MAC verification failed during PKCS12 import (wrong password?)
```

**The password is not wrong.** That message sends you to re-export, re-type, and doubt
the one thing that was correct. Add **`-legacy`** to `openssl pkcs12 -export` and it
imports first try.

> **This one would have detonated in CI, not here.** `release-desktop.yml` runs the same
> `security import`, so the failure would have arrived on the first signed build —
> mid-run, on a machine you cannot inspect, with a message about a password that is fine,
> alongside every other never-exercised step in III.E–III.J. **The general rule: replay a
> CI credential step locally before trusting it to CI.** See the simulation under G-2.

#### Verifying a certificate actually matches its key

Before building the `.p12`, confirm the certificate Apple returned belongs to the key you
hold. The moduli must be identical:

```
openssl x509 -inform DER -in developerID_application.cer -noout -modulus | openssl md5
openssl rsa  -in developer_id.key -noout -modulus | openssl md5
```

Cheap, and it distinguishes "wrong file" from "wrong encryption" before those two failure
modes can be confused with each other.

**On expiry:** Developer ID certificates expire (five years). A signature carrying a
**secure timestamp** stays valid after the certificate expires — which is precisely why
`--timestamp` is not optional, and why `codesign_release.sh` retries rather than dropping it
when Apple's timestamp service flakes. A *revoked* certificate invalidates un-timestamped
signatures immediately.

### III.E — Hardened runtime and entitlements

**Status: written, committed, and asserted. Unexercised.**

**Notarization rejects any build without the hardened runtime** (`--options runtime`).
Entitlements then punch specific holes back through it. The BEAM needs four — the
battle-tested set from Livebook, a Tauri v2 app shipping an Elixir/OTP release, i.e. *the
same architecture*, already notarized and in the wild:

| Entitlement | Why the BEAM needs it |
|---|---|
| `com.apple.security.cs.allow-jit` | BeamAsm has been a real JIT since OTP 24; it needs W^X executable mappings |
| `com.apple.security.cs.allow-unsigned-executable-memory` | BEAM's code allocator does not confine itself to the MAP_JIT regions `allow-jit` alone permits |
| `com.apple.security.cs.disable-library-validation` | BEAM `dlopen`s its NIFs — `crypto.so`, `sqlite3_nif.so`, `asn1rt_nif.so`. To the loader, a NIF is a plug-in from another team |
| `com.apple.security.cs.allow-dyld-environment-variables` | OTP's launcher scripts rely on `DYLD_*`-driven dyld behaviour, which the hardened runtime scrubs |

> **Why this file is not just the shell's business.** **Entitlements do not inherit across
> process boundaries.** `beam.smp` is spawned as a separate process out of
> `Contents/Resources/` and does *not* inherit the Tauri shell's entitlements. It must carry
> them on **its own signature**.
>
> Sign the ERTS without `--entitlements` and: **notarization passes, the DMG ships, and the
> BEAM dies at launch on the user's machine.** It fails nowhere in our pipeline and
> everywhere in theirs. This is why `codesign_release.sh` asserts `allow-jit` is present on
> `beam.smp` after signing rather than trusting that a signature exists, and why CI
> re-asserts it independently on the bundled binary.

**Two traps recorded so they are not re-learned:**

1. **No double hyphen in a comment body.** Illegal in XML; `plutil -lint` accepts it and
   codesign's stricter AMFI parser rejects the *whole file* with `AMFIUnserializeXML: syntax
   error near line N` and signs nothing — a message that names a line and never mentions
   hyphens. Guarded in `codesign_release.sh`. Easy to reland by writing a command flag into
   a comment, which is exactly what happened once.
2. **`com.apple.security.get-task-allow` must never appear.** The debug entitlement is a
   hard notary failure.

**Info.plist usage strings.** Under the hardened runtime a missing usage description doesn't
produce a prompt — the request silently fails. `desktop/tauri/Info.plist` declares Desktop,
Documents, and Downloads, and is auto-merged by Tauri because it sits beside
`tauri.conf.json`. Microphone, camera, and Apple Events are deliberately absent: nothing
captures, and the app scripts nothing. **Declaring a permission we never exercise is its own
small breach of the trust story.**

- [ ] **TCC Files & Folders is still untested behaviour.** The default workspace is
      `~/Desktop/BusterClawCLI`, so the Desktop prompt fires on first run for essentially
      every new user. **The app must behave correctly when the user clicks Don't Allow**, and
      nobody has ever watched that happen. See **G-9**.

### III.F — Signing every Mach-O

**Status: written, committed, verified in dry-run. Unexercised.**

> **Tauri does not sign `bundle.resources`.** Confirmed in the bundler's own strings: its
> recursive walker descends into six hardcoded folders — `MacOS`, `Frameworks`, `Plugins`,
> `Helpers`, `XPCServices`, `Libraries` — and `Resources` is not one of them. The entire
> Erlang VM lives in `Resources`.

So the naïve path fails in the most misleading way available: **the build succeeds, the app
runs fine locally, and notarization comes back rejected once per unsigned Erlang binary.**

`scripts/codesign_release.sh` handles this, and diverges from Livebook in one way that
matters. Livebook's finder is `find <release> -perm +111`. Measured against our own prod
release (OTP 28.4.2 / erts-16.3.1) that finds **17 of 24** Mach-O objects; the seven it
misses are NIFs shipped without an execute bit — `crypto.so`, `crypto_callback.so`,
`otp_test_engine.so`, `asn1rt_nif.so`, `dyntrace.so`, `trace_ip_drv.so`,
`trace_file_drv.so`. Those are exactly the libraries the BEAM `dlopen`s. Worse, the pass is
*partial* — `sqlite3_nif.so` does carry the bit — so the failure looks arbitrary rather than
systematic. **We identify Mach-O by content (`file`), never by mode bits.**

Rules that go with it, all implemented:

- Sign **inside-out**: nested binaries first, the enclosing `.app` last (sorted deepest-path first).
- **Never `--deep`.** It signs everything with the same entitlements and skips things it
  shouldn't. Apple's own guidance says don't.
- `--force` so re-signing replaces rather than errors.
- `--timestamp` on **every** signature, with retry — the timestamp service is a network
  dependency in the middle of a build and it flakes.
- Verify **every** object, not a spot check.
- Sign the `.dmg` too, after it's created.

**Where it runs.** Inside `build_desktop.sh`, on the staged tree, *before* Tauri bundles —
the last moment the binaries are ours to touch. Anything signed after bundling invalidates
the enclosing signature. It is deliberately **not** duplicated in CI, so local and CI builds
sign identically rather than CI keeping a second copy that drifts.

**Expect the `.so` files to verify but carry no entitlements when inspected.** macOS honours
entitlements only on main executables, so the flag is a no-op for a loadable bundle. That is
fine. What the NIFs need from us is a *signature*; what lets the VM load them is
`disable-library-validation` on `beam.smp`.

- [ ] **Re-measure the object count at build time.** 24 is today's number and will drift.
      The discipline is what matters, not the number.

### III.G — Two architectures, and never lipo

**Buster Claw is Intel-only today and Rosetta 2 is being switched off.**

- **macOS 26.4** (shipped) — already warns the user when launching an Intel app.
- **macOS 27 "Golden Gate"** (this fall) — the last release with Rosetta 2. Its installer
  *removes* Rosetta; users must deliberately reinstall it.
- **macOS 28** (fall 2027) — Rosetta retained only for a narrow set of legacy games.

Essentially every Mac sold in the last five years is Apple Silicon, so **the app is already
degraded for nearly all prospective users.**

`cargo tauri build --target universal-apple-darwin` makes the *Rust shell* universal — but
the bundled Erlang VM is a separate Mach-O in `Resources/`, and Tauri does nothing to your
resources. **A "universal" app with an x86_64-only BEAM inside is an x86_64 app with extra
steps.**

> **Do not lipo the ERTS.** Apple restricts dynamic executable-memory mapping in universal
> binaries, so the x86_64 slice of a lipo'd ERTS cannot allocate JIT memory:
>
> ```
> beam/jit/x86/beam_asm.cpp:168: pick_allocator():
> Internal error: jit: Cannot allocate executable memory
> ```
>
> Making a universal ERTS work at all requires building the Intel half **with the JIT
> disabled** — knowingly shipping a materially slower emulator. There is no `configure`
> option for a universal OTP build.

**Two runners, two native ERTS builds, two single-arch DMGs.** Implemented and committed.

**The check that catches a fake universal build:** `lipo -archs` on **`beam.smp`**, not on
the shell binary. CI asserts this per-arch. It is the only assertion that distinguishes a
genuine arm64 build from an Intel one wearing a universal wrapper.

> **Verdict: arm64 is not a follow-up to shipping. It is a prerequisite.** There is no point
> notarizing a DMG most Macs will refuse to run next year. **Both DMGs ship together or
> neither does.**

### III.H — Notarization mechanics

> ### Re-measured 2026-08-22 — it was queue time, not the artifact
>
> III.H's open question was whether 5½ hours is a **property of this bundle**
> (2,876 files, 2,451 `.beam`) or a queue fluke, and it named the second
> submission as the cheapest way to tell. Three CI runs on 08-22 answered it:
> **the app notarized in minutes, on both architectures, every time.** The
> structural-slowness hypothesis is **not supported** — do not plan releases
> around hours.
>
> Keep the advice anyway. A slow submission is still not a broken one, and the
> `--wait`-outlives-its-client note below is still how you recover.
>
> ### And there are now TWO submissions per build, not one
>
> Tauri notarizes the `.app`. `build_desktop.sh` notarizes the `.dmg`
> afterwards (`44e8bd6`). Both wait. Budget two round trips per architecture.
>
> ### The DMG was never notarized, and G-3 hid it
>
> Found by the III.J staple assertion on run `32618232509`, both architectures:
>
> ```
> Processing: Buster Claw.app
> The validate action worked!
> Processing: Buster Claw_0.1.0_x64.dmg
> Buster Claw_0.1.0_x64.dmg does not have a ticket stapled to it.
> ```
>
> Tauri's sequence, quoted from the build log: *Notarizing `.app` → Accepted →
> Bundling `.dmg` → Signing `.dmg`.* **It signs the image and never submits
> it.**
>
> A stapled app inside an un-notarized image does not save the download. The
> image is what carries the quarantine flag, so the image is what Gatekeeper
> evaluates; with no ticket on it that check needs the network and **fails
> closed offline** — the plane case that stapling exists for. This is exactly
> why III.J validates the image separately instead of trusting the app to imply
> it.
>
> **`G-3` recorded "both artifacts are stapled" on 08-10 and that was true.**
> The operator ran `notarytool` and `stapler` by hand after the script finished,
> and the two commands were never written down. **Every CI build since produced
> an un-stapled image**, and nobody could have known, because the assertion had
> never run.
>
> The lesson is not about Tauri: **a manual step performed during a successful
> milestone gets recorded as a property of the pipeline.** `G-3`'s own text says
> "both artifacts are stapled" — a true statement about that afternoon, read
> ever since as a statement about the build. Anything done by hand to make a
> gate pass has to land in a script in the same sitting or it becomes a lie with
> a date on it.

> ### Budget hours, not minutes — measured 2026-08-10 · **superseded above**
>
> **The first submission took about five and a half hours** from upload to
> `Accepted`. Apple's published guidance is "minutes to an hour," the Developer ID
> Notary Service showed **green with no incident** throughout, and the verdict when
> it came had **zero issues**. Nothing was wrong. It was simply slow.
>
> **Do not read a long wait as a problem.** A malformed artifact, a bad signature,
> or a missing entitlement comes back as `Invalid` **with a per-file log** — it does
> not sit in `In Progress`. Extended `In Progress` is queue time, and there is no
> lever on it.
>
> **The best available explanation is the artifact's shape, and it is a hypothesis
> rather than a finding.** This bundle is **2,876 files, 2,451 of them `.beam`** —
> an entire Erlang/OTP release, where a typical Mac app is a handful of binaries and
> some resources. The notary unpacks and walks all of it. If that is the cause, the
> cost is structural: **every Buster Claw release will be slow to notarize**, and no
> amount of pipeline work changes it. Worth re-measuring on the second submission,
> which is the cheapest way to tell a queue fluke from a property of the artifact.
>
> **Practical consequences for a release day:**
>
> - **Do not schedule notarization as the last step of a working session.** Submit,
>   then do something else.
> - **`notarytool submit --wait` outlives its client being killed.** The submission
>   is server-side; recover with `notarytool history`, never a resubmit — a second
>   upload of the same bytes just competes for the same answer.
> - **Do not touch the artifact while waiting.** The ticket staples to *those* exact
>   bytes; rebuilding orphans it.
> - **Escalation, if it ever is genuinely stuck:** check
>   [developer.apple.com/system-status](https://developer.apple.com/system-status/)
>   for the Developer ID Notary Service, then file Feedback Assistant with the
>   submission ID. A green status page makes that report *more* useful, not less.

**Credentials.** Two shapes; CI supports both and prefers the first.

- **App Store Connect API key** — Issuer ID + Key ID + `.p8`. **Preferred: revocable,
  scoped, and no Apple ID password in CI.**
- Apple ID + an **app-specific password** + Team ID.

Locally, store once: `xcrun notarytool store-credentials "busterclaw" …` writes a keychain
profile so no secret appears in a command line.

```sh
xcrun notarytool submit "Buster Claw_0.1.0_aarch64.dmg" \
  --keychain-profile "busterclaw" --wait

# on rejection — this is the only useful diagnostic:
xcrun notarytool log <submission-id> --keychain-profile "busterclaw"

xcrun stapler staple "Buster Claw_0.1.0_aarch64.dmg"
```

Staple **both** the `.app` (before building the DMG) and the `.dmg`. Stapling attaches the
ticket so Gatekeeper validates **offline** — a first launch on a machine with no network
still opens clean.

**Tauri auto-notarizes** when the credentials are present during `tauri build`, which is what
CI relies on. The ERTS tree is already pre-signed by then.

**Notary's requirements, as a checklist:**

- [ ] Signed with a valid Developer ID Application certificate
- [ ] Hardened runtime on every executable (`--options runtime`)
- [ ] A secure timestamp on every signature (`--timestamp`)
- [ ] No `com.apple.security.get-task-allow`
- [ ] Every Mach-O signed individually, inside-out, no `--deep`
- [ ] Built against a reasonably current SDK
- [ ] Signatures intact *after* bundling

**The five rejections to expect:**

| Rejection text | Cause |
|---|---|
| "The binary is not signed with a valid Developer ID certificate" | An unsigned resource — almost always the OTP tree |
| "The signature does not include a secure timestamp" | Missing `--timestamp` |
| "The executable does not have the hardened runtime enabled" | Missing `--options runtime` |
| "The signature of the binary is invalid" | Modified after signing — a build step touching files post-`codesign` |
| "The executable requests the com.apple.security.get-task-allow entitlement" | Debug entitlement left in |

**Budget for rejection rounds.** Each is minutes-to-an-hour of turnaround. The pipeline is
built to make all five impossible, but it has never run. **Plan two or three rounds and be
pleasantly surprised.**

### III.I — The updater · **MOVED 2026-08-16 → [`UPDATE_ROADMAP`](UPDATE_ROADMAP.md)**

**`G-18`, `G-19` and `G-20` now live in [`UPDATE_ROADMAP`](UPDATE_ROADMAP.md), carrying
their original numbers.** They are not duplicated here — a number in two maps is the
failure mode the Supermap's rule 2 exists to prevent.

**Why it moved.** This section is about *Apple* — signing, notarization, Gatekeeper. What
the updater turned out to need is a product surface (a button, a notice, a refusal while a
shift runs), a release cadence, a database backup, and a fix for seeded defaults that never
upgrade. One of those five is Apple's. Keeping it here would have made this map something
other than the signing map.

**What Apple still owns, and what this map's other sections still constrain:**

| Fact | Section |
|---|---|
| The bundle an update ships **must be signed, notarized and stapled** like any other | III.E–III.H |
| **Notarization was measured at ~5½ hours** and is structural, so a release costs a working day of wall-clock | III.H |
| **Two single-arch builds, never a lipo'd ERTS** — which is why the update feed must be per-architecture | III.G |
| Apple Developer ID and minisign are **unrelated signatures**; neither satisfies the other | moved, kept in full in `UPDATE_ROADMAP` |

The BEAM-swap hazard written here has moved with the gates, and **two of its
assumptions were checked against the code on 08-16 and one of them was wrong in our
favour** — see `UPDATE_ROADMAP` F2–F4.

### III.J — Exit tests: the definition of "Apple is done"

Not "it built." These, in order, **on hardware that has never seen the repo**. CI asserts
the machine-checkable ones already; the rest are human.

**Asserted in CI today** — and walked by hand against a signed local build on
**2026-08-10** (x86_64 only; see the arch note below):

- [x] `codesign --verify --deep --strict --verbose=2` → **valid on disk, satisfies its
      Designated Requirement**
- [x] `codesign -dv --verbose=4` → `Authority=Developer ID Application: Luke Hightower
      (KD977J8NF6)` → `Developer ID Certification Authority` → `Apple Root CA`,
      `flags=0x10000(runtime)`, `Identifier=lol.busterclaw.desktop`
- [x] `spctl -a -t exec -vvv` → **`source=Notarized Developer ID`**, not merely "accepted"
      **PASSES 08-10** — reads exactly that.
      *(accepted alone is not enough: an unnotarized build is accepted locally because this
      machine signed it)*
      > **The negative control was sharper than this line anticipated.** Before
      > notarization the result was not "accepted" — it was **`rejected —
      > source=Unnotarized Developer ID`**. Gatekeeper read a genuine Developer ID
      > signature and refused it *only* for the missing ticket, then flipped to
      > `accepted / Notarized Developer ID` once stapled. Both halves were observed, so
      > this check is known to discriminate rather than merely known to pass.
- [x] `stapler validate` passes on both the `.app` and the `.dmg` — **PASSES 08-10**
      *(before notarization it correctly read `does not have a ticket stapled to it`)*
- [x] `beam.smp` carries `allow-jit` on its own signature → **confirmed**, all four
      entitlements present on `erts-16.3.1/bin/beam.smp` itself, not merely on the outer app
- [x] `lipo -archs` on `beam.smp` matches the runner's arch → **`x86_64`**, single-arch
- [x] **Every Mach-O in the bundle verifies** — 24 signed, 0 unsigned. **The map's predicted
      count was exact**: `find -perm +111` would have signed 17 and missed 7 NIFs.

**Only a human on real hardware can do these:**

- [ ] **Download the DMG over the web** so it carries `com.apple.quarantine` — copying via
      USB does not reproduce the real path — then double-click, drag, launch: **no dialog at
      all**
- [ ] **The in-app terminal opens and runs a command.** This is the test that proves
      `beam.smp` got its entitlements. Everything upstream can pass while this fails
- [ ] Launch once **with networking disabled** — proves the ticket is stapled
- [ ] **Repeat every line above on the Intel DMG on an Intel Mac**

> **The last line is not a formality.** Two architectures means every exit test runs twice,
> on two physical machines.
>
> ### The arch dependency was recorded backwards — corrected 08-10
>
> This map, and Stage 0e in the release gate, said *"identify the Intel Mac you will run
> III.J on — still owed."* **The development machine IS the Intel Mac** — an i9-9980HK —
> and every DMG ever built in this tree is `x64`. Nothing was owed.
>
> **What is owed is an Apple Silicon Mac**, and it is the worse gap of the two: the
> download page is meant to say *"Apple Silicon — most Macs since 2020"*, so the untested
> slice is the majority one. As of 08-10 the aarch64 build has **never been built outside
> CI, never signed, and never launched anywhere.**
>
> This inverts **R7** too. "Intel is a one-year shelf" is still true, but the practical
> position today is the reverse: Intel is the only slice with evidence behind it.

---


---

## The gate — Apple and the artifact

*Carved from the launch map's Part IV. `[R1]` blocks the signed build going to
a handful of known people; `[R2]` blocks the public download.*

### G-0 — Apple **[R1]** (blocks everything)

- [x] **G-1. DONE 08-01.** Enrolled in the Apple Developer Program. *This was the gate on all
      of Part III; the constraint is now doing the work, not waiting for Apple.*
- [x] **G-2. DONE 08-10.** Developer ID Application certificate created, exported, installed
      locally, and both CI secrets set. Team `KD977J8NF6`, G2 issuer, valid to 2031-08-11.
      Full account and the three traps in **III.D** — the CSR route changed (no Certificate
      Assistant on macOS 26), the Sub-CA default is wrong, and the `.p12` needs `-legacy`.
      **`HAVE_APPLE_CERT` is now `true`; no workflow edit was required, as designed.**
      > **The import was replayed locally before trusting CI**, in a throwaway keychain
      > running the workflow's own commands — `create-keychain` → `import` →
      > `find-identity -p codesigning` → `delete-keychain`. It resolved
      > `Developer ID Application: Luke Hightower (KD977J8NF6)`. **That simulation is what
      > caught the `-legacy` defect**, which would otherwise have surfaced as a CI failure
      > blaming the password. Re-run it after any change to the cert or the import step.
- [x] **G-2b. DONE 08-10.** App Store Connect API key created and all three secrets set.
      Key `SAKNAF6YLA`, Developer role. Preferred over the Apple-ID + app-specific password
      path because it is revocable and scoped, and keeps an account password out of CI.
      > **Verified by an authenticated round-trip, not by inspection.**
      > `xcrun notarytool history --key … --key-id … --issuer …` returned
      > **`No submission history`** — Apple accepted the credentials and correctly reported
      > zero submissions. **A malformed key, a wrong Key ID or a wrong Issuer ID all fail
      > this call**, so it separates "credentials are good" from every other thing that can
      > go wrong during a first notarization. Re-run it after any key rotation.
      >
      > **Two navigation traps.** The key is on **appstoreconnect.apple.com**, not
      > `developer.apple.com` where the certificate lives — different site, easily conflated
      > in the same sitting. And the **Issuer ID sits above the table, not in it**, so it
      > reads as page furniture rather than a value you need; it is the one people miss.
      >
      > **The `.p8` downloads exactly once**, and it was not on disk when the IDs were first
      > read out — worth checking before leaving the page. If it is lost, revoke and
      > regenerate; keys are free and unlimited, and the only cost is that **the Key ID
      > changes**, so all three secrets must be set together or CI fails during
      > notarization complaining about authentication rather than about a mismatch.
- [x] **G-3. DONE 08-10.** Signing pipeline run for the first time — **it worked end to
      end on the first attempt**, which was not the expected outcome; this map budgets
      rejection rounds. `build_desktop.sh` with `APPLE_SIGNING_IDENTITY` set produced a
      signed `.app` and a signed 27 MB `x64` DMG; submission
      `ea367ea2-c957-4f4a-851b-c460d9d03f3f` came back **`Accepted` / "Ready for
      distribution" with zero issues**, and both artifacts are stapled. **All eight
      machine-checkable III.J assertions pass.**
      > **The ticket is outside verification of III.F.** Apple issued **27 ticket
      > entries** — the app, the Tauri binary, `beam.smp`, and every other Mach-O
      > individually. That is Apple confirming `codesign_release.sh` found them all *by
      > content*, which no local check could establish. **`beam.smp` carries its own
      > cdhash**, so the notary specifically blessed the JIT-enabled BEAM — the likeliest
      > thing in this bundle to be refused, and it wasn't.
      > **What the first run proved beyond signing.** The staging assertion — `bin/buster_claw`
      > executable and `erts-*` present — **held against a tree 254 commits and +50k/−15k
      > lines past the last packaged build**. That guard exists because a staging regression
      > once shipped six days of empty DMGs, and until 08-10 nobody knew whether current
      > `main` still packaged at all. It does.
      >
      > **Two operational notes.** A non-interactive run auto-sets `CI=true` and skips the
      > DMG's Finder window styling — functional, not pretty; re-run from a real terminal for
      > an artifact you hand someone. And `notarytool submit --wait` outlived a 10-minute
      > agent timeout: **the submission survives the client being killed**, so recover with
      > `notarytool history` rather than resubmitting and burning a second upload.
- [ ] **G-4.** Pass every **III.J** exit test — **on both architectures, on real hardware.**

### G-5 — Prove the artifact, not the source **[R1]**

The lesson of BLOCKER-1: five green CI jobs on a tree that could not produce a working DMG.

- [x] **G-5. DONE 08-01.** **A packaged-release boot test in CI.** `scripts/
      smoke_release_boot.sh`, wired into `release-desktop.yml` between the build and the
      signature/upload steps, so a bundle that cannot boot fails the job instead of being
      signed and published. It asserts the bundle carries an executable release, an `erts-*`,
      and a `beam.smp`; boots that release exactly as `main.rs` spawns it; polls `/_health`;
      asserts the catalog; and asserts a bad token 401s.
      **Verified in both directions** — passes against a real bundle, and against a bundle
      with an empty `Resources/release` (BLOCKER-1's exact shape) it exits 1 naming the
      missing VM. Leaves no orphaned `beam.smp`.
      *It drives the release directly rather than launching the `.app`: no window server, no
      Keychain, no Chromium, no network — none of which BLOCKER-1 involved, and all of which
      a runner may lack.*
- [ ] **G-6.** **Half done.** The headless gate above is in CI. **`smoke_desktop.sh` is still
      manual** — it needs a window server, a Keychain, an installed Chromium, and the
      network, and none of that has been validated on a *hosted runner*. It passes locally
      against the packaged app (verified 08-01). Wiring it in needs one throwaway CI run to
      find out what a runner actually provides; adding it blind risks wedging every release
      on an unrelated failure.
      *Fixed along the way:* `smoke_command_surface.sh` read its token from a plaintext file
      **first**, but the shell adopts that file into the Keychain and deletes it on first
      launch — so the documented fallback could never fire and the script failed with "no API
      token" on a healthy install. It now tries env → Keychain → legacy file.
- [x] **G-7. Substantially done 08-01.** `build_desktop.sh` ran end to end and produced a
      working `.app` **and** DMG, and the resulting bundle passes both smokes.
      **Still owed:** the same run from a *clean clone* with no `_build`, no `deps`, no
      `node_modules` — the local run reused warm caches, which is exactly the difference
      that hid BLOCKER-1 on the operator's machine for six days.
- [ ] **G-8.** Assert the bundle contains no `.env`, no dev database, no PLT, no source
      maps. Fail the build on a >10% size regression.
      **Baseline measured 08-01:** `.app` **76 MB**, `.dmg` **29 MB** (well under the old
      88 MB, post-Playwright and post-PLT) · **24 Mach-O objects** in the bundled OTP tree ·
      **157 commands** in the catalog · `beam.smp` `x86_64` on this Intel machine.
      **Clean of** `.env`, dev databases, PLTs, and `.d.ts`. **Four `.map` files remain** —
      all upstream `phoenix` and `phoenix_live_view` `priv/static` maps (~1.1 MB), shipped
      because `mix release` copies each dependency's `priv/`. No app source is leaked, so
      this is a size question, not a disclosure one; the assertion should be written to
      distinguish the two rather than banning `*.map` outright.

### G-9 — First launch on a machine that has never seen it **[R1]**

*A VM snapshot you can roll back is worth an hour of setup.*

- [ ] **G-9.** **TCC:** the Desktop prompt fires when the default workspace is created, and
      **the app behaves correctly when the user clicks Don't Allow.** Untested today.
- [ ] **G-10.** First launch with **no `claude` installed** explains itself and does not crash.
- [ ] **G-11.** First launch with **no Homebrew** gives an actionable message, not "Re-check"
      with no detail.
- [ ] **G-12.** First launch **offline** opens (stapled ticket), and every network-dependent
      surface degrades with a message rather than a spinner.
- [ ] **G-13.** Keychain prompt appears once, is named intelligibly, and "Always Allow" sticks.
- [ ] **G-14.** Two launches at once → single-instance behaviour, not two BEAMs on one SQLite
      file. Force-quit mid-session → relaunch recovers; no orphaned `beam.smp`, no stale
      `epmd`, no locked database.
- [ ] **G-15.** All five onboarding steps complete; each can be backed out of and re-entered;
      quitting mid-wizard and relaunching resumes sanely.

### G-16 — The macOS floor **[R1]** *(measured 08-01 — no longer a guess)*

> ### Measured 2026-08-01 — the declared floor was wrong by three major versions
>
> `vtool -show-build` over every Mach-O in a real bundle:
>
> | `minos` | Objects |
> |---|---|
> | 11.0 | 1 — the Tauri shell |
> | **14.0** | **24 — the entire Erlang VM**, incl. `beam.smp` and `erl_child_setup` |
>
> The bundle advertised **11.0**. macOS refuses to load a Mach-O whose minimum-OS load
> command is newer than the running system, so **on macOS 11, 12, and 13 that build
> installs, passes Gatekeeper, launches the shell — and then dyld rejects the VM and
> Phoenix never starts.** A window that never becomes an app, with nothing in our
> pipeline able to notice, because every machine we build on is new enough.
>
> **The floor was never a decision.** It is inherited from whichever Erlang built the
> release, so a different build machine, a fresh asdf install, or a bumped CI runner
> image moves it silently. Correcting the number fixes one build and nothing else.

- [x] **G-16. DONE 08-01.** Floor measured, corrected to **14.0** in `tauri.conf.json`, and
      **asserted on every build** by `scripts/check_macos_floor.sh` (wired into
      `release-desktop.yml`). The check reads `LSMinimumSystemVersion` from the *built*
      bundle, takes the maximum `minos` across every Mach-O, and fails if the advertised
      floor is below it. Verified in both directions: it fails on the mis-declared bundle
      naming `erl_child_setup`, and passes once the declaration is honest.
      *Raising the floor excludes nobody — macOS 11–13 users could not run the old build
      either. It replaces a broken install with an honest refusal.*
- [x] **G-16b. DECIDED 08-22 — and the number is 15.0, not 14.0.** This item asked whether
      14.0 was the floor we wanted. The first CI build of the release answered it before
      anyone chose: `check_macos_floor.sh` failed **both** architectures of run
      `32618232509` with the same object and the same number —
      `scanned 24 Mach-O objects; highest requirement is macOS 15.0 (inet_gethost)`.
      Corrected to `15.0` in `tauri.conf.json` (`e0b7e3b`).
      > **This is the drift the box above predicted, arriving on schedule.** 14.0 was
      > measured 08-01 on the operator's Intel laptop against an asdf Erlang. CI builds
      > against `setup-beam`'s OTP 28.4.2, whose `inet_gethost` carries `minos 15.0`. The
      > number went stale the moment the release stopped being built on one machine —
      > *"inherited from whichever Erlang built the release, not chosen by us."*
      >
      > **Both architectures agree**, so this is not the arch-specific case: one shared
      > value stays correct and no runner pinning is needed.
      >
      > **Accepted rather than worked around.** The alternative is building OTP from source
      > in CI against an older `MACOSX_DEPLOYMENT_TARGET` — a source build per runner, to
      > recover an OS version the bundle *demonstrably cannot run on*. The whole content of
      > the failure is that the 14.0 claim was already false; nobody was being served by it.
      > **Buster Claw no longer supports macOS 14**, and that is now a decision rather than
      > an accident, which is what this item asked for.
      >
      > **`G-16` remains the reason this was cheap.** The floor was wrong for three weeks
      > and cost nothing, because the assertion caught it on the first build that mattered
      > instead of a stranger catching it one refund at a time.
- [ ] **G-17.** **The feature floor is a separate, unmeasured number.** 14.0 is the *hard*
      floor (dyld). WebGPU-in-WKWebView sets a higher *feature* floor, and it only matters
      if the shader fails to degrade. Test on a machine where WebGPU is unavailable and
      confirm a blank canvas with a user-visible explanation, not an error. **Verify the
      WebGPU-by-default Safari/macOS version against Apple's live docs — do not take a
      remembered version number into a download page.**
- [ ] **G-17b.** Put the confirmed floor in the **README** and the **download page**, not
      just the config. A floor the buyer discovers after downloading is not a floor.
      **The number is `15.0` as of 08-22** (`G-16b`). The public `documentation.md` says
      `10.15`, which was nine major versions stale an hour before this edit and is now ten
      — see [`WEBSITE`](../website/WEBSITE_ROADMAP.md) `G-24`. Take it from
      `tauri.conf.json`, never retyped: this number has now moved twice in three weeks.

**A wrong floor is the most expensive cheap mistake here** — it is discovered by strangers,
one refund at a time, and it was an hour's work to measure.

### G-18 — Updatable **[R2]** · **MOVED → [`UPDATE_ROADMAP`](UPDATE_ROADMAP.md)**

`G-18`, `G-19` and `G-20` are **tracked in [`UPDATE_ROADMAP`](UPDATE_ROADMAP.md)** as of
2026-08-16, with the same numbers and the same wording, alongside three new gates
(`G-42`–`G-44`) that the surface turned out to need. **Do not restate them here** — check
them off there.

They remain **`[R2]`**: a new link is an email, so the updater still does not block
Release 1.


---

## What this map does not cover

- **Updating an install that already exists** — [`UPDATE_ROADMAP`](UPDATE_ROADMAP.md)
  (`G-18`–`G-20`, `G-42`–`G-44`). It consumes a notarized bundle from this map and owns
  everything after it.
- **The website, download page, privacy policy** — [`WEBSITE_ROADMAP`](../website/WEBSITE_ROADMAP.md) (`G-21`–`G-24`).
- **Telemetry, error surface, uninstall, diagnostics, the trust claims** — [`TRUST_AND_SUPPORT_ROADMAP`](TRUST_AND_SUPPORT_ROADMAP.md) (`G-25`–`G-35`).
- **The human walkthrough, the dock, the repeatable checklist** — [`RELEASE_GATE_ROADMAP`](RELEASE_GATE_ROADMAP.md) (`G-36`–`G-41`).
- **Money and audience** — [`DISTRIBUTION_ROADMAP`](../distribution/DISTRIBUTION_ROADMAP.md).
- **Google restricted scopes and CASA** — [`GOOGLE_VERIFICATION_ROADMAP`](../integrations/GOOGLE_VERIFICATION_ROADMAP.md).

---

## The short version

*Was the launch roadmap's Part 0. It lived in the spine because the next action
has been an Apple action since enrollment cleared.*

**The code is written. Enrollment has cleared. The certificate now exists** — see III.D.
*(Written 08-01, when the certificate was still the next click. Kept because the three
numbered items below are still the honest shape of what is unproven.)*

**The one thing to do next: create the Developer ID Application certificate (G-2).** Nothing
else in Part III can start, and it is minutes of work.

Between HEAD and **Release 1** — a signed DMG in a few known hands — there are three things:

1. ~~**The certificate does not exist yet.**~~ **DONE 08-10 (III.D).** Retained because the
   reasoning still applies to the next one: Pick
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
later*. Nobody needs to be able to pay for either release to be a success. See [`DISTRIBUTION_ROADMAP`](../distribution/DISTRIBUTION_ROADMAP.md).

---
---


---

## Verified status at HEAD

*Was the launch roadmap's Part II — kept whole rather than split row-by-row, because its
value is being one dated snapshot. Four rows are owned by sibling maps and say so.*

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
| ~~**No Apple Developer membership**~~ | **Closed 08-10.** Certificate created, secrets set, `HAVE_APPLE_CERT` now **true**. See III.D |
| **Nothing has been signed, notarized, or stapled — ever** | Still true 08-10. The *credential import* is now exercised (G-2); everything downstream of it is not. See the banner in III.0 |
| **No notarization credentials** *(closed 08-10 — see G-2b)* | ~~None existed.~~ Key `SAKNAF6YLA` set and verified |
| **No updater** | Zero references to `tauri-plugin-updater` in `desktop/tauri/Cargo.toml`. No minisign key exists. **Now P0** (III.I) |
| **No telemetry, no crash reporting** *(owned by [`TRUST_AND_SUPPORT`](TRUST_AND_SUPPORT_ROADMAP.md))* | No Sentry code at all as of 08-14 — the integration that read the user's own project was removed. Nothing reports our own crashes |
| ~~`minimumSystemVersion` claims macOS 11.0~~ | **Measured and corrected 08-01 → 14.0.** It was wrong by three major versions: the bundled OTP requires 14.0 while the bundle advertised 11.0, so macOS 11–13 got a launch that dies at dyld. Now asserted on every build (**G-16**). The *feature* floor (WebGPU) is still unmeasured — **G-17** |
| **No download page, no privacy policy, no terms** *(owned by [`WEBSITE`](../website/WEBSITE_ROADMAP.md))* | busterclaw.lol serves 200 from Vercel (separate repo), but `/download`, `/privacy`, `/terms` are all **404**. The homepage leads with the runtime paragraph VI-a exists to replace |
| ~~Nothing proves the packaged app boots~~ | **Closed 08-01.** `smoke_release_boot.sh` is wired into `release-desktop.yml` ahead of signing and upload (**G-5**). The GUI-side `smoke_desktop.sh` is still manual and unvalidated on a hosted runner (**G-6**) |
| **Approval gate is a stub** *(owned by [`TRUST_AND_SUPPORT`](TRUST_AND_SUPPORT_ROADMAP.md))* | `lib/buster_claw/sentinel/pending.ex` — its own moduledoc: *"Approve/deny actions are Phase 2."* |
| **No kill-switch UI** *(owned by [`TRUST_AND_SUPPORT`](TRUST_AND_SUPPORT_ROADMAP.md))* | **Zero** occurrences of `STOP` or `kill_switch` anywhere in `lib/buster_claw_web/` |
| **Security is the last settings tab** | `settings_tabs.ex` — 8th of 8, after Get Started, Appearance, Voice, Notify, Integrations, Configuration, Cmd List |
| **Voice tab is a 58-line dead end** | `voice_live.ex` is 58 lines and tells you the control is elsewhere |
| **Phone tab is in the dock, unbuilt for a new user** | `phone_live.ex` is 1,275 lines; a new user has no number to give out |
| ~~**Bundle size unmeasured post-cleanup**~~ | **Measured 08-10: 27 MB** signed x86_64 DMG |
| **Two HIGH items, now `G-34`/`G-35`** | Walk a live signed-in checkout and confirm the payment gate fires; send `nosniff` on four pipeline-less media routes |
| **Full clone-to-DMG never run end to end** | **Half closed 08-01.** `build_desktop.sh` ran end to end locally and produced a working `.app` + DMG that passes both smokes. Never yet run from a *clean clone* — the run reused warm caches, which is the difference that hid BLOCKER-1 for six days (**G-7**) |
| **The packaged app is verified working** | **REFRESHED 08-10** — rebuilt and *signed* from current `main`, 254 commits and +50k/−15k lines after the 08-01 run. The staging assertion held; see G-3. The row below is the 08-01 evidence, kept because its round-trip claims have not been re-walked. |
| ~~**The packaged app is verified working**~~ *(08-01 evidence)* | **08-01.** `smoke_desktop.sh` PASSED against the real bundle: boots, authenticates, completes a full native-bridge round-trip (Phoenix → PubSub → LiveView → JS → Tauri invoke → POST back), renders a live page through the hidden webview, and drives a headless Chrome over CDP from inside the artifact. The Info.plist TCC strings were confirmed **present in the built bundle**, so Tauri's auto-merge works as documented |

---

---


---

## Risks

*The Apple-owned risks from the launch roadmap's Part XI. R2 lives with Google
verification, R3/R6/R8 with trust and support, R10 with the website.*

- **R1 — Everything Apple is written and unproven.** The whole pipeline is a strong prior, not
  evidence. *Mitigation:* it is guarded and self-asserting at every step, and III.J is checked
  in CI rather than trusted. Expect rejection rounds anyway; budget them.
- **R4 — The minisign key.** Leak it and anyone can push code to every install. Lose it and you
  can never update anyone again. **There is no rotation.** *Mitigation:* offline backup on the
  day it is generated, before the first signed release.
- **R5 — Unknown macOS floor.** Cheap to test, embarrassing to discover via refunds. The
  declared 11.0 is a guess. *Mitigation:* G-16, a morning's work.
- **R7 — Intel is a one-year shelf.** Rosetta's removal means the Intel DMG has a limited life,
  and every hour spent on it is spent on a shrinking audience. *Mitigation:* ship it, don't
  invest in it, and revisit when macOS 28 lands.
- **R10 — busterclaw.lol is an exotic TLD** some corporate mail filters treat badly, and it is
  baked into the bundle ID. The door is closed; this is a risk to watch, not a decision to reopen.

---

---

## Sources

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
`docs/LOCAL_TRUST.md` · `BUSTERPHONE_ROADMAP.md` ·
`TRADING_TAB_CRITICAL_REVIEW_ROADMAP.md` · `LEFTOVERS_SURFACES.md`

---


---

*The app in here is good, and the pipeline to let it out is now written. What remains is the
part no amount of code can do for you: buy the certificate, run the thing, and watch a stranger
open it on a Mac you have never touched.*
