# Getting BusterClaw onto Apple's Storefronts

**Distribution research · Buster Claw 0.1.0**

What it would actually take to ship, to keep shipping, and to publish a paper every morning — and why the App Store is the wrong door, while the door right next to it is standing open.

> Researched 2026-07-11. Sources: developer.apple.com, App Store Review Guidelines, Apple Developer Forums, Tauri & Livebook source, live App Store listings. Findings verified against the shipped `Buster Claw_0.1.0_x64.dmg` and the buster-claw repo at HEAD. Where Apple publishes no SLA or no written rule, this document says so rather than guessing.

---

## The short version

**BusterClaw cannot ship on the Mac App Store** — not for paperwork reasons, but because its defining feature is running *your* `claude` binary from *your* `$PATH`, and Apple's sandbox has no mechanism that permits it. Ever. There is no entitlement to request.

**But the App Store was never the goal you actually want.** The thing you're really after — a Mac user downloads BusterClaw and it just opens, no scary warnings, no gymnastics — is the *Developer ID + notarization* path. Same $99, no sandbox, no review board, no 30% cut, automated approval in under an hour. Your own roadmap already picked it. It is roughly a week of real work.

**The iPhone is a real opportunity, but it isn't BusterClaw.** iOS forbids subprocesses at the kernel level. What ships — and what competitors are shipping *right now* — is a thin client that talks to BusterClaw running on your Mac.

**And there's a fire you haven't noticed:** the app is Intel-only, and Rosetta 2 dies next year.

**On shipping *version two*:** there is no updater at all today, and the obvious way to add one silently corrupts the running Erlang VM. Fixable — but only if you know before you build it.

**On the daily newspaper:** it must never travel on the update channel (that would mean pushing 88MB to every user, every day). Build it as a local feature about the user's own world — and note that a content-only reader is the *one* piece of BusterClaw that Apple's stores would actually accept.

---

## 1. What BusterClaw actually is

*Everything below follows from these five facts. The storefront question is decided here, not in Cupertino.*

Before asking what Apple allows, it's worth stating plainly what we'd be asking them to allow. Reading the shipped `Buster Claw_0.1.0_x64.dmg`:

- **It bundles an entire Erlang VM and launches it as a child process.** The `.app` contains a full OTP release — `beam.smp`, `erlc`, `epmd`, `erl_child_setup` — which the Tauri shell spawns at startup. It runs a Phoenix HTTP server on a loopback port that the webview then loads.
- **It opens a real terminal.** `portable-pty` spawns the user's `$SHELL` — arbitrary code execution, by design.
- **It executes binaries it doesn't own.** The agent runner finds `claude` (or `codex`) on the user's `$PATH` and invokes it with `--permission-mode bypassPermissions`. It also expects a user-installed `node` for the Playwright sidecar.
- **It is completely unsigned.** `codesign` reports "code object is not signed at all." Gatekeeper rejects it outright.
- **It is Intel-only.** Built on an x86_64 Mac; every one of its binaries is x86_64.

> **A number worth internalizing**
>
> The bundle contains **25 separate Mach-O objects** — 17 executables plus 8 NIF shared libraries (`crypto.so`, `sqlite3_nif.so`, `asn1rt_nif.so`…). For notarization, *every single one* must be individually signed with a hardened runtime and a secure timestamp. "Sign the app" is not a checkbox; it's a recursive pass over a tree.

---

## 2. Three doors, not one

*"Release on the App Store" collapses three very different things into one phrase.*

| Door | What it is | Verdict |
|---|---|---|
| **Mac App Store** | Sandboxed. Human review against the App Store Review Guidelines. Apple takes 15–30%. Requires `com.apple.security.app-sandbox`. | **Closed to us** |
| **Developer ID + Notarization** | Direct `.dmg` download from busterclaw.lol. **No sandbox.** No human review — an automated malware scan. No revenue cut. Hardened Runtime required. To the user, it looks and feels exactly as legitimate as an App Store app. | **The answer** |
| **Unsigned (today)** | What ships now. Since macOS Sequoia, this is materially worse than it used to be — see below. | **Untenable** |

**One $99/year membership covers all three** — Mac App Store, iOS App Store, *and* Developer ID notarization. There is no separate purchase or program. Individual enrollment needs no D-U-N-S number and typically clears in a day or two (Apple publishes no SLA). The only real cost of enrolling as an individual: your legal name, "Luke Hightower," becomes the public seller name. For a developer tool distributed outside the App Store, nobody will care.

---

## 3. Why the Mac App Store is closed

*Two of the obvious objections turn out to be false. The one that kills us is narrower — and absolute.*

It's worth being precise here, because the intuitive read ("it bundles a VM, that must be illegal") is *wrong*, and the real blocker is easy to miss.

