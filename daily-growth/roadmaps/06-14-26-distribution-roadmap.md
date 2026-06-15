# BusterClaw → Distribution Roadmap

**Date:** 2026-06-14 (reworked around two delivery channels)
**Target:** macOS first. Two channels delivering the **same** `.dmg`:
- **Channel A — Developers:** `git clone` → build the `.dmg` locally. Unsigned is fine.
- **Channel B — End users:** download a **signed + notarized** `.dmg` from a website.

**Supersedes:** the packaging advice in `old-maps/06-14-26-senior-assessment-claw-landscape.md`.

---

## Locked decisions

| Decision | Choice | Consequence |
|---|---|---|
| Audience | **Public** (via Channel B) + developers (Channel A) | Channel B needs Apple signing + notarization; Channel A doesn't. |
| Key storage | **macOS Keychain** | Done (Phase F1). |
| Google connect | **Bundled OAuth app**, **deep GWS scopes** | CASA assessment required; the long external pole. |
| Recovery | **Reveal recovery key** (+ `RESTORE_SECRET_KEY` import) | Done (Phase F1). |
| Updates | **Manual re-download** (no auto-update in v1) | No updater key / signed feed / release-publishing CI required. Users grab the newest `.dmg` from the site. |
| Hosting | **GitHub Releases + a simple download page** | `.dmg` (signed) is a Release asset; a lightweight page links the latest one. Free, versioned, doubles as an update feed if we ever add auto-update. |

---

## The two channels (the key insight)

One build pipeline (`scripts/build_desktop.sh`) produces the `.dmg`. The channels differ only in **trust and delivery**:

- **Channel A** `.dmg` can be **unsigned** — the developer runs it locally and accepts Gatekeeper (right-click → Open, or strip quarantine). All they need is a clean clone-and-build and good docs.
- **Channel B** `.dmg` **must be Developer-ID signed + notarized + stapled**, or an end user literally cannot open it.

So the plan: harden the build **once** (shared), then add **docs** (A) and **signing + publishing + a page** (B).

---

## Reality check — already done (don't redo)

- **Paths** runtime-resolved; **no personal identifiers** in source; **secrets encrypted at rest** in SQLite (`Vault`/`Encrypted`).
- **Mix release, asset precompile, migration-on-boot, first-run scaffolding** all work.
- **F0 + F1 are committed** (see status below). Keychain-backed secrets + recovery are in.

---

## Critical path (external clocks — start on day 1)

1. **Google OAuth verification + CASA** (F2). Deep Gmail scopes are RESTRICTED → bundled public app needs Google's review + an annual third-party security assessment. Weeks-to-months, recurring cost. Gates **Channel B public launch** — does *not* block Channel A developers or signed private testing.
2. **Apple Developer Program enrollment** ($99/yr). Gates **Channel B signing** (B1). Identity check can take days.

Neither blocks Channel A: a developer can clone and build today.

---

## Part I — Shared foundation (both channels)

### F0 — Guardrails & versioning — ✅ DONE (`7ad5d55`)
Root `VERSION` single-sources the version (`scripts/sync_version.sh` → `tauri.conf.json` + `Cargo.toml`; `mix.exs` reads it). `BusterClaw.Application` refuses to boot a release carrying a dev/test token. `build_desktop.sh` pins `MIX_ENV=prod`.

### F1 — Keychain secrets + recovery — ✅ DONE (`d5bfdb9`)
Tauri shell sources `SECRET_KEY_BASE` + API tokens from macOS Keychain (`keyring`), migrates legacy plaintext files, adopts `RESTORE_SECRET_KEY`. `BusterClaw.Recovery` + Settings "Recovery key" reveal panel. *Keychain path is compile-verified only — verify end-to-end after signing (B1), since unsigned builds get unstable Keychain ACLs.*

### F2 — Bundled Google OAuth + PKCE — ⏳ TODO *(start verification day 1)*
Replace per-user pasted `client_id`/`client_secret` with one OAuth Desktop-app client (PKCE + loopback redirect) and a one-click "Connect Google". **Scope posture LOCKED: deep GWS, expected to grow** — request the full restricted-scope set up front so we pass CASA once, not per feature. Both channels' users need Google to work. *Eng ~3–5 days; verification is the wall-clock pole.* Interim: ship to early users under Google's "unverified" 100-user cap.

