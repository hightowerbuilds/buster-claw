# GWS Seamless Connect Roadmap

*2026-07-04. Governing principle: **connecting Google is one click and zero typed
input.** The app ships its own OAuth client; the user clicks "Connect Google,"
approves in the browser, and comes back to green checks — they never see a client
ID, never type their email, never visit Google Cloud Console. The existing
bring-your-own-client form survives, demoted to an "Advanced" disclosure: it is
Channel A for developers and the fallback if Google verification stalls. This is
F2 from the distribution roadmap, executed to the GTM roadmap's standard.*

Effort tags: **S** = a sitting, **M** = a day-ish, **L** = multi-day / has unknowns.

> **Status (2026-07-05): Phases 0–5 all SHIPPED.** Phases 0–2 in `c3c2176`
> (BundledClient + PKCE + one-click connect), Phases 3–5 the following day
> (self-test, token health, beta gate). Honest deltas from the plan:
> email discovery uses the **Gmail profile endpoint** instead of adding
> `openid email` scopes (fewer scopes, same result); the Phase 4 "warn as
> expiry approaches" proactive countdown was **not** built (we don't record
> refresh-token mint time — the reactive `invalid_grant` → chip + Sentinel
> notice path covers the experience); on-duty mid-shift death is surfaced via
> the `google_auth` Sentinel event from the refresh choke point, not a
> shift-pause mechanism. **Remaining work is entirely the operator console
> checklist below** — the app side is done and runs on a placeholder client
> until real Desktop-app credentials exist.

---

## Where this sits

Today, connecting Google costs a user a trip through Google Cloud Console.
`SetupLive` Step 3 (`lib/buster_claw_web/live/setup_live.ex:326`) is a
three-field form — **email, OAuth client ID, OAuth client secret** — which means
the user must first create a GCP project, enable eight APIs, configure a consent
screen, and mint credentials. Twenty-plus minutes, developer-only, and the wall
between "downloaded the app" and the flagship on-duty feature.

What already exists and is kept:

- **Loopback callback** — `GoogleOAuth.callback_url/0` serves
  `http://127.0.0.1:<port>/google/oauth/callback`; state is a signed
  `Phoenix.Token` with nonce + 10-minute expiry.
- **Encrypted storage** — `Google.Account` encrypts client_secret / tokens via
  `Vault`; `scrub/1` keeps secrets out of LiveView assigns.
- **Refresh plumbing** — `OAuth.refresh_access_token/1`, and `GWSLive` already
  has a `reconnect` event.
- **Per-account scopes** with `@default_scopes` (deep-scope set — locked
  decision, no minimization).

What changes: the *account bootstrap* (who supplies the client, when we learn
the email) and the *post-connect experience* (proof it worked, token health).

## The bundled client — trust model

One Google Cloud project (buster.mom brand), OAuth client type **Desktop app**.
Google's own docs treat installed-app client secrets as **not confidential** —
embedding them in a distributed binary is the sanctioned pattern. We add PKCE
(S256) on top, which composes fine with a secret-bearing client and is what
Google recommends for installed apps. The signed `state` token + loopback
redirect already cover the rest of the threat surface. Nothing about the BYO
path weakens: user-supplied secrets stay Vault-encrypted exactly as today.

The bundled client is **config, not code**: compiled-in defaults, optionally
refreshed from `https://buster.mom/oauth-config.json` (cached, signed-domain
HTTPS, falls back to compiled values on any failure). That lets us rotate or
re-issue the client without shipping a build — insurance against the client
being abused or a verification hiccup forcing a new one.

---

## Phase 0 — Bundled client config (S)

`BusterClaw.Google.BundledClient`:

- `get/0` → `%{client_id: ..., client_secret: ...} | nil` — resolution order:
  runtime override (env/Settings, for testing) → cached remote config →
  compiled default. `nil` until a real client exists; every UI surface treats
  `nil` as "bundled connect unavailable, show Advanced."
- Remote fetch is lazy + cached with TTL; any parse/network failure falls back
  silently (Logger.debug, not user-facing).
- Compiled default lives in config so dev/test can inject fakes; the *real*
  values land here once the console project exists (operator checklist below).

Exit: `BundledClient.get/0` returns the placeholder in dev, `nil` handling
verified, remote-fetch fallback tested.

## Phase 1 — PKCE (S)

In `BusterClaw.Google.OAuth`:

- Generate `code_verifier` (43–128 char URL-safe random) per authorization;
  send `code_challenge` + `code_challenge_method=S256` in `authorization_url`.
- Carry the verifier inside the signed state token (it is short-lived and the
  token is already tamper-proof) so the callback can present it at exchange.
- `exchange_code` sends `code_verifier`; keeps sending `client_secret` when the
  account has one (Desktop clients require both — PKCE is belt on top of
  suspenders, and BYO confidential clients are unaffected).

Exit: existing BYO flow still round-trips (tests), PKCE params present on every
new authorization.

