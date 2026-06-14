# BusterClaw → Distribution Roadmap

**Date:** 2026-06-14
**Target:** Public download (macOS first), OS-keychain key storage, bundled Google OAuth app
**Supersedes:** the packaging recommendations in `06-14-26-senior-assessment-claw-landscape.md`

---

## Decisions locked

| Decision | Choice | Consequence |
|---|---|---|
| Audience | **Public download** | Apple signing + notarization, auto-update, polished onboarding, privacy policy — all required. |
| Local auth / key | **OS keychain** | Master key (`SECRET_KEY_BASE`) + API tokens move from plaintext files into macOS Keychain. No app-unlock prompt; secrets are unreadable off the machine. |
| Google connect | **Bundled OAuth app** | One Google Cloud app we operate; users click "Connect". **Triggers Google's restricted-scope verification (Gmail) — the long pole.** |

---

## Reality check: what's already done (don't redo it)

The earlier "B+ review" and the initial framing implied lots of hardcoding. The audit says otherwise:

- **Paths** are runtime-resolved (`runtime.exs:35-71`): env var → persisted `workspace_root` file → config default. Not hardcoded.
- **No personal identifiers** in source (no emails/names). Seed templates (`jobs.ex`) never overwrite user edits.
- **Secrets already live in SQLite, encrypted at rest** — AES-256-GCM via `Vault` + `Encrypted` Ecto type (`vault.ex`, `encrypted.ex`). Google tokens, integration tokens, webhook secrets.
- **Mix release, asset precompile (`assets.deploy`), migration-on-boot, first-run scaffolding** all work (`build_desktop.sh`, `application.ex:14-15,59-62`).
- **LiveView tests exist** (12 files, `render_click`/`render_submit`/`render_hook`) — the review's "no LiveView testing" claim was wrong.

So this is **not** a de-hardcoding project. It's **packaging hardening + a deliberate key model + a bundled OAuth flow.**

---

## Critical path (start these on day 1 — they're gated by external parties)

1. **Google OAuth verification** (Phase 2). The app reads Gmail (`gmail_read`/`gmail_search`/`gmail_sync`) → `gmail.readonly`/`gmail.modify` are **RESTRICTED** scopes. A bundled, public OAuth app using restricted scopes requires Google's OAuth verification **plus an annual third-party security assessment (CASA)**. This is weeks-to-months and has recurring cost. *Nothing about "public" is real until this clears.* Begin the paperwork before writing the code.
2. **Apple Developer Program enrollment** ($99/yr, Phase 3). Identity verification can take days. Enroll now.

Everything else is engineering we control. These two are not.

---

## Phase 0 — Foundation & guardrails  *(small, do first)*

| # | Task | Files | Notes |
|---|---|---|---|
| 0.1 | Replace bundle ID `com.hightowerbuilds.busterclaw` with a real reverse-domain you own | `desktop/tauri/tauri.conf.json:5` | Must match the Apple cert and Google app branding. Pick it once, everywhere. |
| 0.2 | Single-source the version (one file → mix/tauri/Cargo) | `mix.exs:7`, `tauri.conf.json`, `Cargo.toml` | Build script reads it; stop hand-syncing three files. |
| 0.3 | Fail-closed on dev tokens in a prod build | `config/dev.exs:90,94`, `runtime.exs` | Boot-time assert: refuse to start a release if `:api_token`/`:mcp_api_token` equal the dev sentinels, or if `MIX_ENV != prod`. Closes the "built with dev config" leak. |
| 0.4 | Confirm `build_desktop.sh` pins `MIX_ENV=prod` end-to-end | `scripts/build_desktop.sh` | Audit flagged this as the main token-leak vector. |

**Effort:** ~1 day. **Blocks:** nothing depends on it but it's cheap insurance — clear it first.

**Status (2026-06-14):**
- 0.1 — **PARKED** pending domain decision ("decide later"); bundle ID left as-is, still on critical path.
- 0.2 — **DONE.** Root `VERSION` is the single source: `mix.exs` reads it via `@version`; `scripts/sync_version.sh` propagates it into `tauri.conf.json` + `Cargo.toml`; wired into `build_desktop.sh`. Verified: bump→propagate→restore + idempotent no-op.
- 0.3 — **DONE.** `BusterClaw.Application.verify_release_token_safety!/0` refuses to boot a release (`RELEASE_NAME` set) carrying any dev/test token sentinel. Inert in dev/test/correct-prod. Compiles clean under `--warnings-as-errors`.
- 0.4 — **DONE.** `build_desktop.sh` now `export MIX_ENV=prod` for the whole script (was already prefixed per-command) and runs `sync_version.sh` first.

