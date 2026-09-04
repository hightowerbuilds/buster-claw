# Cancelling an order — the second thing that reaches the broker

**Scoped 08-04-26 · Status: CLOSED + ARCHIVED 08-05-26. Built 08-04-26 as option
B — the chat holds the verb.**

**Nothing left this file, and that is deliberate.** Phase 0 and Phase 3 are done
and verified in code (`@cancel_tools` in `trading.ex`, handed to `Agent.Chat`
through `audit_tools:`). Phases 1 and 2 are the **option A** design the operator
overrode — the road not taken, not work outstanding — so they are not leftovers
and must not be inherited as such. If the confirmation card is ever wanted, it
needs a fresh operator decision, not a checkbox: the argument for it is in this
file, and it lost once already.

The one real cost — the agentic-account restriction is no longer a guarantee
*this app* makes, only one we ask for and Robinhood enforces — is a property
that was traded, not a task anyone could pick up.

> **Operator decision, against the recommendation below.** This roadmap
> recommended **A** (a `cancel` fence and a confirmation card). The operator
> chose **B**: the cancel tool goes into the chat's own allowlist and reaches the
> broker on the model's say-so. That is recorded here rather than quietly
> rewritten, because the recommendation was wrong about what the operator wanted,
> not about what it costs — and what it costs is stated in the code that ships
> it (`trading.ex`, above `@cancel_tools`).
>
> **What the choice traded:** this tab's safety was *structural* — the model held
> no write verb, so it could not act. It is now *behavioural* — it holds one and
> is told how to use it. The prompt is the guard rail; there is no second one.
>
> **What it did not trade:** the audit record. `:audit_tools` hands the cancel
> verb to `Agent.Chat`, which posts a Sentinel `:outbound_send` line the moment
> the tool is called — as it happens, not at the end of the run. The operator
> gave up the click, not the record.

## What shipped

- `@cancel_tools` — one verb, kept *out* of `@read_tools` so that list keeps
  meaning what its name says and the exception stays visible.
- The Authority paragraph rewritten, not appended to. It used to promise "you
  never will" about cancel; shipping the verb under that sentence would have
  been the worst of both. Plus four named rules: read the id first, stop on
  ambiguity, agentic accounts only, and UNKNOWN when the tool does not confirm.
- `:audit_tools` in `Agent.Chat` — generic on purpose; that module does not
  learn what a broker is, only that some verbs are worth recording on use.
- `ModelPolicy` — cancellation **shares** `:order_submit` (Phase 3's open
  question, decided). A cheaper model can never reach cancelling without also
  reaching placing.
- The Trading banner and the Explore tutorial both restated. Neither now claims
  the chat cannot cancel.

## What was NOT built, and is not planned

Phases 1 and 2 below are the *option A* design — a `cancel` fence, a
`TradingCancel` parser, a confirmation card, a third confined run. None of it
exists. Read them as the road not taken, not as work outstanding.

The one thing option A had that B cannot: **the agentic-account restriction is
no longer a guarantee this app makes.** The tool call is the model's, so we ask
for it in the prompt and rely on Robinhood refusing the rest. That is a real
difference from placement and should not be described as equivalent.

---

The Trading chat can already *see* resting orders — `get_equity_orders` has been
in the read allowlist all along. It cannot touch them. This roadmap adds
cancellation, and the whole question is which shape it takes, because this tab
carries the strictest promises in the app and one of them is about to become
either true in a second case or false in the first.

---

## What is already true (read before designing)

**The chat is read-only by construction, not by instruction.** `@read_tools` is
eleven `get_*` tools and nothing else, enforced by `--allowedTools` +
`--disallowedTools` + `--strict-mcp-config` — a three-part confinement whose
every part was probe-verified (`trading.ex:290`). The model is not asked to
behave; it is handed no verb.

**The prompt makes that a promise in words too:**

> *"You have NO order tool and you never will in this conversation. You cannot
> place, amend, or cancel anything."*

Note that sentence already names cancel. Whatever gets built has to leave that
sentence true or change it deliberately — not quietly.

**Placement is a separate, confined, operator-triggered run.** The model emits a
fenced ` ```order ` block; `TradingOrder.parse/1` turns it into a struct; the app
renders a confirmation card built from the *parsed* values, never the prose; the
operator clicks; and only then does a second agent run spawn with
`@submit_tools = [get_accounts, place_equity_order]`. The banner states the
resulting property plainly:

> *"Orders leave only from a card you click — the assistant proposes, it never
> sends."*

**`agentic` is already a real concept.** Accounts carry `agentic: true` when
Robinhood has enabled them for agentic trading, and the order prompt records that
"Robinhood refuses orders on any other account". Scoping cancellation to agentic
accounts is therefore mostly inherited rather than invented — but it should be
asserted rather than assumed, because "the broker will refuse it" is a different
guarantee from "we do not ask".

**`mcp__robinhood__cancel_equity_order` exists** in the MCP surface and is in no
allowlist anywhere.

---

## The decision this roadmap exists to make

**A. Mirror placement exactly.** A ` ```cancel ` fence naming the order, a
confirmation card built from parsed values, and a third confined run with
`[get_accounts, get_equity_orders, cancel_equity_order]`. Every existing property
survives verbatim, including the banner and the Authority paragraph — cancel
simply joins place as a thing the operator clicks.

