# 07-25-26 — The field test, the wiring it exposed, and the mirror

The browser engine met a real, adversarial, logged-in site for the first time.
The errand succeeded — two items into the operator's Amazon cart, a cart that
matched Amazon's subtotal to the cent, human paid — and it exposed four defects,
every one of them at the **wiring layer**: capabilities that exist, are tested,
and are correct in isolation but are not connected to the surface the agent
actually calls. The most serious meant the payment gate did not fire on Amazon.

That is the theme of the whole day. Nothing shipped today was a new capability
in the ambitious sense; it was closing the distance between "correct in
isolation" and "correct when something real runs through it" — and then building
the thing the field test said mattered most.

7 commits, 39 files, +3822/-436. Suite at close: 1380 unit tests, 186
browser-control tests including live Chromium, credo/dialyzer/Rust clean.

## 1. The field report, in-repo

`daily-growth/roadmaps/BROWSER_CONTROL_FIELD_TEST_07-25.md` — the model's own
write-up of the run, unmodified, version-controlled beside the roadmap it feeds.
The roadmap reopened with a section recording not just the tickets but the two
judgments worth keeping.

## 2. The payment gate failed OPEN on Amazon

`@payment_path_re` had no `buy` token and anchored to whole path segments, so
Amazon's entire `/gp/buy/` funnel *and* its literal `payselect` page both sailed
through. A commerce run could walk the checkout funnel still in `agent_working`
— the only mode that permits acting.