| Trait | Ruling | Why |
|---|---|---|
| Bundles the Erlang VM, spawns it as a child process | Red herring | Allowed. Sandboxed apps *may* spawn helpers inside their own bundle, signed with your Team ID and the `com.apple.security.inherit` entitlement. This is exactly how every Electron app on the store works (bundled Node + V8, spawned helper processes). |
| BEAM's JIT compiler | Red herring | There is an entitlement for it: `com.apple.security.cs.allow-jit`. V8 uses it on the store daily. |
| Tauri as the framework | Red herring | Tauri v2 has a first-class, officially documented Mac App Store distribution guide. The framework is not the problem. |
| Reads/writes a user-chosen workspace folder | Fine | Security-scoped bookmarks handle this. Not a blocker. |
| **Executes the user's own `claude` / `node` from `$PATH`** | **Fatal** | The sandbox grants *read* and *read-write* extensions to user-selected files. **There is no execute extension.** None. And even if the exec somehow succeeded, the child inherits your sandbox — `claude` would be trapped in BusterClaw's container, unable to see the workspace or `~/.claude`. Dead on arrival, before a reviewer ever looks at it. |
| PTY running the user's `/bin/zsh` | **Fatal** | Same root cause. A terminal *UI* can ship; the user's *shell* cannot. |
| Agent runs with `--permission-mode bypassPermissions` | **Fatal** | Guideline 2.5.2, independently. And the framing makes it worse: to a reviewer, "bypass permissions" reads as a deliberate sandbox-escape vector. |

Apple's own DTS engineer, on the Developer Forums, on whether a sandboxed app can execute a binary the user points it at:

> The sandbox extension issued by the open panel is either a read extension (`com.apple.security.files.user-selected.read-only`) or a read/write extension. **Neither of these will let you execute code from that directory.**
>
> — Quinn "The Eskimo!", Apple Developer Technical Support — forums thread 683158

And Guideline 2.5.2 itself, which describes BusterClaw's headline feature almost verbatim:

> Apps should be self-contained in their bundles, and may not read or write data outside the designated container area, nor may they **download, install, or execute code which introduces or changes features or functionality of the app**, including other apps.
>
> — App Store Review Guidelines, §2.5.2

### The receipt that settles it

**Termius ships a local-terminal feature on every platform except the Mac App Store.** Their own documentation says the MAS build strips it "due to sandbox limitations" — same app, same company, feature surgically removed to get through the door. Panic's Nova, a code editor with an integrated terminal, stays off the store entirely, citing "heavy reliance on arbitrary third-party executables… prevented by sandboxing."

There is exactly one local-shell app on the Mac App Store — *rootshell* — and it proves the rule rather than breaking it: it ships its *own* bundled utilities compiled to WebAssembly, rooted in its own container. It never touches `/bin/zsh`. That's the deal Apple offers, and it isn't a deal BusterClaw can take.

> **What "make it App Store-legal" would actually mean**
>
> Bundle the agent and every binary it calls inside the `.app`. Replace the user's shell with a self-contained WASM shell. Restrict all file access to security-scoped bookmarks. Delete `bypassPermissions`. At that point you have shipped a *different product* — one whose entire reason for existing has been removed. **This is not a trade worth making.**

---

## 4. The door that's open

*Developer ID + notarization. This is the leap you actually want to take.*

Here's the thing worth sitting with: **almost everything you want from "being on the App Store," you get from notarization instead.** The user downloads a `.dmg`, double-clicks, and it opens — clean, trusted, no warnings, indistinguishable from a store app. What you *don't* get is discovery (browsing the store) and Apple's payment rails. What you don't *pay* is the sandbox, the review board, or 15–30% of revenue.

And critically — **notarization is not App Review.** Apple's own docs:

> The Apple notary service is an **automated system** that scans your software for malicious content, checks for code-signing issues, and returns the results to you quickly.
>
> — Apple, "Notarizing macOS Software Before Distribution"

No human looks at your UI, your features, or your business model. There are no guidelines to violate. Nothing about the terminal, the agent, or `bypassPermissions` is a problem on this path. Turnaround is typically under an hour — often minutes — and it fully automates in CI (`xcrun notarytool submit --wait`, then `xcrun stapler staple`).

### What it requires

- **A "Developer ID Application" certificate** — note you must be the *Account Holder* of the developer team to generate it.
- **Hardened Runtime** on every binary (`--options runtime`). Notarization fails without it, explicitly.
- **A secure timestamp** on every signature.
- **No `com.apple.security.get-task-allow`** entitlement — a hard notary failure.
- **All 25 Mach-O objects signed individually**, inside-out. Never with `--deep`.

> **Precedent — and it's better than "close"**
>
> **Livebook Desktop is a Tauri v2 app with an Elixir/OTP release in `bundle.resources`.** That is not a similar architecture to BusterClaw's — it is *the same architecture*, and the entire build is public (`livebook-dev/livebook` → `rel/app/src-tauri/`, plus `livebook-dev/elixirkit`, whose tagline is literally "Run Elixir from Rust/Tauri apps"). Every problem below is already solved there. **The correct strategy is to copy Livebook wholesale, not to invent anything.**

### The trap that will eat a day if you don't know it

**Tauri does not sign `bundle.resources`.** This is confirmed in Tauri's own bundler source: it signs frameworks, it signs sidecars (`externalBin`), it signs the main executable — and it *copies* resources without ever adding them to the sign list. Its recursive walker only descends into six hardcoded folders (`MacOS`, `Frameworks`, `Plugins`, `Helpers`, `XPCServices`, `Libraries`), and `Resources` is not one of them.

So the naïve path fails in the most misleading way possible: **the build succeeds, the app runs fine on your machine, and then notarization comes back rejected — 25 times over**, once per unsigned Erlang binary, each reading *"The binary is not signed with a valid Developer ID certificate."*