**B. Let the chat cancel directly**, by adding the cancel tool to `@read_tools`.
Fewer moving parts and genuinely faster. It also makes the banner false: orders
would leave on the model's say-so, and the Authority paragraph would have to be
rewritten to carve out an exception. The three-part confinement stops being
"reads only" and becomes "reads, and one write".

**C. No model involvement at all** — a Cancel button on each open order in the
Trading panel. Safest and possibly what is actually wanted, but it is not what
was asked for, and it leaves "cancel the one I placed by mistake this morning"
as a hunt through a list rather than a sentence.

**Recommendation: A.** Not from caution as a reflex — from the specific
observation that this app's trading safety is *structural* rather than
behavioural, and B is the only option that converts it into behavioural. The cost
of A is one more fence, one more card, one more confined run: real work, but work
that reuses three existing shapes almost exactly.

### Why cancel is not obviously "safer than placing"

The tempting argument for B is that cancelling cannot lose money. It can.

- **A resting limit order is a position in a queue.** Cancelling and re-placing
  loses time priority, and in a moving market that is a real cost.
- **Cancelling the wrong order** is the live failure mode. With several orders
  open on one symbol, "cancel my Apple order" is ambiguous, and the model
  resolving that ambiguity silently is exactly the thing the confirmation card
  exists to prevent.
- **A cancel that half-works** — the broker acknowledges but the order fills
  first — is the same three-outcome problem `TradingOrder` already solves for
  submission (accepted / refused / *unknown*), and unknown is the one that
  matters.

None of these argue against cancellation. They argue that its outcome deserves
the same three-state honesty placement already gets.

---

# Phase 0 — Decide (short) — DONE

- [x] **A, B, or C.** → **B**, by the operator.
- [x] The "unknown" vocabulary survives, but as a *prompt rule* rather than a
      card state: the model is told to report UNKNOWN when the tool does not
      clearly confirm, and never to report a cancellation it did not see succeed.
- [x] `agentic: true` is **not** asserted by us — see above. The prompt asks;
      Robinhood enforces. This is the one guarantee option B could not keep.

# Phase 1 — The proposal — NOT BUILT (option A design)

- [ ] A ` ```cancel ` fence and a `TradingCancel` parse/validate, mirroring
      `TradingOrder.parse/1`. It needs enough to identify ONE order
      unambiguously — an order id, not a symbol — plus the symbol and side for
      the card to display, so the operator reads what they are cancelling rather
      than an opaque id.
- [ ] The model must have looked the order up first. A cancel proposal naming an
      id it did not read from `get_equity_orders` is the fabrication failure
      mode, on the surface where it has already been measured once.
- [ ] Prompt changes are a **rewrite of the Authority paragraph**, not an
      addition. It currently says "you never will" about cancel specifically.

# Phase 2 — The card and the run — NOT BUILT (option A design)

- [ ] A confirmation card built from parsed values, in `TradingOrderCard`'s
      shape, showing what will be cancelled and what it was for.
- [ ] A third confined run: `[get_accounts, get_equity_orders,
      cancel_equity_order]`. Re-reading the order inside the confined run before
      cancelling is worth it — it is the only place that can verify the id still
      refers to what the card described.
- [ ] Three outcomes, like submission: cancelled, refused, and **unknown**. A
      timed-out cancel run must never be reported as "cancelled".
- [ ] Sentinel: the confirmation and the settlement, with the harness and model,
      exactly as `:order_submit` now records.

# Phase 3 — The surfaces — DONE

- [x] Cancellation **shares** `:order_submit` — decided, not omitted. Same money
      path, same floor, same claude-only pin.
- [x] The banner was **replaced**, not extended: under B, "orders leave only from
      a card you click" was simply false. It now names the split — new orders
      need the card, cancellation does not, and every cancellation is on the
      Security feed.
- [x] The Explore tutorial's "what it can't do" listed cancellation. Moved to
      "what it can do", with the missing card and the audit line both named.

---

## The question to ask every phase

The Trading tab's safety is structural: the model has no verb, so it cannot act.
Every phase should be asked whether it is adding a *verb the operator clicks* or
a *verb the model holds*. A is the former. Anything that drifts toward the latter
should be noticed at the moment it drifts, not after.
