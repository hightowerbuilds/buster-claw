# Shipping Buster Claw

**The single release document.** Apple, both architectures, the release gate, and
everything that waits behind it — one file, because the last time this was four files
they disagreed with each other and with the code.

**Rewritten 2026-08-01 · App version 0.1.0 · Status: ACTIVE — this is the live map.**

> **The target, stated once, precisely.** A stranger visits **busterclaw.lol**, downloads
> a DMG, double-clicks it, and the app opens with **no dialog of any kind** — on **Apple
> Silicon and on Intel**. That is the definition of done for this document. Everything
> here either serves that sentence or is explicitly marked as not blocking it.
>
> **What changed on 2026-08-01.** The previous revision (07-27) was written when the build
> was broken and nothing was signed. Both of those are now false. Most of the Apple
> engineering is **written and committed**; none of it has ever **run against a real
> certificate**. This rewrite exists to make that distinction the spine of the document,
> because it is now the only thing that matters.

> **Stable anchors — do not renumber.** `III.E`, `III.F`, `III.G`, and `III.J` are cited by
> name in code comments (`desktop/tauri/Entitlements.plist`, `scripts/codesign_release.sh`,
> `scripts/build_desktop.sh`, `.github/workflows/release-desktop.yml`). Renaming them
> silently breaks documentation that lives next to the thing it documents. Add sections;
> don't renumber these four.

---

## Contents