**The fix** — Livebook's, exactly — is to sign the OTP tree *as a step in `mix release`*, before Tauri ever bundles it. `ElixirKit.Release.codesign/1` is a find-every-Mach-O-and-sign-each-one pass:

```sh
files=$(find <release> -perm +111 -type f -exec sh -c 'file "$1" | grep --silent Mach-O && echo "$1"' _ {} \;)
echo "$files" | xargs -n 1 -I {} codesign --force --options runtime \
  --entitlements App.entitlements --sign "$APPLE_SIGNING_IDENTITY" --timestamp {}
```

*Source: livebook-dev/elixirkit — `lib/elixirkit/release.ex`*

> **The subtle one — worst possible failure mode**
>
> **Entitlements do not inherit across process boundaries.** `beam.smp` is spawned as a *separate process* from `Contents/Resources/` — it does *not* inherit the Tauri shell's entitlements. It must carry `allow-jit` on **its own signature**.
>
> Sign the ERTS binaries *without* passing `--entitlements` and here is what happens: **notarization passes.** The DMG ships. And then the BEAM crashes at launch on the user's machine under hardened runtime. It fails nowhere in your pipeline and everywhere in theirs. This is exactly why ElixirKit passes `--entitlements` to *every* binary, not just the app.

### The entitlements, from a shipping notarized BEAM app

This is Livebook's `App.entitlements` — battle-tested, currently in the wild:

| Entitlement | Why the BEAM needs it |
|---|---|
| `cs.allow-jit` | BEAM has had a real JIT (BeamAsm) since OTP 24; it needs W^X executable mappings. |
| `cs.allow-unsigned-executable-memory` | Required in practice alongside the above for BEAM's code allocation. |
| `cs.disable-library-validation` | **Required.** BEAM `dlopen`s NIF `.so` files — `crypto.so`, `sqlite3_nif.so`, `asn1rt_nif.so`. To the loader, a NIF is a plug-in. |
| `cs.allow-dyld-environment-variables` | OTP's launcher scripts rely on `DYLD_*`-driven dyld behavior. |

Point *both* the mix release step and `tauri.conf.json → bundle → macOS → entitlements` at one shared file. Your `portable-pty` terminal needs no additional entitlement, and on this channel you need no sandbox entitlement at all.

The good news buried in all this: **Tauri auto-notarizes.** If the `APPLE_*` env vars are present during `tauri build`, it signs → submits to the notary → staples, with no extra step. Once the ERTS tree is pre-signed, the rest is largely already wired.

### Why "just leave it unsigned" stopped being an option

The roadmap calls the current experience "right-click gymnastics." That was true once. **macOS Sequoia removed the Control-click bypass, and it's still gone in Tahoe 26.** Apple's announcement:

> In macOS Sequoia, users will **no longer be able to Control-click to override Gatekeeper** when opening software that isn't signed correctly or notarized.
>
> — Apple Developer News

What a user meets today when they double-click your unsigned DMG: a dialog saying macOS "could not verify" the app is free of malware, whose only two buttons are **"Move to Trash"** and **"Done."** To run it they must go to System Settings → Privacy & Security, find the blocked app, click "Open Anyway," and type their admin password — and that button only appears for about an hour after the failed launch. This is not friction. It is a message from the operating system that your software is malware.

---

## 5. The iPhone

*Not BusterClaw. But a real product — and the category is already contested.*

Start with the wall: **iOS apps cannot spawn child processes.** Not "shouldn't" — *cannot*. `fork()`, `exec()`, and `system()` are unavailable to sandboxed iOS apps, and no entitlement restores them. Apple DTS, plainly: *"You are correct that iOS apps are not allowed to spawn child processes."* The Erlang VM, the PTY, and the CLI execution have no iOS equivalent. There is no clever architecture that gets around this.

Nor is there a developer-tools carve-out. Guideline 4.7 — which people reach for — has been **narrowed into an enumerated whitelist**: HTML5/JS mini apps, streaming games, chatbots, plug-ins, game emulators. A coding agent is not on the list. And the apps people cite as precedent (Pythonista, a-Shell, iSH) survive on a *discretionary* reading Apple has already tried to revoke once — in 2020 Apple told iSH it violated 2.5.2 and would be pulled; they won on appeal. Pythonista hasn't shipped an update since 2023. Do not build a strategy on that ground.

> **Live enforcement, four months ago**
>
> In **March 2026, Apple pulled "Anything" from the App Store and blocked updates to Replit and Vibecode**, citing 2.5.2 — the trigger being apps that generate code and then *run* it. This is the current, active tripwire in exactly our category. **The rule to design by: never execute, interpret, or preview agent-generated code on the device.** Keep 100% of execution on the Mac. Send previews out to Safari.

### What *does* ship — and it's a crowd

The asymmetry that makes an iPhone app possible: **2.5.2 forbids executing code that changes *the app's* functionality. Code running on a remote host does neither.** Local execution is restricted; remote execution is unremarkable. That single distinction is why Blink Shell, Termius, and Prompt all live happily on the App Store.

And it's why an entire cohort of BusterClaw-shaped companion apps is **shipping today**:

| App | Architecture |
|---|---|
| Happy: Codex & Claude Code | Pairs with a CLI on your machine via QR code; end-to-end encrypted |
| Mobile IDE for Claude Code | "Send prompts to Claude Code on your Mac from your iPhone… ship code from anywhere." Paid subscription. |
| Mobile for Claude Code | Cloudflare tunnel to your Mac; file browse, git, deploy |
| Vicoa | Laptop → phone session handoff |

These are simultaneously an **existence proof** and a **warning**: the idea is approvable, and someone else is already executing on it.

### The trap: Guideline 4.2.7

This is the one that would quietly ruin the product, so it's worth understanding before a line of code is written. Guideline 4.2.7 governs **Remote Desktop Clients**, and it applies to an app that "acts as a mirror of *specific* software or services rather than a *generic* mirror of the host device." If it applies to you, clause (a) forces the app to be **LAN-only** — which annihilates the entire point (checking on your agent from anywhere), and clause (e) kills a hosted version outright.

Screens, Jump Desktop, and Blink escape 4.2.7 because they're *generic* — they'll connect to anything. An app that exists solely to mirror BusterClaw is precisely the fact pattern the rule was written for. **The escape is architectural, and it must be decided up front:**

- **Do:** speak a structured JSON/WebSocket protocol to a daemon on the Mac, and render **native iOS UI** — a task list, a diff viewer, approval prompts, streamed log output. That is a client-server app. 4.2.7 never engages.
- **Don't:** mirror the BusterClaw window as pixels or stream the PTY as a screen. That is textbook "mirror of specific software" → 4.2.7 → LAN-only → dead product.
- **Budget for:** APNs push infrastructure. iOS won't let you hold a socket open in the background, so "the agent needs your approval" *must* arrive as a push notification. This is real work and it's routinely underestimated.
- **Also budget for:** a reviewer classifying the agent chat as a "chatbot" under 4.7 — which drags in content reporting, user blocking, and an age gate.

> **The sequencing insight**
>
> The load-bearing work for an iPhone app is **not iOS work**. It's the Mac-side daemon and a well-specified remote protocol — which is platform-agnostic, useful on its own, and something BusterClaw arguably wants regardless. Build that first; the phone client then becomes a small project you can write in whatever you like. *Realistic effort for the client once the protocol exists: 3–6 weeks (Tauri, reusing the web frontend) or 4–8 weeks (native SwiftUI, better result).*

---

## 6. The fire nobody set off the alarm for

*This outranks the storefront question. It has a deadline, and the deadline is close.*

**BusterClaw is Intel-only, and Rosetta 2 is being switched off.**

- **macOS 26.4** (shipped) — already shows users a *warning* when they launch an Intel app.
- **macOS 27 "Golden Gate"** (this fall) — the *last* release with Rosetta 2. Its installer actively *removes* Rosetta; users must deliberately reinstall it.
- **macOS 28** (fall 2027) — Rosetta retained only for a narrow set of legacy games. Everything else Intel-only *simply fails to open*.

You build on an Intel i9, so you have never felt this. But essentially every Mac sold in the last five years is Apple Silicon — which means **the app is already degraded for nearly all prospective users today**, and has roughly a one-year shelf life before it stops launching for them at all.

And here is the wrinkle that makes this more than a build-flag fix: `cargo tauri build --target universal-apple-darwin` makes the *Rust shell* universal — but **the bundled Erlang VM is a separate x86_64 Mach-O sitting in `Resources/`, and Tauri does nothing to your resources.** A "universal" app with an x86_64-only BEAM inside it is just an x86_64 app with extra steps.

### Do not build a universal binary. Ship two DMGs.

The instinct is to `lipo` the Intel and ARM Erlang trees together into one universal bundle. **This is actively harmful, and it fails in a way you would probably not catch.** Apple restricts dynamic executable-memory mapping in universal binaries, so the x86_64 slice of a lipo'd ERTS cannot allocate JIT memory:

```
beam/jit/x86/beam_asm.cpp:168: pick_allocator():
Internal error: jit: Cannot allocate executable memory
```

*Source: Erlang Forums — on building a universal Erlang for macOS*

To make a universal ERTS work at all, the Intel half must be built **with the JIT disabled** — meaning you'd knowingly ship a materially slower emulator to your Intel users. There is no `configure` option for a universal OTP build, and the OpenSSL cross-arch linking is where even the author of ElixirKit got stuck.

**What Livebook does — and what you should copy verbatim:** two GitHub Actions runners, `macos-15` (Apple Silicon) and `macos-15-intel`. Each installs OTP natively, builds the release with its *own* native ERTS, signs it, and produces a single-arch DMG. No lipo, no cross-compilation. You cannot sanely cross-compile an OTP release for arm64 from your Intel Mac — so let the runners do it. It's free.

**Verdict: arm64 support is not a follow-up to shipping. It is a prerequisite for shipping.** There is no point notarizing a DMG that most Macs will refuse to run next year.

---

## 7. The bill

| Item | Cost | Notes |
|---|---|---|
| Apple Developer Program (individual) | $99 / year | Covers *all three* channels. No D-U-N-S. Clears in ~1–2 days. |
| Developer ID certificate | $0 | Included. Must be Account Holder to generate. |
| Notarization | $0 | Unlimited, automated, <1hr turnaround. |
| Apple Silicon build machine | $0 – $600+ | Free via GitHub Actions arm64 runners; or a used Mac mini. |
| Apple's revenue cut (Developer ID) | **0%** | vs. 15–30% on the App Store. |
| iPhone companion app | $0 marginal | Same $99 membership. The cost is *weeks*, not dollars. |

