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

## What's next

The app side of seamless connect is **done, waiting on the operator
checklist**: GCP project + consent screen + Desktop-app client (~40 minutes,
also starts the CASA clock), Apple Developer enrollment, buster.mom live with
a privacy policy. Then GTM workstreams W0–W2 (bundle ID switch, sign/notarize,
first full clone-to-`.dmg` build).