## Phase 2 — One-click connect (M)

The heart of the dissolution. New flow, `GWSLive` + `SetupLive` Step 3:

1. **"Connect Google"** button (shown when `BundledClient.get/0` is non-nil).
   Creates nothing yet — just builds an authorization URL against a *pending*
   bundled-client account context and opens the system browser.
2. Callback exchanges the code (PKCE + bundled secret), then calls the
   **userinfo endpoint** (add `openid email` to the requested scopes — both
   non-sensitive) to learn the address.
3. `Google.upsert_account/1` on the discovered email: new address → account
   created with bundled client + tokens; known address → tokens/scopes updated
   (re-connect and add-second-account are the same gesture).
4. Browser tab lands on the existing "return to the app" page; the LiveView
   refreshes via the existing `google_account_changed` broadcast.

The three-field form moves behind **"Advanced: use your own OAuth app"**
(collapsed disclosure, same fields, same validation — Channel A intact). Setup
wizard copy rewritten around the one button.

Design note: step 1 must not create a half-empty `Account` row that leaks into
`list_accounts/0` if the user abandons the browser tab. Either carry the
"pending" entirely in the state token (preferred — the callback has everything
it needs to upsert) or create-with-status and sweep abandoned rows.

Exit: fresh dev instance with placeholder client (against a test GCP project)
→ one click → account appears with correct email, zero typed input.

## Phase 3 — Post-connect self-test (S/M)

The scariest OAuth moment is the second after consent. Immediately on connect
(and on demand from the GWS panel): fetch Gmail profile, list one page of
labels, list calendar list — render **green checks per surface** (Mail /
Calendar / Drive) with the failing scope named on any miss. Persist the last
self-test result + timestamp on the account summary so the panel always shows
connection health, not just connection existence.

Exit: a deliberately scope-stripped account shows a named failure, not a stack
trace; a healthy account shows three greens within seconds of connecting.

## Phase 4 — Token health & the 7-day beta reality (M)

While the OAuth app is unverified ("Testing" status), Google expires refresh
tokens every **7 days**. That is survivable only if the app is graceful about
it:

- Detect `invalid_grant` on refresh → mark the account `reconnect_needed`
  (status field on the summary), never silently fail.
- GWS panel + homepage status: visible "Reconnect Google" chip with the
  existing one-click `reconnect` flow (which, with Phases 0–2, is now itself
  one click, no form).
- **Sentinel `:notice`** when tokens die — and if it happens mid-shift, the
  on-duty loop surfaces "Google disconnected, shift paused for mail" instead of
  opaque command failures.
- During Testing status only: show connected-since + "Google may require
  re-connecting weekly during beta" copy so the expiry reads as expected, not
  broken. (Post-verification this text and the 7-day urgency disappear on their
  own; the `invalid_grant` handling stays forever — tokens can always be
  revoked.)

Exit: revoke a test account's grant server-side; the app degrades to a labeled
reconnect chip + Sentinel event, and one click restores it.

## Phase 5 — Beta access gate + consent framing (S)

Two pieces of copy that make the Google-imposed friction feel intentional:

- **Unverified-era access gate:** test users must be hand-added in the console
  (no API exists). Pre-connect, the panel's first state is "Request beta
  access" — prefilled mailto with their address, and "you'll get a confirmation
  within a day." After confirmation they click Connect like anyone else.
- **Consent framing:** the moment before the browser opens, one panel in our
  voice: what BusterClaw will be able to do (read/send mail, manage calendar,
  drive, docs...), why, and that every action lands in the Sentinel audit
  trail. The Google consent screen then *confirms* instead of ambushes. This is
  the app's honesty posture doing sales work.

Exit: copy reviewed by the operator; the unverified path is followable by a
non-developer.

---

## Operator checklist (console side — also starts the GTM CASA clock)

Only the operator can do these; ~30–45 minutes total, then the slow clocks run:

1. GCP project (e.g. `buster-mom-prod`), brand set to buster.mom (domain must
   be verified in Search Console first).
2. Enable APIs: Gmail, Calendar, Drive, Docs, Sheets, Slides, People
   (Contacts), Tasks.
3. OAuth consent screen: External, deep-scope list from
   `OAuth.default_scopes/0` **plus `openid email`**, homepage + privacy-policy
   URLs on buster.mom (GTM W0 must land first).
4. Create **Desktop app** OAuth client → client ID + (non-confidential) secret
   → into `BundledClient` compiled config + `buster.mom/oauth-config.json`.
5. Add initial test users (operator + first beta users).
6. Submit for verification → CASA. (GTM roadmap Clock 2 — start immediately,
   run in background.)

## Exit test for the whole roadmap

A fresh machine, signed build, test-listed Google account: install → Setup
Step 3 → **one click, one Google approval, zero typed input** → three green
checks → send a test email from the terminal via `google_mail`. Under two
minutes, no console, no documentation open in another tab.