The financial answer is almost anticlimactic: **$99 unlocks everything discussed on this page.** The real currency is engineering time — and the good news is that the expensive-looking item (App Store compliance) is the one we're *not* buying.

---

## 8. Shipping the second version

*There is no updater. None. And the way you'd naïvely add one will corrupt the Erlang VM.*

Confirmed by reading the tree: **no `tauri-plugin-updater`, no Sparkle, no version check, no "new version available" anywhere.** This is deliberate — `DESKTOP_PACKAGING.md` calls auto-update "intentionally out of scope for v1 (users re-download the latest `.dmg`)," and the roadmap logs it as risk **R4: "a security-patch liability."** That framing is right. An agentic app that can read and act on your email *will* someday need a fix shipped fast, and "please re-download" is not a plan.

### Two signatures, not one

The most-missed fact about Tauri's updater: it uses a **completely separate signature** from Apple's, and you need both.

| Signature | What it protects | Verified by |
|---|---|---|
| Apple Developer ID | Gatekeeper / notarization | macOS, at every `exec` |
| **Minisign (Ed25519)** | Update authenticity | The updater, before it installs |

They are unrelated. Apple's certificate does not satisfy the updater; the minisign key does not satisfy Gatekeeper. Verification cannot be turned off. And **Livebook — again — already does exactly this in production**, with a static `latest.json` on GitHub Releases, both arches, at **77–78MB per update**. Your 88MB is the same problem, already solved by the closest possible precedent. Copy it.

### First — what is the 88MB, actually?

Worth measuring rather than assuming, because the answer is not "an Erlang VM." I unpacked the shipped bundle. **The Erlang VM is 4.9MB — about 5% of the app.** Here is where the other 95% went:

**What's inside `Buster Claw.app`** — 87.77 MB total, measured from the shipped 0.1.0 bundle:

| Component | MB | Share |
|---|---:|---:|
| Elixir + OTP libraries (57 deps) | 27.33 | 31.1% |
| Playwright sidecar (node_modules) | 17.02 | 19.4% |
| Rust / Tauri shell | 14.90 | 17.0% |
| Static assets (images, CSS, JS) | 11.38 | 13.0% |
| Dialyzer PLTs ← **build waste** | 8.69 | 9.9% |
| Erlang VM (ERTS) | 4.86 | 5.5% |
| BusterClaw's own code (`.beam`) | 2.50 | 2.8% |
| Release metadata + icon | 1.09 | 1.2% |
| **Total** | **87.77** | **100%** |

Two things fall out of this that are worth more than the chart itself.

> **You are shipping 8.69 MB of build artifacts to every user**
>
> `priv/plts/` contains three **Dialyzer PLT files** — including a 5.6MB `..._deps-dev.plt`. These are static-analysis caches produced by `mix dialyzer` at *build* time. They have no function whatsoever in a shipped app. That is **~10% of the download, on every install and every future update, for nothing.**
>
> Add `priv/plts` to the release's exclusions and the app gets 10% smaller before you optimise a single real thing. The Playwright sidecar (17MB of `node_modules`, shipped complete with TypeScript `.d.ts` declaration files) is the next place to look — especially since the app requires a user-installed `node` and downloads its browsers separately anyway.

**The second observation is the more sobering one:** BusterClaw's own compiled code — the actual application, everything you have written — is **2.5MB, or 2.8% of the bundle.** The other 97% is runtime, dependencies, assets, and waste. That ratio is what makes the update problem hard, and it's also what makes it solvable.

### Every update is a full 88MB download

**Tauri has no delta updates on macOS.** Not "not yet" — it's an explicit design decision ("typical Tauri apps are a few MB"), an assumption your app violates by roughly 30×. The only delta issue in the tracker is Linux/AppImage-only.

Sparkle, the veteran macOS updater, *does* do binary deltas — and the table above is precisely the argument for it. **Between two releases, most of that bundle is byte-identical**: the OTP libraries, the Erlang VM, the Playwright sidecar, and the PLTs don't change unless you bump a dependency. What actually changes is your 2.5MB of `.beam` files, some static assets, and the Rust shell. A delta could plausibly be a few megabytes instead of 88 — a 90%+ saving, and a real argument that deserves a fair hearing.

**It still isn't worth it.** The Tauri↔Sparkle bridge is a 28-star plugin whose own docs never mention deltas. Sparkle ships a framework plus two XPC services plus a helper app, each of which must be signed in a strict order without `--deep` — a notorious tarpit that surfaces its failures *at notarization*. And you would be layering that on top of the custom `bundle.resources` signing you already have to hand-roll. Worse, Sparkle's delta generator **explicitly rejects code-signing extended attributes** — on a large mixed tree of Mach-O and non-Mach-O files, which is precisely what an OTP release is. Full downloads over free GitHub Releases bandwidth, a handful of times a year, is the correct trade.

