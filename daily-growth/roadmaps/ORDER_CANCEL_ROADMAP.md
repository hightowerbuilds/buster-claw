# Cancelling an order — the second thing that reaches the broker

**Scoped 08-04-26 · Status: SCOPED, nothing built.**

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

# Phase 0 — Decide (short)

- [ ] **A, B, or C.** Everything else follows from it.
- [ ] If A: does a cancel card carry the same "unknown" outcome vocabulary as a
      submit? (It should — the failure mode is identical.)
- [ ] Is cancellation restricted to `agentic: true` accounts *by us*, or do we
      rely on the broker refusing? Recommend asserting it ourselves, so the
      refusal is legible in our audit trail rather than only in theirs.

# Phase 1 — The proposal

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

# Phase 2 — The card and the run

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

# Phase 3 — The surfaces

- [ ] `ModelPolicy` gains an `:order_cancel` surface, or cancellation shares
      `:order_submit`. Sharing is probably right — same money path, same floor —
      but it should be a decision, not an omission.
- [ ] The read-only banner needs new words. "Orders leave only from a card you
      click" stays true under A and should be *extended* to name cancellation
      rather than left to imply it.

---

## The question to ask every phase

The Trading tab's safety is structural: the model has no verb, so it cannot act.
Every phase should be asked whether it is adding a *verb the operator clicks* or
a *verb the model holds*. A is the former. Anything that drifts toward the latter
should be noticed at the moment it drifts, not after.
