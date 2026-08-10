# Apple — the complete acceptance path

**Split out of `LAUNCH_ROADMAP.md` 2026-08-09 · Status: ACTIVE. G-2 is the next action.**

> ### The one-sentence version
>
> **Sign it, notarize it, staple it, and watch it open on a Mac that has never
> seen the repo — twice, once per architecture.**

**Enrollment cleared 2026-08-01.** That was the gate on everything here, and it
is open: the constraint has moved from *waiting on Apple* to *doing the work*.

**The one thing to do next: create the Developer ID Application certificate
(G-2).** Nothing else on this page can start, and it is minutes of work.

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

> ### Written versus exercised
>
> **Nothing has ever been signed, notarized, stapled, or opened on a machine that
> did not build it.** The pipeline is written against Apple's documented
> behaviour and Livebook's working implementation. That is a strong prior, not
> evidence. It will be wrong somewhere — budget rejection rounds.

**Release 1 is this map plus a clean-machine launch.** Everything else in the
release — the website, telemetry, the trust surface — is Release 2 and lives in
its own map. See [`LAUNCH_ROADMAP`](LAUNCH_ROADMAP.md) for the spine.

---

## Part III — Apple: the complete acceptance path

*Read this once end to end before touching a certificate.*

### III.0 — Written versus exercised

The single most important distinction in this document.

| | Written & committed | Exercised against a real cert |
|---|---|---|
| Entitlements (III.E) | ✅ | ❌ |
| OTP tree signing (III.F) | ✅ | ❌ |
| Two-arch build (III.G) | ✅ | ❌ (built unsigned only) |
| Notarization + stapling (III.H) | ✅ | ❌ |
| Updater (III.I) | ❌ | ❌ |
| Exit tests (III.J) | ✅ asserted in CI | ❌ |

**Everything in the right-hand column flips on the day enrollment clears, and not before.**
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

- [ ] **Create a Developer ID Application certificate.** The only certificate we need. It
      signs the `.app` and the `.dmg`.
- [ ] **Skip the Developer ID Installer certificate.** That signs `.pkg` installers.
- [ ] **Export as `.p12` and back it up offline.** Apple limits Developer ID Application
      certificates per account (currently five). Losing the private key burns one.
- [ ] **Store as GitHub Actions secrets.** `release-desktop.yml` reads
      `secrets.APPLE_CERTIFICATE` to flip `HAVE_APPLE_CERT`, and the workflow header
      documents the full secret list. Adding them is the *only* change needed to turn CI
      from unsigned to signed — no workflow edit.
- [ ] **No provisioning profile is required** for plain Developer ID + hardened runtime.
      Worth knowing so you don't go looking for a step that doesn't exist.
- [ ] **Bundle identifier is locked:** `lol.busterclaw.desktop`. Do not change it.

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

### III.I — The updater

**Status: not started. P0 for a public download.**

This item was deferrable when the target was a private cohort. It is not now. A public
download with no patch channel means a security fix requires every user to notice, return,
and re-download.

**Two signatures, not one** — the most-missed fact about Tauri's updater:

| Signature | Protects | Verified by |
|---|---|---|
| Apple Developer ID | Gatekeeper / notarization | macOS, at every exec |
| **Minisign (Ed25519)** | Update authenticity | The updater, before it installs |

They are unrelated. Apple's certificate does not satisfy the updater; the minisign key does
not satisfy Gatekeeper. Verification cannot be turned off.

- [ ] Add `tauri-plugin-updater`, generate a minisign keypair, set
      `createUpdaterArtifacts: true`, publish a static `latest.json` on GitHub Releases.
- [ ] **Back up the minisign private key offline, before the first signed release.** Anyone
      holding it can push arbitrary code to every install. There is **no revocation**: the
      public key is compiled into every shipped binary, so a rotated key is *rejected* by
      existing installs. Dangerous to leak and dangerous to lose. See **R6**.
- [ ] **Accept full downloads.** Tauri has no delta updates on macOS, and the Sparkle bridge
      is a signing tarpit whose failures surface at notarization. Full downloads over free
      GitHub Releases bandwidth, a few times a year, is the correct trade.
- [ ] **`latest.json` must be per-architecture.** Two single-arch DMGs means the updater
      must not hand an Intel build to an arm64 install. This is a new failure mode that a
      universal build would not have had.

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
> orphaned — an orphaned `beam.smp` still holding the SQLite file makes the relaunched app
> fail in a deeply confusing way.

### III.J — Exit tests: the definition of "Apple is done"

Not "it built." These, in order, **on hardware that has never seen the repo**. CI asserts
the machine-checkable ones already; the rest are human.

**Asserted in CI today:**

- [ ] `codesign --verify --deep --strict --verbose=2` → valid on disk
- [ ] `codesign -dv --verbose=4` shows `Authority=Developer ID Application` and `runtime` in the flags
- [ ] `spctl -a -t exec -vvv` → **`source=Notarized Developer ID`**, not merely "accepted"
      *(accepted alone is not enough: an unnotarized build is accepted locally because this
      machine signed it)*
- [ ] `stapler validate` passes on both the `.app` and the `.dmg`
- [ ] `beam.smp` carries `allow-jit` on its own signature
- [ ] `lipo -archs` on `beam.smp` matches the runner's arch