> **The BEAM gotcha — undocumented, and the reason to diverge from Livebook**
>
> Tauri's updater **renames your running `.app` out from under the live Erlang VM**, drops the new bundle at the same path, and `rm -rf`s the old one.
>
> Open file descriptors survive that (POSIX keeps the inode alive), so `beam.smp` keeps running — which is exactly what makes this dangerous. **The BEAM loads modules lazily, from absolute paths into the bundle.** After the swap, any module not yet loaded resolves against the *new* release. That's mixed-version code loading inside a live VM, and the same hazard applies to lazily `dlopen`ed NIFs.
>
> Livebook survives this only because it installs and restarts within milliseconds, with warm modules. **Don't rely on that.** Use the split API instead of `download_and_install()`: `download()` and verify first (the BEAM is still healthy, nothing has moved) → **cleanly stop the OTP release and wait for the child to actually exit** → `install()` → `app.restart()`. No live BEAM means no lazy loads and no open handles into a bundle that's being deleted. Make sure the child is *reaped*, not orphaned — an orphaned `beam.smp` still holding the SQLite file will make the relaunched app fail in a deeply confusing way.

### The key is the crown jewel

Auto-update is, by construction, a remote-code-execution channel into every machine that runs your software. **Anyone holding the minisign private key can push arbitrary code to every installed copy of BusterClaw.** And there is no revocation: the public key is compiled into every shipped binary, so a rotated key is *rejected* by existing installs — they can only be moved forward by an update signed with the old, compromised key.

