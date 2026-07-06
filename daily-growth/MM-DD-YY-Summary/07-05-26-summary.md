# 07-05-2026 Summary

One long arc across the midnight line (first commits landed late on the 4th):
**the shader-pattern designer was finished**, **the go-to-market strategy was
locked and mapped**, and the **GWS seamless-connect roadmap went from "written"
to "all six phases shipped"** — connecting Google is now one click and zero
typed input.

## Shader-pattern designer, finished (`6b8ca1d`)

The runtime pipeline (workspace `shaders/<name>.wgsl` → `BusterClaw.Shaders` →
`GET /shaders/:name` → live WebGPU compile with the shared prelude) was already
built; the unfinished half was the **skill**. The seeded `shader-designer`
playbook still taught the old bundle-rebuild flow — an agent following it
couldn't actually add a pattern at runtime. Rewritten to the file-first
contract (constraints, prelude API, no-build shipping, preview-based verify),
INTRODUCTION.md updated to match, both live workspaces reseeded. Verified with
a real `.wgsl` round-trip through list/read/select. Also committed from the
working tree: the **cmd-list editor** (`ff34aa4` — editable terminal command
cheatsheet with protected On Duty roles) and the real Tauri icon set
(`b0b1535`).

## Go-to-market: strategy locked (`9dd0f47`)

A structured Q&A session locked the business shape, recorded in
`roadmaps/GO_TO_MARKET_ROADMAP.md`:

- **Free beta first, charge later** — free core + paid tier, with the paywall
  drawn around the two features that cost real money: **Browserbase + GWS**.
- **BYO Claude stays** (no token reselling); buyer = **both, dev-first**.
- **buster.mom** is the domain (unblocks bundle ID `mom.buster.*`, Google's
  homepage/privacy-policy requirement, and the download page).
- **Open core** — repo stays public; paid tier is enforced server-side because
  the gated features are services (our Browserbase keys, our verified OAuth
  app). License TBD during beta.
- **Apple: enroll as individual now**; **payments via merchant of record**
  (Paddle/Lemon Squeezy) — which makes the LLC a liability question, not a
  blocker. **CASA/Google verification starts now**; beta runs under the
  100-tester cap. Beta measured by **opt-in telemetry**.

The honest bits are in the doc: the 7-day refresh-token expiry during Google's
Testing status, CASA as a forever-cost, the BYO-filtered market, and the
"everything we control is weeks; everything slow is someone else's queue"
through-line.

## GWS seamless connect: roadmap written, then all six phases shipped

`roadmaps/GWS_SEAMLESS_CONNECT_ROADMAP.md`, then the build. Target experience:
**click Connect Google → approve in the browser → green checks.** No email
field, no client ID, no Google Cloud Console.

**Phases 0–2 (`c3c2176`):**
- `Google.BundledClient` — the OAuth client as *config, not code*: compiled/env
  values plus an optional remote `oauth-config.json` (lazy, cached, never
  blocks, silent fallback) so the client can be rotated without a release.
- **PKCE (S256)** on every authorization; the verifier rides inside the signed
  10-minute state token. BYO and reconnect flows inherit it for free.
- **One-click connect** in GWS + Setup: pending state lives entirely in the
  state token (abandoned tab = zero residue); the callback exchanges the code,
  discovers the address via the **Gmail profile endpoint** (no extra scopes),
  upserts the account, trusts the user's own address. The three-field BYO form
  demoted behind "Advanced: use your own OAuth app."

**Phases 3–5 (today):**
- **Post-connect self-test** — `Google.SelfTest` probes Mail/Calendar/Drive
  with one cheap read each, persists per-account in Settings, renders as a
  Health row ("Mail ✓ · Calendar ✓ · Drive ✗ (HTTP 403: …)") in the accounts
  panel, runs async after every connect and on demand via a Self-test button.
- **Token health** — `invalid_grant` on refresh (the single choke point) flags
  `reconnect_needed`, emits a Sentinel **`google_auth`** notice (new category),
  and shows a "Reconnect needed — Google session expired" chip; any successful
  exchange/refresh clears it. Written for the beta reality of weekly
  Testing-status token death, and correct forever (revocation).
- **Beta gate + consent framing** — `google_oauth_app_status: "testing"` drives
  request-access mailto + weekly-reconnect copy on both connect surfaces
  (flips off via config when verification clears); Setup copy now names the
  Sentinel audit feed before the Google consent screen appears.