Replaced with segment-wise matching over two lists whose rules differ on
purpose: `@payment_fragments` matches a segment that **contains**
(checkout/pay/billing/purchase — this is what finally sees `payselect`, and it
also catches Shopify's plural `/checkouts/`), `@payment_words` a segment that
**is** (buy/place-order/… — `buy` belongs here because substring `buy` would
halt `/buyers-guide`). Four payment hosts added.

**Why the suite passed while the gate was open** is the part worth remembering:
its fixtures were paths we invented (`/checkout/`), and `AgentModeTest` faked
the decision with `String.contains?(url, "checkout")`. Nothing in the suite ever
asked the real `Scope` about a real checkout URL. The new table is real URLs
only, with the rule written into the file: *if you cannot name where a path came
from, it does not belong in this test.*

## 3. `text` targeting nearly bought the wrong product

`click text: "45 inches"` matched a customer **review's** variant byline
("Size: 45 inchesColor: Dark Brown") instead of the size swatch. Had it landed
on a different valid swatch, the wrong size would have gone into the cart
silently and every downstream receipt would have been perfectly accurate about
the wrong item.

Resolution is now two-tier — exact match first, substring second — refusing with
`{:ambiguous_text, count}` when the winning tier has more than one member.
Exact-first is the half that matters: it makes the field test's own case
*resolve correctly* rather than merely fail safely, since the real swatch reads
exactly "45 inches" while the byline only contains it. `selector` and `index`
keep first-match semantics — `text` is the fuzzy instrument, so `text` is the
one that must not guess.

The refusal carries a count and deliberately **not** the matched labels: labels
are page content and an error path is not egress-accounted, so shipping them
would be untracked bytes the run summary could not reconcile. A test asserts
their absence so a later "helpful" patch fails loudly.

## 4. Walking it, and how far that got

Two new files run the **real** gate rather than a stand-in:
`commerce_payment_gate_test` (real `BrowserControl.navigate/4`, real Sentinel
record, a commerce run handing off at Amazon checkout with a cent-exact frozen
cart) and `page_targeting_live_test` (6 tests against real Chromium on the exact
DOM that defeated targeting — the stub suite could only assert the JS we
*generate*, which is how the defect survived).

Then a live anonymous probe: throwaway profile, no account, no purchase, search
→ product → add to cart → read the real checkout control. It is
`https://www.amazon.com/checkout/entry/cart`, and the gate halts it.

**Stated precisely:** that URL would have been caught by the *old* regex too —
it was never the gap. The `/gp/buy/` funnel is only reachable logged-in, and the
field-test agent only got there by constructing the URL itself. So the live
entry point is confirmed gated, the logged-in funnel is gated *by test* but
still not *by walk*. That last mile needs the operator's own session and remains
open.

## 5. Finding 6 — the gate authorized the request, not the landing

Surfaced while walking item 3. `navigate/3` ran the scope gate on the URL it was
*asked* for, then waited for the load event — and nothing checked where the
browser ended up. A 302 carried a run onto a payment page or an off-scope host
with the mode still `agent_working`. Same failure as the payment regex by a
different road: that was a bad pattern, this was a missing check.

The gate now fires twice, and the returned origin always describes the landing.
**That second part is the half that leaked**: `AgentMode` sets `current_host`
from the origin and `Egress` resolves the per-host redaction level from it, so a
cross-host redirect left content prepared at the *previous* site's level — a
`:structure_only` host (banking, health, government) was readable at `:full`
simply by being redirected to. `redirect_egress_test` pins it.

On what a failed re-check should do, the mode machine already had the answer: a
halt flips the mode, and acting is legal only in `agent_working`, so the agent
cannot read, click, or navigate from the page it was redirected onto. Nothing
needs to navigate away — the run loses the wheel. Fails closed: an unreadable
landing is `{:halt, :unverified_location, meta}`.

Two things fell out. `Session.info/1` was lying the same way — reporting the URL
navigation was *requested* for while calling it "current url"; it now stores the
landing, caught by a live test asserting the origin agreed with the session
(amazon.com 301s to www.amazon.com, and it did not). And `guarded_navigate_test`
stopped **re-implementing the composition it tests** — it copied
guard-then-navigate into the test file and asserted against the copy, the same
shape that produced the field-test defects.

## 6. Phase 7 — the mirror

The field report's own conclusion was that the single most effective safety
property in the run was not a gate: it was that the run is headful and
supervised, so a human could see it. But watching meant alt-tabbing to another
application — supervision that was *available* but not *practical*.

`Page.startScreencast` pushes JPEG frames over the pipe we already own, through
the CDP client that already fans events out, so the mirror is one more
subscriber: no new transport, no new trust boundary. They reach the browse tab
as MJPEG (`multipart/x-mixed-replace`) in a plain `<img>` — the webview decodes
natively and frames never touch the LiveView channel, where base64 through
`push_event` would be ~0.5–1 MB/s of JSON contending with every other diff.
Capture is on demand: the connection process **is** the watcher, so an unwatched
run costs no engine CPU and closing the tab tears it down with nothing to
remember. Acking each frame is the flow control, not bookkeeping — Chromium
withholds the next frame until the current is acked — so a slow viewer drops
frames rather than growing a queue.

Prerequisite shipped with it: `CDP.subscribe/2` takes a `:methods` filter.
Without it a running screencast pushes ~15 × 60 KB messages per second into
every subscriber's mailbox, including `Session`'s, which only wants load events.

**Not embedding Chrome's window** — macOS has no supported cross-process view
reparenting; ruled out on the merits and recorded in Deferred so it is not
re-proposed.

## 7. What only the end-to-end walk found

Three defects survived a fully green unit suite:

- **A static page emits no frames at all.** Screencast fires on *new compositor
  frames*, and the agent usually pauses on a settled page — so the mirror opened
  black and stayed black, indistinguishable from broken. Seeded with a
  `Page.captureScreenshot`, which renders on demand.
- **The caster was a `:permanent` child.** It stops normally when the last
  watcher leaves; the supervisor read that as failure and restarted it, which
  stopped again — max_restarts tripped, the DynamicSupervisor died, and it
  cascaded into the application supervisor. *The whole app died because somebody
  closed a tab.* Now `:temporary`, like `Session`. It failed 30 unrelated tests
  as collateral, which is how it surfaced.
- **A missing supervisor rendered as a 500** rather than a legible error — found
  by driving a dev node that predated the tree change, since code reload
  recompiles modules but never adds supervision children.

Also written down because it cost an hour: `URI.encode/1` does not escape `#`,
so a `data:text/html,` fixture truncates at the first CSS colour. The page
arrives without its script and paints once — symptomatically identical to
"screencast only ever sends one frame". Fixtures use base64 data URLs now.

## 8. The window, stashed

Headful is correct — checkout popups and native dialogs need a real window — but
that window landed on top of everything, so the experience read as "a Chrome
window pops up" even with the mirror built. It is now pushed aside at run start
(`stash_window/2`) and brought back by the "Real window" control
(`reveal_window/2`, which restores position *before* focusing; `bringToFront`
alone would focus a window that is still off-screen).

Two constraints, measured rather than assumed, both pinned by
`WindowPlacementLiveTest` because both are easy to "tidy up" back into a broken
state: **minimizing stops compositing on macOS** (screencast dies after one
frame, mirror freezes), and **macOS clamps window positions**, so `left: -32000`
lands near `-1240` and a ~40px sliver stays visible at the screen edge. Out of
the way, not invisible; closing that last gap is not available without giving up
the live view. Operator confirmed the real-app result: the errand completed with
no pop-up windows.

## 9. The guide routes by consequence

The workspace guide taught `browser_*` as *the* way to drive a browser and never
mentioned `agent_run_*` — so a chat-spawned model asked to browse reached for
co-presence or a plain fetch, meaning anything consequential ran on the ungated
path and the watchable engine went unused because nothing said it existed.

Now: public reads → `web_search`/`browser_fetch`; the tab the user is looking at
→ `browser_*`; **a logged-in session or money → `agent_run_*`**. One rule the
model can apply without a table: *if it can spend money or act as the user, it
belongs in an Agent Mode run.* It also teaches the guardrails as things to work
*with* — a halt is a decision not an error, payment pages stop the run and the
human confirms in the app so the model must not offer to — and carries the field
test's lesson into the model's own guide: use `selector` for anything that
decides what gets bought, and **verify a variant against the cart line, never
the product page's default**. The guide regenerates on launch, so existing
workspaces pick it up.

## 10. Deliberately not built

**Mirror input forwarding.** The rule was "refuse while `agent_working`,
read-only at `awaiting_human` on a payment page" — and the state machine cannot
express it. `awaiting_human` is reached by *both* `take_wheel` and `need_human`
and the resulting states are identical, so a deliberate take-the-wheel is
indistinguishable from a payment handoff. Shipping input under a rule that
cannot be enforced is worse than shipping the mirror without it; watching was
the finding. The input slice needs an `awaiting_reason` on the run first.

**`agent_run_confirm_purchase` on the command surface.** The field report
recommends exposing it; we are not going to. `:restricted` is runnable by
`agent_untrusted` — an agent that has been reading page content — which would
let it write its own ledger entry for a purchase it claims happened. Confirming
is the human's act and the LiveView button is the complete surface. Gated-only
if ever exposed.

## 11. Open

Item 3's last mile (the signed-in `/gp/buy/` walk), mirror input forwarding
(blocked on `awaiting_reason`), `find_elements` selector, Keychain-backed
`secret_resolver`, per-host egress levels with a config surface. New risk on the
roadmap, with a proven instance: *a gate whose fixtures we authored ourselves is
unverified until it meets a real site* — mitigated by a live walk per gate, not
a larger table of imagined paths.