**Only a human on real hardware can do these:**

- [ ] **Download the DMG over the web** so it carries `com.apple.quarantine` — copying via
      USB does not reproduce the real path — then double-click, drag, launch: **no dialog at
      all**
- [ ] **The in-app terminal opens and runs a command.** This is the test that proves
      `beam.smp` got its entitlements. Everything upstream can pass while this fails
- [ ] Launch once **with networking disabled** — proves the ticket is stapled
- [ ] **Repeat every line above on the Intel DMG on an Intel Mac**

> **The last line is not a formality.** Two architectures means every exit test runs twice,
> on two physical machines. Access to an Intel Mac is a scheduling dependency, not a
> technical one — identify the machine before enrollment clears, not after.

---


---

## The gate — Apple and the artifact

*Carved from the launch map's Part IV. `[R1]` blocks the signed build going to
a handful of known people; `[R2]` blocks the public download.*

### G-0 — Apple **[R1]** (blocks everything)

- [x] **G-1. DONE 08-01.** Enrolled in the Apple Developer Program. *This was the gate on all
      of Part III; the constraint is now doing the work, not waiting for Apple.*
- [ ] **G-2. ← THE NEXT ACTION.** Create + export the Developer ID Application certificate.
      **Pick `Developer ID Application`**, not `Developer ID Installer` (that signs `.pkg`;
      we ship `.dmg`) and not `Apple Development` (cannot be distributed).
      **Generate the CSR locally** — Keychain Access → Certificate Assistant → *Request a
      Certificate From a Certificate Authority* → Saved to disk. The private key is created
      on that Mac and never leaves it; Apple only holds the public half. Lose it and the
      certificate is dead weight and you have burned one of five.
      **Export the `.p12` with the private key selected, not the certificate alone** — the
      cert-only export imports cleanly and signs nothing.
      Then `base64 -i Certificates.p12` → `APPLE_CERTIFICATE`, plus
      `APPLE_CERTIFICATE_PASSWORD`. **Back the `.p12` and its password up offline.**
- [ ] **G-2b.** Create the **App Store Connect API key** for notarization: App Store Connect
      → Users and Access → Integrations → Team Keys. → `APPLE_API_KEY_P8` (base64),
      `APPLE_API_KEY_ID`, `APPLE_API_ISSUER_ID`.
      **The `.p8` can be downloaded exactly once.** Preferred over the Apple-ID + app-specific
      password path because it is revocable and scoped, and keeps an account password out of CI.
- [ ] **G-3.** Run the signing pipeline for the first time. Expect rejection rounds (III.H).
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
- [ ] **G-16b.** **Decide whether 14.0 is the floor we want.** It is currently an accident of
      the build toolchain, not a choice. Lowering it means building the OTP release against
      an older `MACOSX_DEPLOYMENT_TARGET` — real work for a shrinking audience, given macOS
      14 shipped Sept 2023 and Apple supports roughly three versions. **Probably accept
      14.0; just accept it deliberately.**
- [ ] **G-17.** **The feature floor is a separate, unmeasured number.** 14.0 is the *hard*
      floor (dyld). WebGPU-in-WKWebView sets a higher *feature* floor, and it only matters
      if the shader fails to degrade. Test on a machine where WebGPU is unavailable and
      confirm a blank canvas with a user-visible explanation, not an error. **Verify the
      WebGPU-by-default Safari/macOS version against Apple's live docs — do not take a
      remembered version number into a download page.**
- [ ] **G-17b.** Put the confirmed floor in the **README** and the **download page**, not
      just the config. A floor the buyer discovers after downloading is not a floor.

**A wrong floor is the most expensive cheap mistake here** — it is discovered by strangers,
one refund at a time, and it was an hour's work to measure.

### G-18 — Updatable (III.I) **[R2]**

- [ ] **G-18.** `tauri-plugin-updater` wired, minisign keypair generated, **private key
      backed up offline**, `latest.json` published and **per-architecture**.
- [ ] **G-19.** The BEAM-safe update sequence implemented — `download()` → verify → stop the
      release and reap the child → `install()` → `restart()`. Never `download_and_install()`.
- [ ] **G-20.** An actual 0.1.0 → 0.1.1 update tested end to end, preserving workspace,
      settings, database, and Google connection. **Tested, not assumed.**


---

## What this map does not cover

- **The website, download page, privacy policy** — [`WEBSITE_ROADMAP`](WEBSITE_ROADMAP.md) (`G-21`–`G-24`).
- **Telemetry, error surface, uninstall, diagnostics, the trust claims** — [`TRUST_AND_SUPPORT_ROADMAP`](TRUST_AND_SUPPORT_ROADMAP.md) (`G-25`–`G-35`).
- **The human walkthrough, the dock, the repeatable checklist** — [`RELEASE_GATE_ROADMAP`](RELEASE_GATE_ROADMAP.md) (`G-36`–`G-41`).
- **Money and audience** — [`DISTRIBUTION_ROADMAP`](DISTRIBUTION_ROADMAP.md).
- **Google restricted scopes and CASA** — [`GOOGLE_VERIFICATION_ROADMAP`](GOOGLE_VERIFICATION_ROADMAP.md).
