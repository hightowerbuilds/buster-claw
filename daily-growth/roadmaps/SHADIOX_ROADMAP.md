# Shadiox Roadmap

**Your avatar is a shader you wrote with an agent, and it renders live on notesthatfloat.com**

> Scoped 2026-07-22 against the shipped WGSL background system
> (`BusterClaw.Shaders`, `assets/js/smoke/`, `GET /shaders/:name`), the Home chat
> pipeline (`BusterClaw.Agent.Chat`), and notesthatfloat.com as a JS app on a
> Vercel-class host.
>
> Decisions locked at scoping time:
> - **notesthatfloat.com is a separate JS app.** Two codebases, one visual contract.
> - **The model runs on the user's Mac** — the installed Claude/Codex CLI, via the
>   existing `AgentRunner`. Zero inference cost to us, no stored provider creds.
> - **Accounts live on NTF, from day one.** Web signup is real; the desktop links
>   into an existing account rather than owning identity.
> - **The avatar is a profile identity.** One shader per person, square, small.

---

## Outcome

A **Shadiox** subtab on the Home page, alongside Notes / Chat / Calendar. In it:

1. You sign into your notesthatfloat.com account (device-code link, system browser).
2. A live preview shows your shader avatar at true avatar size, circle-masked.
3. A queued agent turn — Claude by default, Codex if selected — writes WGSL
   against a fixed avatar contract until you like it.
4. **Publish** ships the source plus a rendered still and a short loop to NTF.
5. notesthatfloat.com renders it wherever your name appears.

## The one hard constraint

**The preview and the website must be the same renderer, byte for byte.**

Everything else in this document is ordinary work. This is the part that decides
whether Shadiox is a product or a demo. If the desktop preview and NTF drift —
different prelude revision, different uniform packing, different post pass — then
"preview" is a lie, and every user discovers it publicly, on their own profile.

The rest of the architecture follows from taking that seriously:

- The prelude, uniform packer, and post pass become **one versioned artifact**
  consumed by both codebases. Not a copy. Not a port.
- Every published shader **stamps the runtime version it was authored against**.
  NTF renders it with that version or refuses to render it at all.
- Parity is proven by a **golden-image test that runs in both repos**, not by
  looking at it.

## System map

| Concern | Owner | Notes |
|---|---|---|
| Identity, accounts, sessions | **NTF** | Web signup is the source of truth |
| Shader storage + public read | **NTF** | Source, still, loop, palette, runtime version |
| Server-side validation | **NTF** | Re-validated on ingest; the client is never trusted |
| Public rendering | **NTF** | Still by default, live as an enhancement |
| The authoring agent | **Buster Claw** | Existing CLI, existing chat queue |
| Live preview | **Buster Claw** | `ShaderPreview` hook, avatar variant |
| Capture (still + loop) | **Buster Claw** | Rendered locally at publish time |
| The shared renderer | **Both**, via a versioned package | Phase 0 |

## Product contract

| Situation | Required behavior |
|---|---|
| Not signed in | Tab renders, preview works against a local draft, Publish is disabled with a Sign in affordance. |
| Signed in, no avatar yet | Preview shows the default/fallback avatar; the agent starts from a blank contract. |
| Agent writes invalid WGSL | Compile error surfaces in the tab; the last-good pipeline keeps rendering. Never a black square. |
| Publish while a turn is running | Publish is disabled until the turn completes. No publishing a half-written file. |
| Publish succeeds | NTF has source + still + loop + runtime version. The site updates without a redeploy. |
| Publish fails validation server-side | Specific reason returned and shown; the local draft is untouched. |
| Viewer's browser has no WebGPU | Still image. Not a blank space, not an error. |
| Viewer has `prefers-reduced-motion` | Still image, always, regardless of WebGPU. |
| Shader hangs a viewer's GPU | Frame is isolated; the host page survives; the avatar demotes to its still. |
| Web-only user, no desktop app | Can hold an account and an avatar, and can view. **Cannot author in V1.** |
| Token revoked on the web | Next publish fails with a re-link prompt. No silent retry loop. |

**The V1 gap, stated plainly:** authoring requires the desktop app, because the
model runs on the user's Mac. Web accounts exist from day one, but a web-only
user's authoring path is empty until either the hand-written WGSL editor (V1.5)
or a hosted builder (deferred) ships. Do not ship marketing copy implying
otherwise.

---

## Phase 0 — Extract the renderer, prove parity

Nothing else starts until this is done, because everything else inherits its
correctness from it.

**Extract** `@notesthatfloat/shadiox-runtime` from `assets/js/smoke/`:

- `prelude.wgsl.js` → `WGSL_PRELUDE` (the `struct U` / binding contract)
- `params.js` → `packUniforms`, `UNIFORM_FLOATS`, `DEFAULT_COLORS`, `POST_DEFAULT`
- `palettes.js` → the palette tables
- `smoke.js` → `createSmoke`, `SmokeGpuError`

Buster Claw's `assets/` consumes the package instead of its local copies. NTF
consumes the same package at the same pinned version. `assets/package.json`
currently carries only xterm; adding one dependency is cheap.