- [Part 0 — The short version](#part-0--the-short-version)
- [Part I — Locked decisions](#part-i--locked-decisions)
- [Part II — Verified status at HEAD](#part-ii--verified-status-at-head)
- [Part III — Apple: the complete acceptance path](#part-iii--apple-the-complete-acceptance-path)
- [Part IV — The release gate](#part-iv--the-release-gate)
- [Part V — The backlog](#part-v--the-backlog)
- [Part VI — Focus: the product story](#part-vi--focus-the-product-story)
- [Part VII — Money](#part-vii--money)
- [Part VIII — Google verification and CASA](#part-viii--google-verification-and-casa)
- [Part IX — Concept testing](#part-ix--concept-testing)
- [Part X — The order to do it in, and the bill](#part-x--the-order-to-do-it-in-and-the-bill)
- [Part XI — Risks](#part-xi--risks)
- [Appendix A — Sources](#appendix-a--sources)
- [Appendix B — Finding index](#appendix-b--finding-index)

---

## Part 0 — The short version

**The code is written. The certificate does not exist.**

Between HEAD and a stranger downloading a working app there are exactly four things:

1. **Nothing has ever been signed.** Not because the signing path is missing — it is
   committed, guarded, and reviewed — but because there is no Apple Developer membership.
   **$99 and one to two days of Apple's queue.** Every other Apple item on this page waits
   on this one, and it is the cheapest item here. **Start it first, today.**
2. **Nothing has ever been notarized, stapled, or opened on a machine that didn't build
   it.** The pipeline is written against Apple's documented behaviour and Livebook's
   working implementation. That is a strong prior, not evidence. It will be wrong
   somewhere; budget rejection rounds (**III.H**).
3. **There is no updater.** For a private beta this is survivable — you can email fifteen
   people a link. For a **public download it is not**: an agentic app that reads email and
   drives a browser *will* need a fix shipped fast, and "please re-download" is not a patch
   channel. The updater is a **P0 for this target and was not one for the last** (**III.I**).
4. **The download page does not exist.** busterclaw.lol is live and serving, but `/download`,
   `/privacy`, and `/terms` all return 404, and the homepage leads with the runtime
   paragraph that Part VI exists to replace.

**What is no longer in the way.** The build blocker is fixed. Entitlements are correct and
asserted. Every Mach-O in the OTP tree is signed by a script that finds them by content.
CI imports a throwaway keychain, notarizes, staples, verifies all of **III.J**, and tears
the keychain down on failure. Two native architectures, no lipo. This was "the bulk of the
week" in the previous revision and it is **done and committed**.

**Ordering principle, unchanged and still right:** start the slow clocks you don't control
on day one, do the free high-leverage work while they tick, then spend real engineering on
the things that gate the download.

**The honest estimate:** **$99** and **~2 focused weeks** gets a signed, notarized,
self-updating pair of DMGs behind a download page. The largest single unknown is not
engineering — it is how many notarization rejection rounds Apple hands back, and that
clock does not start until enrollment clears.

**Money is deliberately not on this path.** The locked decision is *free beta first, charge
later*. Nobody needs to be able to pay for the first public download to be a success. See
**Part VII**.

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

## Part IV — The release gate

**This is the ordered, checkable list that blocks a public download.** Everything here
blocks; everything that doesn't block is in Part V. If an item can't be judged pass/fail by
a person with the app in front of them, it's written wrong.

### G-0 — Apple (blocks everything)

- [ ] **G-1.** Enroll in the Apple Developer Program. **$99, ~1–2 days.** *Do this first.*
- [ ] **G-2.** Create + export the Developer ID Application certificate; back up the `.p12`
      offline; add the GitHub secrets.
- [ ] **G-3.** Run the signing pipeline for the first time. Expect rejection rounds (III.H).
- [ ] **G-4.** Pass every **III.J** exit test — **on both architectures, on real hardware.**

### G-5 — Prove the artifact, not the source

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

### G-9 — First launch on a machine that has never seen it

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

### G-16 — The macOS floor (you are currently guessing)

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

### G-18 — Updatable (III.I)

- [ ] **G-18.** `tauri-plugin-updater` wired, minisign keypair generated, **private key
      backed up offline**, `latest.json` published and **per-architecture**.
- [ ] **G-19.** The BEAM-safe update sequence implemented — `download()` → verify → stop the
      release and reap the child → `install()` → `restart()`. Never `download_and_install()`.
- [ ] **G-20.** An actual 0.1.0 → 0.1.1 update tested end to end, preserving workspace,
      settings, database, and Google connection. **Tested, not assumed.**

### G-21 — Findable and trustworthy

- [ ] **G-21.** A **download page** on busterclaw.lol offering both DMGs, with the
      architecture explained in a sentence a non-expert can act on ("Apple Silicon — most
      Macs since 2020" / "Intel"). Today: 404.
- [ ] **G-22.** A **privacy policy** and **terms**. Today: both 404. Also a hard prerequisite
      for Google OAuth verification (Part VIII).
- [ ] **G-23.** The homepage leads with the same sentence as the README and the app's first
      screen (**VI-a**). It currently leads with the runtime paragraph.
- [ ] **G-24.** The communicated macOS floor and the "you need your own Claude subscription"
      requirement are both stated **before** the download button, not after.

### G-25 — Survivable in the wild

You cannot support what you cannot see, and a public download means strangers.

- [ ] **G-25.** **Crash reporting / minimal telemetry** — consent-gated, anonymous,
      default-off. An install ID and a handful of events: app opened, feature touched,
      crash. A retention thermometer, not analytics. Without it the release is unmeasurable.
- [ ] **G-26.** **A user-facing error surface** — "something went wrong, here's what to do."
      Today the only path is a stderr log in Application Support.
- [ ] **G-27.** A documented clean uninstall: app, Application Support, Keychain items,
      WebKit cache.
- [ ] **G-28.** A one-command diagnostic bundle for support (versions, log tail, no secrets).

### G-29 — Trust claims must be true

The product is sold on auditability. Shipping to strangers with the claim unbacked is the
one reputational risk that compounds.

- [ ] **G-29.** **Build the approval gate or stop implying it exists.** `Sentinel.Pending` is
      an in-memory stub whose own moduledoc says approve/deny is Phase 2, while the README
      implies refusals are actionable. *1 day to be honest; more to build.*
- [ ] **G-30.** **A visible kill switch.** Zero `STOP`/`kill_switch` references exist in the
      web layer; the emergency brake is a file on disk the user learns about from a markdown
      doc.
- [ ] **G-31.** **Disclose `bypassPermissions`** on the first on-duty or chat run. A one-line
      disclosure converts a hidden risk into a visible feature.
- [ ] **G-32.** Move **Security** out of last place in Settings and add a refusal badge to
      the dock.
- [ ] **G-33.** Re-review the unauthenticated loopback scopes (`/browser/*`, `/ws/*`,
      `/finance/api/*`) and the plaintext recovery-key reveal. Either defend them in writing
      in `LOCAL_TRUST.md` or close them. *Documented decisions, but decisions to defend.*
- [ ] **G-34.** **`LEFTOVERS.md` HIGH #1:** walk a live signed-in checkout and confirm the
      payment gate fires. The failure mode is an agent proceeding through a real payment page.
- [ ] **G-35.** **`LEFTOVERS.md` HIGH #2:** send `nosniff` on the four pipeline-less media routes.

### G-36 — The dock must be the product, not the roadmap

A stranger judges maturity by the weakest surface they click.

- [ ] **G-36.** **Move Voice out of main navigation.** 58 lines that tell you the control is
      somewhere else.
- [ ] **G-37.** **Move Phone out of the dock or behind a labs toggle** until a new user can
      do something with it. 1,275 lines of polish; no number to give out.
- [ ] **G-38.** Decide what to do about **Trading in the dock** while its safety remediation
      is open (**R9**). Read-only today; a stranger finding an unsafe path in a financial
      surface will not care that it was labelled a prototype.

### G-39 — The repeatable release checklist

Everything above is one-time. This runs every release, forever.

- [ ] `mix precommit` green · `bun test assets/js` green
- [ ] `mix dialyzer` green · `mix sobelow --config` green
- [ ] `scripts/check_docs_drift.sh` green
- [ ] `mix test --include browser_engine` green on a machine with a browser
- [ ] Deno tests for the edge functions green
- [ ] Two-arch DMGs built, signed, notarized, stapled
- [ ] `smoke_desktop.sh` + `smoke_command_surface.sh` green against **each** packaged artifact
- [ ] III.J exit tests passed on real hardware, **both** arches
- [ ] Update from the previous release tested, not assumed
- [ ] `VERSION` bumped, changelog written, per-arch `latest.json` published
- [ ] **Minisign key backup confirmed to still exist**
- [ ] Apple Developer Program License Agreement still accepted (it stalls silently)

> **A gate that can be skipped is not a gate.** `mix precommit | tail && git push` shipped a
> red suite once. Use `set -o pipefail` on any `&&` chain that depends on a piped gate.

---

## Part V — The backlog

**Nothing here blocks the release.** It is kept in this document rather than a separate file
because the last time this work lived in its own roadmap, four documents disagreed with each
other and with the code. Promote items into Part IV when they earn it.

### V.1 — Testing gaps

The baseline is genuinely strong for a solo project: four CI jobs (`build`, `rust`, `js`,
`dialyzer`) plus the release DMG job, zero warnings, and a static ACL lockstep test that
catches a class of bug that only appears in the packaged app. The gaps are about *where the
confidence sits*, not volume.

> **Measured 2026-08-01: 2,028 tests, 0 failures, 22 excluded, 32.9s.** Up ~24% from the
> 07-27 measurement of 1,638. Green.
>
> **One thing observed and worth writing down.** An identical run launched *while a
> saturating Rust compile held the machine* produced **816 failures — every one of them at
> `Ecto.Adapters.SQL.Sandbox.start_owner!/2`, none in a test body.** Under CPU starvation the
> SQLite sandbox checkouts time out en masse. It is not a defect and the suite is not flaky
> on an idle machine, but **a loaded CI runner is the normal case, not the exception**, and
> this failure presents as 816 unrelated red tests rather than as "the machine was busy."
> If CI ever goes red that way, this is why. See **T-11**.

| # | Gap | Why it matters | Status |
|---|---|---|---|
| T-1 | No test proves the packaged app boots | BLOCKER-1 shipped through five green CI jobs | **Promoted → G-5** |
| T-2 | `:browser_engine` tests excluded by default **and in CI** | One of the largest subsystems; its tests never run automatically | Backlog — run nightly |
| T-3 | No exhaustive tier×command authorization matrix | The trust model is the differentiator; it deserves a generated test over the whole catalog | Backlog — *half a day* |
| T-4 | No end-to-end LiveView/browser tests | The Trading stale-SVG defect was invisible to server-rendered-HTML assertions | Backlog |
| T-5 | No migration test from a real 0.1.0 database | First update to a real user is the first time this runs | **Partly promoted → G-20** |
| T-6 | Smoke scripts manual, not in CI | Only checks that exercise production ACL resolution end to end | **Promoted → G-6** |
| T-7 | No soak/leak test | Always-on app, continuous render loops, long-lived LiveViews | Backlog |
| T-8 | No prompt-injection regression suite | The most likely real-world attack on an agent runtime | Backlog — **highest-value backlog item** |
| T-9 | Rust `browser/` modules thinly tested relative to size | 934-line `mod.rs`, 582-line `js.rs` | Backlog |
| T-10 | Trading Stage 6 confidence tests | Tracked in the Trading roadmap | Backlog |
| T-11 | Sandbox checkout times out under CPU starvation | Green on an idle machine; 816 sandbox-checkout failures under a saturating parallel build. Presents as mass unrelated red, not as "the runner was busy" — and a gate that goes red for unreproducible reasons teaches you to ignore red | **New 08-01** — low priority, but pin `max_cases` or raise the ownership timeout before it bites in CI |

**Principles worth keeping.** *Test at the boundary that fails* — 131 passing Trading tests
concentrated on prompt text and pure math missed a stale-DOM defect and an unsafe execution
boundary. And **every bug found in QA gets a regression test before the fix is merged**; the
QA lists are one-time discovery, the tests are what make them permanent.

### V.2 — Per-surface QA

Worth doing before a wide audience; not worth blocking the first download.

**Home** — chat send/stream/interrupt/error; a hung run is killed and reported · shader
degrades to blank canvas without an error · SVG sketchpad refuses malicious SVG (script tags,
external refs, `foreignObject`) · notify timer/alarm/reminder each fire and dismiss · journal
note survives restart.

**Terminal** — PTY survives tab switches and window resize · multiple terminals ·
close-with-busy-process confirmation · ANSI/unicode/wide-glyph rendering · large scrollback
doesn't wedge the UI · `./buster-claw` resolves inside the workspace on an installed build.

**Browser** — navigate/back/forward/reload/tabs/⌘1–9/⌘W/⌘F · tab eviction at the cap ·
popup-as-tab · download + reveal in Finder · bookmarks round-trip with folders · history dedup
and clear · agent co-presence badge fires on every agent-driven call · **SSRF guard refuses
`localhost`, `127.0.0.1`, `169.254.169.254`, an IPv6 literal, and a DNS-rebinding host** ·
Agent Mode run starts/streams/stops and survives the command call that started it.

**Workspace** — file tree lists/opens/renders markdown · drag-and-drop import · a file deleted
on disk disappears without an error · path traversal via a crafted filename is refused.

**Trading** — read-only enforcement holds; no free-form model turn can place, amend, or cancel
an order · dashboard renders with zero agent runs on open · rapid account/symbol/range
switching never shows stale data · two accounts with identical last-four fail closed.

**Phone** — inbound call → greeting → record → transcript → Library doc + `/phone` row ·
voicemail audio plays · a call while the Mac is asleep drains on wake · inbound SMS from a
trusted number creates a Dispatch item, from a stranger archives only · outbound `sms_send`
respects the kill switch and daily cap · empty states read as "nothing yet," not broken.

**Calendar / Integrations / Security / Settings / Manual** — calendar handles all-day,
multi-day, and empty months · GitHub/Sentry/Umami manual poll, good-signature webhook,
**bad-signature webhook must fail closed**, **no-configured-secret webhook must fail closed** ·
Security feed streams live, redacts secrets, paginates at 10k rows · every settings toggle
persists across restart · every Manual link resolves.

### V.3 — The agent loop

`on-duty` → claimed → work → `dispatch reply` → `done` end to end · the STOP file halts an
unattended shift within one tick · the crash-loop brake trips instead of burning tokens · the
budget cap stops the shift and records a Sentinel event · killing the agent mid-run reclaims
the orphaned item · a wall-clock timeout kills the **whole process group** (no orphaned Bash
or MCP grandchildren) · `shift/Dispatch.md` matches the database after every state change ·
two agents cannot claim the same item · a malicious dispatch item body cannot escalate the
caller's trust tier.

### V.4 — Google Workspace

Connect/disconnect/reconnect; a revoked token surfaces a clear reconnect prompt · refresh-token
expiry produces a real message, not a silent failure · Gmail sync with 0, 1, and thousands of
messages · `gmail_send` from an `agent_untrusted` caller is refused and queued · attachments,
unicode subjects, HTML-only mail · a trusted sender's mail queues, a stranger's archives ·
Calendar/Drive/Docs/Contacts each survive an empty account and a rate-limited response.

### V.5 — Security and trust

**Tier matrix, exhaustively:** every catalog command against each of `trusted` /
`agent_untrusted` / `agent` / `mcp` — **automate this (T-3)** · a `restricted` command from
`mcp` is refused, recorded, and **not executed** · operator `policy.md` rules tighten but can
never loosen a baseline protection · Sentinel redaction catches an API key, a Bearer token, an
OAuth `code` in a URL, and a card number — **by key name *and* by value shape** · a phone PIN
never appears in `security_events` in the clear · CSP holds on every page · **prompt injection:
a hostile web page, a hostile email body, and a hostile SMS body each fail to make the agent
run a gated command.**

### V.6 — Durability, performance, accessibility

**Durability** — every migration runs forward on a 0.1.0-seeded database · kill the app
mid-write with no corruption or lost dispatch item · the workspace can be moved and found ·
deleting the workspace under a running app errors rather than crash-loops · a full-disk
condition is handled · encrypted secrets survive restart and a wrong key fails closed · SQLite
WAL files are checkpointed.

**Performance** — idle CPU with a continuous render loop · battery over an hour idle · memory
after 8 hours · per-row shaders under 100+ rows · cold start to interactive · a 10k-row
Security feed and 5k-item Dispatch queue still render.

**Accessibility** — full keyboard navigation · VoiceOver reads the audit feed and chat ·
contrast passes for hazard-orange on both backgrounds · gain/loss and success/refusal never
communicated by colour alone · `prefers-reduced-motion` disables the shader.

### V.7 — Platform matrix

| | Apple Silicon | Intel |
|---|---|---|
| **Oldest supported macOS** | determine (**G-16**) | determine (**G-16**) |
| **Current macOS** | required | required |
| **Latest beta macOS** | before each release | best effort |

Also: a non-admin user account, and a non-English locale with a non-US date format.

---

## Part VI — Focus: the product story

*The cheapest high-leverage work in this document, because it is mostly deletion and
rewording. It is in Part V territory for engineering effort and Part IV territory for impact.*

### VI.1 — The core problem: no front door

Buster Claw is several products sharing one shell, and a new user cannot form a single mental
model in the first session:

| Surface | What it pitches |
|---|---|
| README | "Agent runtime + audit trail" |
| busterclaw.lol | "A desktop runtime where an AI agent manages your web interactivity" |
| Onboarding wizard | "Your assistant, reachable by email" |
| Home screen | "Chat with Claude" |
| Phone tab | "An answering machine for your agent" (mostly unbuilt) |
| Trading tab | "A portfolio dashboard" (read-only, remediation open) |

**A user cannot answer "what is Buster Claw?" after a full session — the answer changes with
the screen.** The competitor that wins the comparison is the one whose one-sentence pitch
matches its first screen.

**Two agent entry points with contradictory docs.** The terminal `on-duty` loop (durable,
queued, auditable) and the home headless chat (ephemeral, conversational) are two ways to use
the same agent, with different state and different trust presentation. The wizard routes you
to one; the default tab shows you the other. **Pick one as the front door and make the other
an advanced mode.**

### VI.2 — The worklist

| # | Task | Cost |
|---|---|---|
| **VI-a** | **Pick one front door.** Make README + busterclaw.lol + wizard welcome + home primary action say the same sentence | Hours. **Highest leverage in this document.** Blocks **G-23** |
| VI-b | Delete retired features from `user-guide/introduction.md` — Scheduler, Webhooks, Delivery, and Memory are all retired and still documented | Hours |
| VI-c | Fix `user-guide/setup.md`: it describes a 3-step wizard; the app has five steps and never asks for a name | Hours |
| VI-d | Reword the README's bold *"There is no LLM inside Buster Claw"* — technically true, practically misleading when the default tab is a chat box driving the user's Claude. The README also never mentions the home chat at all | Hours |
| VI-e | Least-privilege onboarding: Gmail read-only first, widen later | A day |
| VI-f | Seed a test dispatch item so the first run isn't an empty box | Hours |
| VI-g | Agent-orientation health check: "your agent found its workspace guide" | A day |

**The fastest way to destroy trust is to tell the user to click something that isn't there.**
VI-b and VI-c are hours of deletion and they are the difference between a documentation set
that builds confidence and one that reveals the seams.

---

## Part VII — Money

**Not on the critical path for this release.** The locked decision is *free beta first, charge
later*; nobody needs to be able to pay for the first public download to succeed. Retained here
in compressed form so it does not drift into a separate document that disagrees with this one.

**The paid tier is BusterPhone. We are the phone company.** We hold the Twilio account, we
provision the number, the user never learns Twilio exists. They pay us one bill; we pay the
wholesaler.

| Tier | What you get | Our marginal cost |
|---|---|---|
| **Free / Channel A** | Bring your own Twilio + Supabase; wire the webhook yourself | **$0** — so it's free. Same principle as BYO Claude |
| **Paid** | We are your phone company. A number, the relay, zero setup | **Real, recurring, per-user** — which is what honestly earns a recurring price |

**Why this also fixes the marketing problem.** The paid pitch is **"Buster Claw answers your
phone."** Five words. And a phone number is the one thing nobody questions paying *monthly*
for — telephony has been priced that way for a century.

**Inbound voice does not require A2P 10DLC.** That grind is an *SMS* gate.

**What must exist before anyone can pay** (none of it blocks this release): MoR checkout ·
number provisioning tied to subscription lifecycle, **releasing on cancel** or we pay forever ·
Twilio subaccount isolation · **usage caps and an abuse kill switch** (a pricing requirement,
not a nice-to-have — an abused account is unbounded minutes against a flat subscription) ·
in-app "get a number" UI · a server-side entitlement check.

**Margin, measured not guessed:** every voicemail on record costs **$0.0525**, of which
**transcription is $0.0500 — 95%.**

> **Open decision, and it shapes the price:** turn `<Record transcribe="true">` off (~one
> line; drops a voicemail to ~$0.0025), or keep Twilio transcription as COGS at ~5¢/message.
> A local-STT replacement would be a *fresh* decision — Whisper was deliberately demolished
> 06-28. **Decide before pricing anything.**

At $10–15/mo against a number (~$1–2/mo) plus usage, gross margin is roughly 80–85%.

---

## Part VIII — Google verification and CASA

**Deferred, and that is a deliberate, load-bearing choice.**

The app reads and sends Gmail — **restricted scopes** — which means three gates: OAuth brand
verification (needs a homepage **and a privacy policy at a matching domain** — see **G-22**),
restricted-scope review, and a **CASA security assessment**: an independent lab assessment,
**annual**, typically mid-hundreds to a few thousand dollars per year, recurring forever.

**Honest timeline: weeks to months.** An app whose pitch is "an AI autonomously reads and
answers your email" should expect extra scrutiny and at least one rejection round.

> **The beta-cap gotcha.** While the OAuth app is unverified ("Testing"), only **100
> explicitly listed test users** can connect — and **their refresh tokens expire every 7
> days.** Users must reconnect Google weekly until verification clears. The onboarding says
> "you'll do this once," which is **false for every early user**. Say it out loud, and fix
> the wizard copy.

**The fallback, and it is a good one:** GWS ships as *"developer preview — bring your own
OAuth app"* while the rest of the download is public. A dev can make their own OAuth client in
twenty minutes. The flagship feature dark for non-dev users is bad; **it is not a launch
blocker for the app as a whole**, and keeping this fallback alive permanently is the mitigation
for R2.

- [ ] **Decide explicitly and write the answer down:** does the *public download* need
      restricted Gmail scopes on day one? If no — and with BusterPhone as the paid tier, the
      answer is probably no — this entire part stays a background task.

> **Say this out loud.** The Google/CASA clock is slower, costlier, and riskier than
> everything Apple asks for. Apple is a week of work and $99. Google is months and possibly
> thousands per year, forever. **If both queues are starting, Google should have started
> yesterday — and Apple should not be what's blocking you.**

---

## Part IX — Concept testing

*Compressed from the 07-27 revision. Everything here can start before enrollment clears, and
the first item costs an afternoon.*

**Five falsifiable claims**, each with a way to be wrong:

| # | Hypothesis | Falsified if |
|---|---|---|
| H1 | Developers who pay for Claude want a runtime that gives it hands *plus a receipt* | Interviewees can't name a moment they wished they had an audit trail |
| H2 | **"Buster Claw answers your phone"** beats the runtime pitch | The runtime pitch converts at least as well on a landing test |
| H3 | The audit trail is the differentiator vs Open Claw / Zero Claw / Hermes | Users say "nice" and rank other features above it |
| H4 | BYO Claude is not a purchase blocker | Prospects balk at needing their own subscription |
| H5 | $10–15/mo for a managed number is acceptable | The price sits above "expensive but I'd consider it" for most of the sample |

**IX.1 — The one-sentence test (this week, free).** Show ten developers the README's first
paragraph and the home screen, **fifteen seconds each**: What does this do? Who is it for?
What would you do first? **Pass: seven of ten give the same answer to Q1, and it's the answer
you intended.** Today's likely result is a fail — that's the point, it's evidence for **VI-a**
that costs an afternoon. **Re-run after the front-door rewrite; the delta is the finding.**

**IX.2 — The landing-page test.** busterclaw.lol needs a download page anyway (**G-21**). Ship
two headline variants at the same URL: **A** = "Buster Claw answers your phone," **B** = the
runtime pitch. Measure visit → download per variant. **If neither clears ~3–5% from a warm
audience, the problem is the pitch, not the product.**

**IX.3 — Five moderated first-run sessions.** Five users finds most usability problems. Clean
Mac, signed DMG, screen recording, 45 minutes, you say nothing beyond "what are you thinking?"
Tasks: install and open · *without asking me, what is this for?* · get the agent to do one
useful thing · **find out what the agent did** · **stop the agent immediately** · find out what
the agent is **not allowed** to do. **Pass bar: 4/5 complete tasks 1, 3, 4, and 5 unaided.
Tasks 4 and 5 are the ones that matter — they are the product's claim.**

**IX.4 — The concierge test for BusterPhone.** The paid tier needs provisioning, lifecycle, and
abuse controls before it can be *sold*. **You do not need any of that to test whether people
want it.** Provision three to five numbers **by hand** in the Twilio console, run four weeks,
then say you're turning it off. **Do they ask for it back?** That question is the entire test,
and it costs five phone numbers instead of a month of provisioning code.

**IX.5 — Competitive teardown.** Install Open Claw, Zero Claw, and Hermes. Do the IX.3 tasks in
each. Write down, honestly, the three things each does better. **Confirm or kill H3 with
evidence:** does any of them have a per-command, redacted, trust-tiered audit log with refusal
queueing? If one does, the differentiation story needs rewriting *before* launch.

**Decision gates.** After IX.1: 7/10 same answer, or rewrite the story. After IX.2: >3–5%, or
change the pitch or the buyer. After IX.3: 4/5 complete the audit + kill tasks, or fix Part VI
before inviting anyone. After IX.4: they ask for the number back, or **re-open the paid-tier
question before building provisioning.**

---

## Part X — The order to do it in, and the bill

### Stage 0 — Start the clocks you don't control (today)

| # | Task | Cost |
|---|---|---|
| 0a | **Enroll in the Apple Developer Program** (individual, no D-U-N-S) | **$99/yr**, ~1–2 days. **Everything waits on this** |
| 0b | **Decide:** does the public download need restricted Gmail scopes? | Free. Determines whether CASA exists at all |
| 0c | Stand up `/privacy` + `/terms` on busterclaw.lol (**G-22**) | Hours. **Blocks 0d and Google both** |
| 0d | If yes to 0b — start Google OAuth verification | $0 for basic; weeks to months |
| 0e | **Identify the Intel Mac** you will run III.J on | Free, and it is a scheduling dependency |

### Stage 1 — Free work while Apple's queue runs (same week)

| # | Task | Cost |
|---|---|---|
| 1a | **VI-a: pick one front door**; make README, site, wizard, and home agree | Hours. Highest leverage here |
| 1b | **Run the one-sentence test** (IX.1) before and after 1a | An afternoon |
| 1c | VI-b/VI-c: delete retired features from the user guide, fix the wizard docs | Hours |
| 1d | **G-5: packaged-app boot test in CI** | Half a day. Highest-value test in the document |
| 1e | **G-6: wire the smoke scripts into the release workflow** | Hours |
| 1f | **G-7: clean clone → DMG, end to end, once** | Hours plus surprises |
| 1g | **G-16: measure the real macOS floor** | A morning |
| 1h | G-36/G-37: move Voice and Phone out of main navigation | Small diffs |

### Stage 2 — Make it openable (gated on 0a)

| # | Task | Cost |
|---|---|---|
| 2a | G-2: certificate, `.p12` backup, GitHub secrets | An hour |
| 2b | **G-3: first real signed build.** Expect rejection rounds | Hours to days |
| 2c | **G-4: III.J exit tests, both arches, real hardware** | A day, plus Intel-Mac scheduling |

*The engineering behind 2b is already written and committed. This stage is running it and
fixing what Apple objects to.*

### Stage 3 — Make it updatable (parallel with Stage 2)

| # | Task | Cost |
|---|---|---|
| 3a | G-18: updater plugin, minisign keypair, **offline key backup**, per-arch `latest.json` | Days |
| 3b | G-19: the BEAM-safe update sequence | Days — this is the subtle part |
| 3c | G-20: a real 0.1.0 → 0.1.1 update, tested | A day |

### Stage 4 — Make it survivable and honest

G-9 through G-15 (first launch on a clean machine) · G-25 through G-28 (telemetry, error
surface, uninstall, diagnostics) · G-29 through G-35 (the trust claims, both HIGH leftovers).

### Stage 5 — Make it findable

G-21 through G-24: the download page, the architecture explanation, the stated floor and Claude
requirement.

### Stage 6 — Ship, then watch

IX.3 sessions on the real signed DMG · publish · one question by email each week to whoever
shows up: *"What did you use it for this week?"* The answers are the roadmap.

### Explicitly off the critical path

- **SMS / A2P 10DLC** — code-complete, frozen on the Sole-Proprietor registration reset. Does
  not gate anything here.
- **Trading Stages 1–7** — real safety work in its own roadmap; the tab is read-only today.
  But see **G-38** and **R9**: read-only is a reason it doesn't block, not a reason to ignore it.
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
- **R9 — Trading is in the dock while its remediation is open.** A user who finds an unsafe path
  in a financial surface will not care that it was labelled a prototype. *Mitigation:* G-38 —
  decide deliberately rather than by default.
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