---

## Phase 1 — OS-keychain key model  *(the "local auth + storage" deliverable, done right)*

The vault key can't live inside the DB it encrypts. Today the Tauri shell generates `SECRET_KEY_BASE` and writes it as a **plaintext file** in the app-data dir (`desktop/tauri/src/main.rs:405-422`), then injects it as an env var into the Phoenix release. We keep that injection seam and only change *where the shell gets the key*.

| # | Task | Files | Notes |
|---|---|---|---|
| 1.1 | Store/retrieve `SECRET_KEY_BASE` in macOS Keychain from the Rust shell (`keyring` or `security-framework` crate) | `desktop/tauri/src/main.rs` | Generate on first run → write to Keychain → inject as env var exactly as today. Phoenix code is untouched. |
| 1.2 | Move API token + MCP token to the same Keychain-managed path | `lib/buster_claw/api_token.ex`, `main.rs`, `config/runtime.exs` | Have the shell generate them and inject `BUSTER_CLAW_API_TOKEN`/MCP via env (the override path already exists). Centralizes *all* key material in shell+Keychain; `api_token.ex` file-write path becomes the dev-only fallback. |
| 1.3 | Upgrade migration: existing key file → Keychain, then remove the file | `main.rs` | Don't strand current installs. Read old file once, write to Keychain, delete. |
| 1.4 | Key backup/export affordance + clear loss messaging | onboarding / settings UI | Keychain loss = unrecoverable secrets (same as today, now OS-protected). Offer "reveal/export recovery key" so a reinstall isn't a wipe. |
| 1.5 | Tests for key resolution + first-run migration | `test/` | New code path; cover Keychain-present, absent, and migrate-from-file. |

**Note on "authentication":** Keychain ties secret access to the OS login — there is **no app-level password prompt**, and the LiveView UI stays open on loopback. Threat model becomes "someone at your unlocked Mac," which is acceptable for a single-user desktop app. If you later want a true app passcode, that's the "master passphrase" variant — out of scope here by your choice.

**Effort:** ~2–4 days (mostly Rust + migration + tests). **Cross-platform note:** Windows Credential Manager / Linux Secret Service are the same crate, deferred to post-v1.

---

## Phase 2 — Bundled Google OAuth (PKCE) + verification  *(external critical path — kick off now)*

Today each user pastes their own `client_id`/`client_secret` (`setup_live.ex`, `google/oauth.ex`). Replace with one app we operate.

| # | Task | Files | Notes |
|---|---|---|---|
| 2.1 | Register a Google Cloud **OAuth Desktop-app** client; embed `client_id` (public) | new config | Desktop clients use **PKCE + loopback redirect**; the "secret" isn't confidential. Drop the per-user secret requirement. |
| 2.2 | Switch the flow to PKCE + loopback redirect | `lib/buster_claw/google/oauth.ex`, `google_oauth.ex`, `GoogleOAuthController`, router | Replaces the manual web-redirect-with-pasted-creds flow. Keep "advanced / bring-your-own client" as a hidden fallback. |
| 2.3 | One-click "Connect Google" in setup + GWS | `setup_live.ex`, `gws_live.ex` | Remove the client_id/secret form from the happy path. |
| 2.4 | **Begin Google verification** — privacy policy, app homepage, scope justification, demo video | external | Required before public consent works without scary "unverified app" screens. |
| 2.5 | **Restricted-scope security assessment (CASA)** for Gmail | external | Annual, paid via an authorized assessor. *This is the gate on true public launch.* Confirm current Google requirements at start — they change. |
| 2.6 | Interim posture: ship "unverified" to early users (100-user cap) while 2.4/2.5 are in flight | — | Lets Phases 0–4 land and reach trusted users without waiting months. |

**Effort (engineering):** ~3–5 days. **Effort (verification):** weeks-to-months wall-clock, mostly waiting + recurring cost.

**Scope posture (LOCKED — deep GWS is the product thesis):** Gmail/GWS scopes stay **deep** — full read/modify/send, and the surface is *expected to grow* (Calendar, Drive, etc.) as users build more GWS power into BusterClaw. We do **not** minimize scope to dodge CASA. Instead: request the **full restricted-scope set up front** so we pass one assessment, not a new one per feature. CASA Tier 2 is therefore a non-negotiable, recurring cost of the strategy — budget it as table stakes, not a surprise.

---

## Phase 3 — Signing & notarization  *(hard Gatekeeper blocker)*

