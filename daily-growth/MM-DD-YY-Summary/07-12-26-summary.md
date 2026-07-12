# 07-12-2026 Summary

The day the business model got honest. It started as a codebase review and
turned into the most consequential strategy day of the project: **Browserbase
is deleted, the paywall it anchored turned out to be standing on zero legs,
BusterPhone was crowned the money leg, the repo went MIT with the name
reserved, and the one technical gap in the phone — the Mac-side drain — is
shipped.** Eight commits (`bab3a88..22b89e3`), net −2,100 lines, and the
paid tier now describes something that can actually exist.

## The review that pulled a thread

A full-codebase read (four parallel explorers: security/commands,
orchestration/dispatch, web/Google/integrations, frontend/Tauri/phone) turned
up one small lie: `Browser.status/0` reported `health: "available"` for a
configured external sidecar without ever probing it. Closer look: the
function had **no callers at all** — only two tests pinning it. Deleted
(`bab3a88`). But the sidecar questions it raised didn't stop there.

## Browserbase: deleted root and branch (`419577d`, −2,158 lines)

The operator's instinct — "don't pile on code we don't need" — led to the
load-bearing discovery of the day: **Browserbase could never run in the app
we ship.** A cloud session isn't driven from Elixir; it's driven over CDP by
the *local Playwright sidecar*, and the prod build neither enables that
sidecar (`runtime.exs` gated it to dev) nor installs node/Playwright at all
(`build_desktop.sh` only runs `npm ci` in `assets/`). Every packaged build
that ever existed had a paid feature with no driver.

Cut: the three Browserbase modules, `SessionClient`, all 12 `web_*` agentic
commands, config, tests, and the CDP machinery in `server.js`. Capability
lost in production: **zero** (it never worked there). Capability lost in
principle: unattended web *interaction* — the `browser_*` co-presence verbs
need the desktop window open. Acceptable; the live-tab verbs are better for
the actual use anyway.

## The paywall was standing on nothing (`7249e68` → `466696f`)

Deleting Browserbase didn't narrow the paid tier from two legs to one — it
took it to zero, because **on-duty cannot be paywalled at all**: the
Dispatcher touches exactly one endpoint (`127.0.0.1`) and the agent is the
user's own BYO Claude. Zero marginal cost + our own no-client-DRM rule = no
hook to withhold in a public repo. And GWS alone is the wrong thing to sell
a dev-first buyer (a one-time GCP setup priced as a subscription, with CASA
as its forever-cost).

**Resolved same day: BusterPhone is the money leg, as managed telephony.**
We hold the Twilio account, we provision the number, the user never learns
Twilio exists — the deliberate inverse of BYO Claude (buyers already have
Claude; nobody has a spare phone number). The trap written down so it can't
be re-proposed: BYO-Twilio-as-paid-tier means the buyer pays twice and we
have nothing to enforce. Free/Channel A stays honest: bring your own Twilio
and Supabase, wire it yourself. And the compliance find that reorders the
build: **inbound voice needs no A2P 10DLC** — the paid tier ships voice-first
with zero registration paperwork; SMS (which drags the LLC forward via the
EIN requirement) waits.

## MIT + trademark + the Signature Feed (`0e62021`)

The README had claimed "License: MIT" for months while the repo carried **no
LICENSE file** — all rights reserved by accident. Fixed for real: MIT for
the code *including* the WGSL shaders and the Industrial Claw CSS (they're
the best advertising we have, and MIT makes every fork carry the copyright
notice — the attribution actually wanted). Reserved: the name, wordmark,
logo (`TRADEMARK.md` — "rename your fork; that's the whole ask"). AGPL/BSL
rejected on the merits: neither money leg is defended by copyright — the
phone is defended by owning the number, the feed by making new things.

The operator's reframe became `SIGNATURE_FEED.md`: don't *vault* the
signature assets, **publish them as a stream** — ongoing drops of shaders,
palettes, phone faces, greeting voices. You cannot fork work that doesn't
exist yet. The phone acquires; the feed retains. Hard line recorded: a pack
carries WGSL and data, **never JavaScript** (remote JS = RCE in the webview).
README rewritten to match reality (134 commands, verified by running the
catalog — it claimed ~70).

## The number-vending dossier (`307991b`)

`NUMBER_VENDING.html` — an Industrial Claw operations dossier (self-hosted
fonts inlined, four hand-built SVG diagrams, published as a claude.ai
artifact). Its thesis: vending is a **state machine with a meter on it** — a
number costs rent in four states and earns in one; `suspended` and `parked`
must be time-bounded or they're a subscription we pay on our customers'
behalf forever; releasing a number is a one-way door with a person behind
it; usage (not the number) is the cost risk, so caps ship with the first
paid number; subaccounts-per-customer decided now, not retrofitted. Phase 1
is concierge: vend the first ten numbers **by hand**.

## The drain shipped (`22b89e3`) — the inbound path is complete

The gap every document called "the blocker" is closed.
`Telephony.Relay` + `Telephony.Drain`: poll the Supabase queue, download
voicemail audio into the Library, mirror rows into SQLite (PubSub → the
/phone tab updates live; Sentinel observes inbound), then ack. **Design
change from the sketch: it polls PostgREST (30s), no Slipstream websocket**
— a socket can't replay rows missed while the laptop slept, so the catch-up
poll must exist anyway, and at answering-machine latency it *is* the drain.
Persist-then-ack (crash → re-drain → `twilio_sid` dedupe; retry, never a
lost voicemail), a 180s transcript grace window (Twilio's transcription
callback trails the recording callback), storage-404 drains without audio,
traversal paths refused. 8 tests. One bug cost a debugging round:
`runtime.exs` runs *after* `config/test.exs` and was clobbering the test
stubs with nil — the relay block is now guarded out of `:test`, with the
reason in a comment.

## Housekeeping that was overdue

`mix precommit` had been red on `main` — workers were verifying with bare
`mix test`. Now green (`bce193a`): of 102 credo findings, 33 actually fixed,
three thresholds calibrated with reasoning written into `.credo.exs`, and
six genuine outliers annotated rather than hidden (`cli.ex` `main/1` at
complexity 23 is real debt → Shortlist item 6; gmail's two lookup tables are
*not* debt and their comments say don't "fix" them). Also learned:
`precommit` runs `format`, not `--check-formatted` — it rewrites files,
which was the mystery churn in unrelated diffs.

## Where things stand

894 tests green, precommit green, everything pushed. The wire from a
caller's voice to the /phone tab is complete but has only been proven
against stubs — **the remaining Phase 0 is console clicks, waiting on a
paycheck**: upgrade Twilio to paid, wire the number's Voice webhook, set
`SUPABASE_URL` + `SUPABASE_SERVICE_ROLE_KEY`, call +1 844-687-8016, and
watch the voicemail land within 30 seconds. That first real call is the
true verification of today's code — and the day the money leg starts
existing in the world instead of in documents.