**Version it properly.** `RUNTIME_VERSION` is exported from the package and
compiled into every publish. NTF keeps the last N majors renderable. A shader
authored against v1 renders with v1 forever, or is explicitly migrated — never
silently reinterpreted.

**Golden-image test, in both repos.** Fixed WGSL + fixed uniforms + fixed seed →
render offscreen at 256×256 → compare hash against a committed PNG. Runs in
Buster Claw CI (which already has JS gates) and in NTF CI. When they disagree,
one of them is lying to a user; fail the build.

**Deliberately excluded from the avatar contract:** the expression uniforms
(`NEUTRAL_EXPRESSION`, `easeExpression`) belong to the phone contact shaderface
system and its chat-state coupling. Avatars do not get them. Faces and avatars
share a prelude, not a semantics.

## Phase 1 — The avatar contract

This is what "build shaders in the appropriate size" means concretely, and it is
what the agent gets told.

- **Square. Aspect is always 1.0.** Never letterboxed, never cropped from a
  16:9 background.
- **Circle-safe.** The site masks avatars to a circle. Corners get clipped;
  anything load-bearing in a corner is a bug. Composition lives in the inscribed
  circle.
- **Small.** 128 CSS px logical, up to 256 device px at DPR 2. A shader that only
  reads at 1440p is the single most likely failure mode and the contract must say
  so: legible silhouette, low spatial frequency, no fine detail.
- **Uniforms:** `uv` in [0,1]², `time` in seconds, the 3-color palette
  (`colA`/`colB`/`colC`), post params. **No mouse. No content texture. No
  expression.**
- **Loopable.** The capture is a short seamless loop; the shader should read well
  over a few seconds and not depend on a long-running accumulation.
- **Entry point** `fs_main`, consistent with `BusterClaw.Shaders`.

Write this once, as the reference the agent is handed and the doc a human author
reads. It supersedes nothing — the existing background/face contract stays as is.

**Naming.** `BusterClaw.Shaders` already splits backgrounds from faces on a
dash-separated-word rule (`face?/1`). Avatars need their own word so they don't
leak into the homepage background picker or the phone contact face picker.
Extend the same rule rather than inventing a second mechanism.

## Phase 2 — NTF: accounts, ingest, serve

- **Accounts.** Whatever the host makes cheap (NextAuth / Clerk / Supabase Auth).
  Passkeys or OAuth preferred; the desktop never sees a password.
- **`shaders` table:** `user_id`, `wgsl`, `runtime_version`, `still_url`,
  `loop_url`, `palette`, `status` (`live` | `quarantined`), timestamps.
- **`POST /api/shaders`** — bearer token, scope `shader:publish`.
- **Server-side re-validation on ingest. Non-negotiable.** The desktop is a
  client, and a client is an attacker. Re-check: size cap (mirror the existing
  64KB), `fs_main` present, static loop-bound scan, no unbounded `while`, no
  bindings beyond the prelude's. A client-side check is a UX affordance; this is
  the actual gate.
- **`GET /api/u/:handle/avatar`** → source + still + loop + runtime version.
- Assets on the host's blob storage. Source is a few KB; the still and loop
  dominate, and both are small.

## Phase 3 — Desktop: linking and the client

- **OAuth 2.0 Device Authorization Grant (RFC 8628)** — the `gh auth login`
  shape. The tab shows a user code, opens **the system browser** to
  `notesthatfloat.com/link`, polls the token endpoint. Never render a login form
  inside the app webview: it trains users to type credentials into a native
  window, and it breaks passkeys outright.
- Token → **macOS Keychain**, alongside the keys already scoped in
  `DISTRIBUTION_ROADMAP.md`. Never the workspace, never plaintext settings.
- **Scope `shader:publish` only.** The desktop app has no business holding a
  token that can change an email or delete an account.
- New module `BusterClaw.Shadiox` — link state, token custody, publish call,
  last-publish result. Follows `BusterClaw.Shaders`' file-first habits for the
  local draft: the draft is a real `.wgsl` file in the workspace, diffable and
  agent-editable.

## Phase 4 — The Shadiox tab

- Subtab in `StatusLive` next to Notes / Chat / Calendar, as its own component
  (`shadiox_component.ex`) in the pattern of `notes_component.ex`.
- **Preview:** the existing `ShaderPreview` hook with an avatar variant — square,
  circle-masked, live palette inputs, the same `data-preview="unavailable:…"`
  failure reporting it already does.
- **The queue is the existing queue.** A Shadiox-scoped conversation on
  `Agent.Chat` / `ChatSupervisor`, reusing the `chat_queue` machinery already in
  `status_live.ex`. It is preloaded with the Phase 1 contract and constrained to
  write one file. This is not a new agent runtime.
- **Provider choice rides `HOME_CHAT_AGENT_SELECTION_ROADMAP.md`** — Claude
  default, Codex alternative. That roadmap is a hard dependency for the
  "ie claude, codex" half of this feature; Shadiox should not grow its own
  provider seam.
- **Publish button:** compile-check → render offscreen at 256×256 → capture still
  PNG + ~3s seamless loop → `POST` → show the live URL.