| # | Task | Files | Notes |
|---|---|---|---|
| 3.1 | Enroll Apple Developer Program | external | Day-1 item; verification latency. |
| 3.2 | Developer ID signing config (app + DMG) | `tauri.conf.json` (`bundle.macOS.signingIdentity`), `build_desktop.sh` | Currently absent — flagged MISSING. |
| 3.3 | Hardened runtime + entitlements | tauri config / entitlements plist | Required for notarization. |
| 3.4 | Notarize + staple (`notarytool` + `stapler`) in the build | `build_desktop.sh` | `bundle_dmg.sh` already supports `--notarize`; just isn't invoked. |
| 3.5 | Clean-machine Gatekeeper test | — | Verify no "unidentified developer" on a Mac that never saw the source. |

**Effort:** ~1–2 days once the Apple account exists.

---

## Phase 4 — Auto-update + release CI

| # | Task | Files | Notes |
|---|---|---|---|
| 4.1 | Tauri updater config + dedicated update-signing keypair | `tauri.conf.json`, `main.rs` | Separate from the Apple cert. |
| 4.2 | Update feed (GitHub Releases or static JSON manifest) | repo / hosting | Source of truth for "is there a newer version". |
| 4.3 | GitHub Actions: build → sign → notarize → publish DMG + update manifest | `.github/workflows/` | No CI today. Secrets: Apple cert, notary creds, updater key. |
| 4.4 | Version-bump automation from the Phase 0 single source | CI | One bump → release. |

**Effort:** ~2–3 days.

---

## Phase 5 — Public first-run & onboarding polish

| # | Task | Files | Notes |
|---|---|---|---|
| 5.1 | Clean-machine onboarding pass (no .env, no Elixir installed) | `setup_live.ex`, `require_onboarding.ex` | Verify DB create, workspace picker, migrations, CLI launcher all self-configure. |
| 5.2 | Surface data location, Keychain explanation, and the one-click Google connect | onboarding UI | Public users need to know where their data lives and that nothing leaves the machine. |
| 5.3 | Error/edge states: port conflict, Keychain access denied, OAuth cancel | `main.rs`, setup flow | Public users will hit these; today's flow assumes the happy path. |
| 5.4 | Optional: in-app API-token rotation/reveal UI | new LiveView | Now that tokens are Keychain-managed, give a way to rotate. |

**Effort:** ~2–3 days.

---

## Phase 6 — Test & hardening gaps

- Add coverage for: Keychain key path + file→Keychain migration (1.5), OAuth PKCE flow (2.2), prod-token guardrail (0.3), first-run on clean machine (5.1).
- LiveView coverage is already decent — don't over-invest there (correcting the prior review).
- **Deferred to post-v1:** Windows/Linux builds, their keychains, and their signing stories. Note the cap explicitly so "macOS public" isn't mistaken for "cross-platform public."

---

## Sequencing

```
Day 1:  Enroll Apple (3.1)  +  Start Google verification paperwork (2.4/2.5)   ← external clocks start
Week 1: Phase 0 (guardrails)  →  Phase 1 (keychain)
Week 2: Phase 2 engineering (PKCE/one-click)  →  Phase 3 (signing, once Apple clears)
Week 3: Phase 4 (updater + CI)  →  Phase 5 (onboarding polish)
Ongoing: Phase 2 verification finishes on Google's timeline → flip from "unverified/early users" to "public"
```

Ship to **trusted early users** (unverified Google app, signed+notarized build) at end of Week 3. Flip to **true public** when Google verification + CASA clear.

---

## Costs & external dependencies

| Item | Cost | Lead time |
|---|---|---|
| Apple Developer Program | $99 / yr | Days (identity check) |
| Google OAuth verification | Free, but heavy paperwork | Weeks |
| Google CASA assessment (restricted Gmail scopes) | Paid (authorized assessor; recurring annual) | Weeks–months |
| Update hosting | ~Free (GitHub Releases) | — |

---

## Resolved decisions (since first draft)

- **Auth model:** macOS **Keychain** confirmed as the effective + simple path — Secure-Enclave-backed on Apple Silicon, zero unlock prompts, and the right vault for deep-GWS refresh tokens. No app-level passphrase.
- **Gmail/GWS scopes:** stay **deep** and are expected to expand (the product thesis). CASA accepted as recurring cost; verify the full restricted-scope set up front. (See Phase 2 "Scope posture".)
- **Recovery:** **reveal recovery key** (1.4) is sufficient — no full vault backup/restore in v1.

## Open questions

1. **Bundle identity / domain:** final reverse-domain bundle ID + the domain that triples as (a) the Apple namespace, (b) the Google OAuth app homepage, and (c) the privacy-policy URL. Gating for Phases 0.1, 2, and 3 — being resolved now.