Which means the key is dangerous to leak *and* dangerous to lose. Losing it permanently destroys your ability to update anyone who has already installed. **Back it up somewhere you would still have it after your laptop is stolen.** (Sparkle, for the record, supports key rotation. Tauri does not. It's the one place Sparkle is genuinely, structurally better.)

---

## 9. The daily newspaper

*Two products wear this name. Choosing between them is the whole decision.*

Start with the trap, because it's the one that connects this section to the last one: **the newspaper must never ride on the update channel.** Content shipped inside the app bundle would mean building, signing, notarizing, and pushing an **88MB download to every user, every day** — which is not merely wasteful, it's the exact shape of the thing Apple's rules forbid on reviewed channels. Code and content must travel on separate roads. Code: rare, signed, heavy, gated. Content: daily, cheap, ungated.

### What you already have (and never connected)

This feature is further along than it looks, in two disconnected halves:

- **A live publishing backend you already own.** Lobster Attack is deployed at `lobsterattack.yachts` — Supabase, a `buster_posts` table with public-read RLS, a working `GET /api/posts`, and an established agent identity (`buster@claws.dev`). Any client could poll it today.
- **A daily-content generator that's been running for weeks.** Scribe writes `mm-dd-yy-summary/*.md` — 23 days of real, readable, time-stamped prose. The HTML Designer writes `pages/*.html`.
- **And the reader primitives already exist in-app:** `/ws/file` renders Markdown → HTML, `/browser/home` server-renders a list-of-things-to-read, `/manual` is a working reader UI with sections.

What's missing is the wire between them. Notably, **BusterClaw today fetches content from no server you control** — every outbound call goes to a third party (Google, GitHub, Finnhub). There is no BusterClaw cloud, no phone-home, nothing. That's a feature, and it's worth being deliberate before giving it up.

### The fork: whose newspaper is it?

**A. The personal edition** — *Recommended.* Your agent writes *you* a paper each morning from your own world — your mail, your calendar, your repos, your stocks, your runtime. Generated on-device. No server, no publishing, no moderation, no liability. **Scribe is already most of the way there.** Works offline. Nobody else can copy it, because the moat is your data.

**B. The published edition** — *A real business.* You write one paper, centrally, for all users. Needs a content pipeline and an editorial cadence — a thing that must be fed *every day, forever.* Makes you a **publisher**: moderation, editorial liability, and a real defamation surface if a model invents a fact about a real person.

These share almost no engineering. And three *independent* forces all push toward (A):

- **Apple's brand-new guideline 4.3(b)** (June 2026): *"Don't submit apps that are indistinguishable from what's already widely available"* — with new language that such apps **may be removed** if they don't attract customers. A generic AI news digest is precisely the shape that rule was written to kill. A paper about *your own data* is differentiated by construction.
- **Guideline 1.1.6, on false information.** An LLM-written newspaper that hallucinates a fact and presents it as news is a rejection — and the guideline pre-emptively forecloses the obvious defence: *"Stating that the app is 'for entertainment purposes' won't overcome this guideline."*
- **Defamation law, which does not care about your distribution channel.** This one bites on Developer ID too. Apple's rules stop at the App Store; libel doesn't. A newspaper about the user's own inbox has no defamation surface at all.

Three unrelated lines of reasoning converging on the same design is usually a sign it's the right one.

### If you build it, what the rules actually say

**On Developer ID — nothing applies.** No review, no content guidelines, no age rating. Notarization is a malware scan; it does not read your newspaper. Everything below matters only for a possible iOS or Mac App Store client.

The code/content line is cleaner than expected. Apple's own guideline 1.2.1 uses *"articles"* as its paradigm case of *content* — a newspaper is the least ambiguous thing you could ship. The rule that follows:

> **The design rule**
>
> **Ship the edition as *data* (Markdown/JSON) with a fixed schema, rendered by code compiled into the binary.** Then there is nothing to argue about, ever.
>
> The one design to rule out now, before anyone builds it: **remote LiveView on iOS.** LiveView isn't HTML — it's a stateful protocol pushing DOM diffs *and client-side JS hooks*. A remote server that can change client behaviour arbitrarily, after review, is a precise description of what guideline 2.5.2 exists to prevent. A reviewer would very likely never catch it. That's not a reason to do it.

### Two costs that turn out to be zero

- **Hosting is free.** One ~150KB edition a day, polled with ETags: **$0/month at 100 users and $0/month at 10,000 users** on Cloudflare R2 or Pages (egress is free; you'd be at 45GB/month against a 1TB free tier). Do not architect around distribution cost — it isn't one. The real costs are the tokens to write the edition and the liability for what it says.
- **Notifications need no push infrastructure.** APNs *does* work for Developer ID Mac apps now (via an entitlement + provisioning profile) — but you don't need it. BusterClaw already runs a persistent local server. It can poll hourly, notice the ETag changed, and fire a **local** notification. No entitlement, no push server, no Tauri signing fight, no cost.

### The strategic prize hiding in here

> **Worth sitting with**
>
> A **pure content reader** — no terminal, no subprocesses, no Erlang VM, just HTTP and a renderer — has *none* of the sandbox problems that permanently closed the Mac App Store to BusterClaw. It needs one entitlement (`network.client`) and nothing else.
>
> **So the newspaper is the one piece of BusterClaw that could ship on both the Mac App Store and the iOS App Store** — as its own small, separate app, even though BusterClaw itself never can. That is a real door, and it's the only one Apple leaves open to you.
>
> *The catch:* it must be genuinely separate (the moment it bundles the VM, you're back in the trap), and it must clear guideline 4.2 "minimum functionality" — Apple rejects thin readers that are just a repackaged website. Which, once more, argues for the personal edition: a paper about your own machine is not a repackaged anything.

---

## 10. The order to do it in

*Start the slow queue first; build while it grinds.*

1. **Enroll as an individual** — *this week · ~$99 · ~48h*
   Nothing downstream can start without it. It's the only item on this page that is somebody else's queue rather than your keyboard. The roadmap already made this call — just execute it.

2. **Read Livebook's build before writing any of your own** — *half a day, saves a week*
   Same framework, same VM, same bundling problem, already solved and public: `livebook-dev/livebook` (`rel/app/src-tauri/`, `mix.exs`, `.github/workflows/release.yml`) and `livebook-dev/elixirkit`. Everything in steps 3–4 is a port, not an invention.

3. **Move the build to CI, two arches** — *before anything else technical*
   `macos-15` + `macos-15-intel` runners, each building its own native OTP release. **Do not lipo the ERTS** — it kills the JIT on the Intel slice. Two DMGs. Until this exists, everything you sign is a product with a one-year fuse.

4. **Trim the bundle** — *one line · 10% smaller*
   Exclude `priv/plts` from the release — 8.69MB of Dialyzer build artifacts currently ship to every user for no reason. Then prune the Playwright `node_modules`. Do it before you have users, because every megabyte here is paid again on every future update.

5. **Run `build_desktop.sh` end-to-end, once** — *schedule real time*
   Per the roadmap, the complete clone-to-DMG run *has never been executed*. It will surface surprises. Do this before layering signing on top, not after.

6. **Sign + notarize** — *the real work*
   Add a `codesign` step to `mix release` that signs all 25 Mach-Os individually — `--options runtime --timestamp --entitlements`, **entitlements on every binary, including `beam.smp`** — *before* Tauri bundles. Then set the `APPLE_*` env vars and let Tauri sign, notarize, and staple on its own. **Exit test:** an Apple Silicon Mac that has never seen this repo downloads the DMG and it opens clean, first try, no dialogs — and the terminal actually works, which is what proves the BEAM got its entitlements.

7. **Lock the bundle ID before a single user installs** — *one-way door*
   Still `com.hightowerbuilds.busterclaw`. Changing it after people install orphans their app data and breaks notarization continuity. The roadmap flags `lol.busterclaw.desktop` (domain is busterclaw.lol as of 07-14) — decide now, not later.

8. **Add the updater — in the same breath as signing** — *don't defer this*
   `tauri-plugin-updater`, minisign keypair (**back it up**), `createUpdaterArtifacts: true`, static `latest.json` on GitHub Releases. Copy Livebook's config. **Diverge from them in exactly one place:** use `download()` → stop the BEAM and wait for it to exit → `install()` → `restart()`, never `download_and_install()`. Do this *with* the first signed release, not after — the first version you ship to strangers is the first version you'll need to patch.

9. **The newspaper, as a local feature first** — *cheap · already half-built*
   Wire Scribe's daily minutes into a reader surface in-app (`/ws/file` and `/manual` are already the primitives). No server, no publishing, no liability. If it's good, *then* ask whether it wants to be a separate App-Store reader app — which is the one Apple door open to you.

10. **Then, and only then, consider the phone** — *separate product*
    Design the Mac-side daemon + remote protocol first — it's the load-bearing, platform-agnostic half. Native SwiftUI client, APNs for approvals, no on-device code execution, no pixel-mirroring. Competitors are live; the window is open but not indefinitely.

> **One thing to say out loud**
>
> Your roadmap's Google/CASA clock (restricted Gmail scopes, an annual paid security assessment) is **slower, costlier, and riskier than everything on this page.** Apple is a week of work and $99. Google is months and possibly thousands per year, forever. If both queues are starting, Google should have started yesterday — and Apple should not be what's blocking you.

---

## Sources

- [App Store Review Guidelines](https://developer.apple.com/app-store/review/guidelines/)
- [Apple Developer Program — Enroll](https://developer.apple.com/programs/enroll/)
- [Compare Memberships](https://developer.apple.com/support/compare-memberships/)
- [Developer ID](https://developer.apple.com/developer-id/)
- [Notarizing macOS Software Before Distribution](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)
- [Resolving Common Notarization Issues](https://developer.apple.com/documentation/security/resolving-common-notarization-issues)
- [Customizing the Notarization Workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow)
- [Protecting User Data with App Sandbox](https://developer.apple.com/documentation/security/protecting-user-data-with-app-sandbox)
- [Entitlement Key Reference — App Sandbox](https://developer.apple.com/library/archive/documentation/Miscellaneous/Reference/EntitlementKeyReference/Chapters/EnablingAppSandbox.html)
- [Apple Forums 683158 — NSTask in a sandboxed app](https://developer.apple.com/forums/thread/683158)
- [Apple Forums 747499 — iOS and fork()](https://developer.apple.com/forums/thread/747499)
- [Apple Dev News — Sequoia runtime protection](https://developer.apple.com/news/?id=saqachfa)
- [Opening an app from an unidentified developer](https://support.apple.com/guide/mac-help/open-a-mac-app-from-an-unknown-developer-mh40616/mac)
- [Alternative Browser Engines (JIT entitlements)](https://developer.apple.com/support/alternative-browser-engines/)
- [Tauri v2 — App Store distribution](https://v2.tauri.app/distribute/app-store/)
- [Tauri v2 — macOS code signing](https://v2.tauri.app/distribute/sign/macos/)
- [tauri-bundler `macos/app.rs` — proof resources go unsigned](https://github.com/tauri-apps/tauri/blob/dev/crates/tauri-bundler/src/bundle/macos/app.rs)
- [Livebook — `App.entitlements`](https://github.com/livebook-dev/livebook/blob/main/rel/app/src-tauri/App.entitlements)
- [Livebook — two-arch release workflow](https://github.com/livebook-dev/livebook/blob/main/.github/workflows/release.yml)
- [ElixirKit — `Release.codesign/1`](https://github.com/livebook-dev/elixirkit/blob/main/lib/elixirkit/release.ex)
- [Erlang Forums — why a universal ERTS breaks the JIT](https://erlangforums.com/t/is-it-possible-to-build-a-universal-binary-of-erlang-on-macos-arm-intel/975)
- [Tauri v2 — Updater plugin](https://v2.tauri.app/plugin/updater/)
- [Livebook — updater config (`latest.json`, pubkey)](https://github.com/livebook-dev/livebook/blob/main/rel/app/src-tauri/tauri.conf.json)
- [Sparkle — delta updates](https://sparkle-project.org/documentation/delta-updates/)
- ["Code Signing and Notarization: Sparkle and Tears"](https://steipete.me/posts/2025/code-signing-and-notarization-sparkle-and-tears)
- [tauri plugins#2672 — delta updates (Linux only)](https://github.com/tauri-apps/plugins-workspace/issues/2672)
- [Apple DTS — APNs *does* work for Developer ID Mac apps](https://developer.apple.com/forums/thread/74662)
- [June 2026 guidelines update — new 4.3(b) on commodity apps](https://www.macrumors.com/2026/06/09/app-store-guidelines-low-quality-apps/)
- [Cloudflare R2 pricing (free egress)](https://developers.cloudflare.com/r2/pricing/)
- [Termius docs — no local terminal on MAS](https://docs.termius.com/organize-and-connect-to-hosts/connecting-to-a-server)
- [timac — Embedding a CLI tool in a MAS app](https://blog.timac.org/2021/0516-mac-app-store-embedding-a-command-line-tool-using-paths-as-arguments/)
- [9to5Mac — Apple pulls "Anything," blocks Replit/Vibecode (Mar 2026)](https://9to5mac.com/2026/03/30/apple-steps-up-crackdown-on-vibe-coding-apps-pulls-anything-from-the-app-store/)
- [Michael Tsai — iSH and a-Shell vs. the App Store](https://mjtsai.com/blog/2020/11/09/ish-and-a-shell-vs-the-app-store/)
- [MacRumors — macOS 27 is the last with Rosetta 2](https://www.macrumors.com/2026/06/10/macos-golden-gate-last-to-support-intel-apps/)
- [AppleInsider — When macOS stops supporting Intel apps](https://appleinsider.com/articles/26/06/12/how-and-when-macos-will-finally-stop-support-for-intel-apps)
- [Eclectic Light — Gatekeeper & notarization in Sequoia](https://eclecticlight.co/2024/08/10/gatekeeper-and-notarization-in-sequoia/)
- [Happy: Codex & Claude Code (App Store)](https://apps.apple.com/us/app/happy-codex-claude-code-app/id6748571505)
- [rootshell — the one sandboxed local shell on MAS](https://apps.apple.com/us/app/rootshell-local-terminal-ssh/id6755794662)