## Phase 5 — NTF rendering: still first, live second

The instinct is to render every avatar live. Don't — and the reason is that one
decision solves three problems at once.

**Serve the still by default. Go live only for the focused/hero avatar.**

- **Browser coverage.** WebGPU on the open web is thinner than in your own Tauri
  build. Safari and Firefox users see the avatar anyway.
- **Density.** A feed with 60 avatars cannot be 60 WebGPU pipelines. It can
  trivially be 60 images.
- **Blast radius.** A hostile shader that never executes on a viewer's GPU cannot
  hang it.

Live rendering becomes an enhancement, which is exactly the right risk posture
for stranger-authored GPU code.

When it does go live:

- Run it in a **cross-origin sandboxed iframe** (a separate origin, not just the
  `sandbox` attribute) so a lost device kills the frame, not the page.
- Handle `device.lost` → swap to the still, report it.
- Frame-time watchdog → demote on sustained misses.
- `prefers-reduced-motion` → still, unconditionally.
- Intersection observer → nothing renders offscreen.

## Phase 6 — Safety and moderation

- **Static WGSL scan** at publish and at ingest (Phase 2 gate).
- **Flash detection at capture time.** Compute max frame-to-frame luminance delta
  over the captured loop; above threshold, mark motion-restricted and serve the
  still. A public gallery of stranger shaders will eventually contain a strobe,
  and photosensitive epilepsy is the one failure here that hurts a person rather
  than a page.
- **Report → quarantine.** `status = quarantined` stops serving source; the still
  can survive or not, by policy.
- **Rate limits** on publish, per account.

The security posture changed the moment shaders came from strangers, and one
existing doc comment has to change with it: `lib/buster_claw/shaders.ex:19`
currently reasons that an author "can never force a pattern onto the screen"
because the operator picks it in Settings. That is true for workspace shaders and
false for a public avatar feed. Fix the comment when Shadiox lands, so nobody
later reads it as a guarantee that still holds.

---

## Files expected to change

**New**
- `shadiox-runtime/` (extracted package, published to npm)
- `lib/buster_claw/shadiox.ex` — link state, token custody, publish
- `lib/buster_claw_web/live/shadiox_component.ex` — the tab
- `assets/js/hooks/avatar_preview.js` — or an avatar mode on `shader_preview.js`
- `test/buster_claw/shadiox_test.exs`
- golden-image fixtures, both repos
- the avatar contract doc (agent-facing + human-facing)

**Existing**
- `assets/js/smoke/*` — becomes a thin consumer of the package
- `assets/package.json` — add the runtime dependency
- `lib/buster_claw_web/live/status_live.ex` — mount the subtab
- `lib/buster_claw/shaders.ex` — avatar naming class; fix the safety comment
- `lib/buster_claw/settings/*` — link state persistence

**NTF (separate repo)** — auth, `shaders` table, publish + read APIs, ingest
validation, the sandboxed render frame, still/loop serving.

## Acceptance criteria

1. The same WGSL renders to the same PNG hash in Buster Claw CI and NTF CI.
2. A shader authored against runtime v1 still renders correctly after the runtime
   ships v2.
3. Publishing from the desktop updates a live profile with no redeploy.
4. An avatar renders on a browser with WebGPU disabled.
5. A deliberately hostile shader (unbounded loop) is rejected at ingest even when
   the client-side check is bypassed.
6. A profile page with 50 avatars holds frame rate.
7. Revoking the token on the web causes the next publish to fail with a re-link
   prompt.
8. Signing out of Shadiox removes the token from the Keychain.

## Explicitly deferred

- **Hosted/server-side shader building.** The whole cost model here rests on the
  model running on the user's Mac. A hosted builder is a paid feature or it is a
  bill.
- **Per-note shader skins.** Avatar is profile identity, one square shader per
  person. This is the line that keeps Shadiox from becoming a Shadertoy clone.
- **A public browse/discover gallery.** Avatars render where a person already
  appears. A gallery is a separate product with separate moderation load.
- **Remixing / forking others' shaders.**
- **Web-native authoring** (hand-written WGSL editor) — the natural V1.5, and the
  thing that closes the web-only-user gap without paying for inference.

## Risks, descending

1. **Renderer drift between two codebases.** The whole product is "what you see
   is what they get." Mitigated only by Phase 0's shared package plus golden
   images in both CIs — never by discipline.
2. **Verify WebGPU in the packaged app, not just dev.** The smoke background
   already depends on it, but confirm against the signed bundle before building a
   feature on top; that class of gap has bitten this repo before.
3. **Dependency on the agent-selection roadmap.** "Claude or Codex" in Shadiox is
   that roadmap's provider seam. Shipping Shadiox first means either Claude-only
   or a second, divergent seam.
4. **Opportunity cost.** Per `GO_TO_MARKET_ROADMAP.md`, BusterPhone is the money
   leg and the arm64 build is a shipping prerequisite. Shadiox is a free
   goodwill/identity feature — genuinely good for adoption, and it competes for
   the same hours as the two things that gate revenue and distribution. Sequence
   it accordingly.