### F3 — Reproducible build-from-source — ✅ DONE *(unblocks Channel A)*
`git clone … && ./scripts/build_desktop.sh` → `.dmg` on a clean machine.
- **Fixed the clean-clone blocker:** the build never installed JS deps, so `assets.deploy` (esbuild) would die resolving `@xterm/*`. Added `npm ci` (assets) — verified clean from the tracked `assets/package-lock.json`.
- **Toolchain pinned:** `.tool-versions` (erlang 28.4.2, elixir 1.19.5-otp-28, nodejs 26.0.0); Rust + `cargo-tauri` documented in BUILD.md.
- **Preflight** added to `build_desktop.sh` — checks elixir/mix/erl/cargo/rustc/node/npm + `cargo tauri`, fails early with install hints. Syntax + logic verified.
- **Pipeline verified, artifact NOT trustworthy in this location:** `build_desktop.sh` compiled + staged current code (F1 `Recovery.beam` present in the staged release) and produced `Buster Claw_0.1.0_x64.dmg` + `.app`. **But the repo lives in iCloud Drive (`~/Desktop` synced), and iCloud evicts the multi-GB `target/` (6.4 GB) — the final bundle's `Contents/` was offloaded to a placeholder, so the app that opened was stale/empty.** Channel A is not truly verified until the project is built **outside iCloud**. ⚠️ Action: relocate the repo to a non-synced local path and rebuild there.
- ⚠️ **Arch:** the build host's Rust is `x86_64-apple-darwin`, so the `.dmg` is **Intel-only** (runs on Apple Silicon only via Rosetta). For Channel B (website) we'll want an `aarch64` or **universal** binary; decide the target arch in B1. For Channel A, each dev builds for their own toolchain.

---

## Part II — Channel A: Developer (clone & build)

### A1 — Prerequisites documented + preflight — ✅ DONE
`BUILD.md` + README quickstart list exact prereqs (versions in `.tool-versions`) and the one command. The F3 preflight enforces them at build time.

### A2 — Build docs + Gatekeeper note — ✅ DONE
`BUILD.md` documents that a self-built `.dmg` is unsigned and how to open it (right-click → Open, or `xattr -dr com.apple.quarantine "Buster Claw.app"`). No Apple account needed. Also corrected `docs/DESKTOP_PACKAGING.md` (stale post-F1: it still described a `secret_key_base` file and the wrong env vars — now reflects Keychain + the npm step).

**Channel A is effectively complete** — independent of Apple and Google. Only a full end-to-end `.dmg` build run remains to confirm (see F3 note).

---

## Part III — Channel B: Website (download signed `.dmg`)

### B1 — Signing & notarization — ⏳ TODO *(hard Gatekeeper blocker)*
Apple enrollment → Developer ID signing for `.app` + `.dmg`, hardened runtime + entitlements, `notarytool` notarize + `stapler` staple, wired into `build_desktop.sh`. Clean-machine Gatekeeper test. *This is also when F1's Keychain path gets its real end-to-end verification.*

### B2 — Release publishing to GitHub Releases — ⏳ TODO
A `scripts/release.sh` (or GitHub Actions) that: builds → signs → notarizes → computes a SHA-256 → creates a GitHub Release tagged from `VERSION` and uploads the `.dmg` + checksum. (Single source of truth on version makes the tag automatic.)

### B3 — Download page — ⏳ TODO
A simple static page (GitHub Pages or in-repo) that links the **latest** Release `.dmg`, and shows version, SHA-256, minimum macOS, and a one-line "first open" note. *(Domain still parked — page can launch on a `github.io` URL and move later.)*

### B4 — Auto-update — ❌ OUT for v1 (decision: manual re-download)
If added later: Tauri updater + a signed update feed. GitHub Releases already serves as that feed, so this is a clean future bolt-on, not a rework.

---

## Resolved decisions (since first draft)

- **Auth model:** macOS **Keychain** (no app passphrase). ✅ implemented.
- **Gmail/GWS scopes:** stay **deep** and grow; CASA accepted as recurring cost.
- **Recovery:** **reveal recovery key** (+ `RESTORE_SECRET_KEY` import). ✅ implemented.
- **Updates:** **manual re-download** — no auto-update apparatus in v1.
- **Hosting:** **GitHub Releases + simple page.**
- **Bundle identity / domain:** _still parked_ — see open questions.

---

## Sequencing

```
Day 1:   Apple enroll (B1)  +  start Google verification/CASA (F2)   ← external clocks
Shared:  F2 engineering  +  F3 reproducible build
Channel A: A1 + A2  → developers can clone & build immediately (no Apple/Google wait)
Channel B: B1 (sign+notarize) → B2 (publish to Releases) → B3 (download page)
Public:  flip Channel B to "verified" when Google verification + CASA clear
```

**Channel A is the fast win** — it depends only on shared F3 + docs, nothing external. Channel B's *engineering* is ready as soon as Apple enrollment clears; its *public* status waits on Google.

---

## Costs & external dependencies

| Item | Cost | Lead time |
|---|---|---|
| Apple Developer Program | $99 / yr | Days |
| Google OAuth verification + CASA (deep Gmail scopes) | Paid, recurring | Weeks–months |
| GitHub Releases + Pages hosting | Free | — |

---

## Open questions

1. **Bundle identity / domain** — final reverse-domain bundle ID + the domain for the Apple namespace, the Google OAuth app homepage, and the privacy-policy URL. The download page (B3) can launch on `*.github.io` and move to a custom domain later, so this no longer blocks Channel B's start — only the *public* (verified Google) milestone.