Honest deltas from the plan, recorded in the roadmap: Gmail-profile discovery
instead of adding `openid email` scopes (better); no proactive day-6 expiry
countdown (we don't record token mint time — the reactive path covers it);
mid-shift death surfaces via the Sentinel event, not a shift-pause mechanism.

Suite: **893 tests, 0 failures.** One real flake found and fixed: a background
config fetch hitting `Req.Test`'s ownership server from a non-owner process
poisoned later tests.

## GWS → Configuration, then a sidebar/main console

`GWSLive` was its own Settings sub-tab; folded it entirely into the
**Configuration** tab (`SettingsLive` at `/settings`) so one tab owns all
account-level config, and removed the `/gws` route (repointed split panes,
tab-strip labels, runtime nav, OAuth callback). Then restyled the GWS section
into a **sidebar/main console**: a left tab rail (Accounts / Search / Labels /
Sync Mail / Calendar) with the active tool's form + results in the middle;
results persist across tab switches since they stay in assigns.

## cmd-list: agent-editable, then fully file-first

- **Agent edits from chat** — two native commands (`terminal_command_list`
  read, `terminal_command_set` restricted) so BusterClaw can read + edit the
  cmd-list catalog itself; protected On Duty roles refused, multiline-shell
  rejected, same validate→persist→broadcast path as the UI.
- **File-first storage** — the catalog moved out of the Settings KV store into
  `<workspace>/cmd-list/catalog.json` (+ README), seeded on boot, read live —
  like `skills/`, `shaders/`, the `buster-claw` launcher. The file holds the
  full non-protected roles (not a diff); protected roles stay code-enforced.
- **Prompts generated from skills** — the Prompts role is now `welcome` +
  one prompt per enabled `skills/*.md`, synthesized at read time, never
  persisted; Settings → Cmd List renders them read-only ("From your skills
  folder"). A user's own `skill-<name>` row shadows the generated one.
- Renamed the sub-tab label to **"Cmd List"** and widened the terminal
  cmd-list flyout to 34rem.

## Terminal fine-tuning

- **Split (+) button greys out** once a tab is already split (2 terminals is
  the limit) so a third can't push a pane out.
- **Dock Terminal button opens a NEW shell every click** (a fresh session key
  + tab, like Cmd-T). It had been navigating to bare `/terminal`, which falls
  back to the shared `"main"` session — so it kept reopening the same shell.

## Tab strip: Settings reopens where you left off

The collapsed "Settings" top tab always navigated to Configuration; now it
remembers the last sub-route visited (per-tab `href`) and returns there. Also
refreshed the Settings group set (dropped `/gws`, added `/cmd-list`).

## Housekeeping — docs + the archive lifecycle

- Removed the completed `chat-roadmap.md`; **moved the in-app manual source
  out of `daily-growth/` to a top-level `user-guide/`** (compile-time embed +
  drift-check + moduledocs all updated).
- Reviewed the **veteran review** and **07-04 code review**: verified their
  P0/P1 fixes still hold in current code (SSRF, catalog invariants, no
  `String.to_atom`, README drift), then archived both completed docs. Caught
  and fixed a self-inflicted regression — recent archiving to
  `roadmaps/oldmaps/` had reintroduced the exact "old nesting" the veteran
  review's P2-2 banned; consolidated everything into one flat
  `daily-growth/archive/` (`grep old` → 0) and restored the Shortlist live.

## The weather-shader bundle break (worth remembering)

The app suddenly looked broken — tab strip gone, WebGPU shaders dead, chat
stretched/mis-laid-out, all at once. Root cause: an agent's redesign of the
weather shader put **`reach` with backticks in a WGSL comment**, but
`assets/js/smoke/weather.wgsl.js` is a **JS backtick template literal**, so the
stray backtick terminated the string mid-file. esbuild failed that file, which
**took the whole `app.js` bundle down** — and with no bundle, *every* LiveView
hook died simultaneously (the tab strip renders itself client-side, the shaders
are a hook, the chat layout is hook-driven). One-line fix (drop the backticks);
build clean again.

**Lesson:** the six baked-in shaders (`assets/js/smoke/*.wgsl.js`) are JS
template literals — a backtick *anywhere* inside, even in a comment, breaks the
entire bundle. The workspace `shaders/*.wgsl` files (shader-designer output) are
served as raw text and compiled in-browser, so they're immune; this footgun is
built-ins only. When the app goes fully dark, it's almost always a broken
`app.js` — `mix assets.build` names the exact file:line.

## What's next

The app side of seamless connect is **done, waiting on the operator
checklist**: GCP project + consent screen + Desktop-app client (~40 minutes,
also starts the CASA clock), Apple Developer enrollment, buster.mom live with
a privacy policy. Then GTM workstreams W0–W2 (bundle ID switch, sign/notarize,
first full clone-to-`.dmg` build).
