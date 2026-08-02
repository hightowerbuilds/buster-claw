# Browser control — closing out the field test

**Scoped 08-02-26 · Status: ACTIVE · Small on purpose.**

The 07-25 field test (`~/Desktop/browser-control-field-test-2026-07-25.md`) ran the
whole Agent Mode stack at a real, logged-in, adversarial commercial site and came
back with five findings. Three are closed:

- **Finding 1** (payment gate failed open on Amazon) — fixed in the 07-25 gate
  rewrite; `Scope.payment?/1` now checks host *and* path.
- **Finding 4** (`text` targeting nearly bought 54" laces instead of 45") — fixed;
  matching resolves exact before substring and refuses with `ambiguous_text`
  rather than silently taking the first of many.
- **The defect the report described but did not name** — a run had no way to
  *finish*. `AgentMode.complete/1` existed with exactly one caller, behind the GUI
  and behind a non-empty cart, so a non-commerce run could never reach `done`; it
  sat in `agent_working` holding a Chromium window open until someone stopped it,
  and went into the record as halted. That is what "Final mode: `stopped` — not
  `done`" meant. Fixed 08-02 (`f979afd`): `agent_run_finish`, `agent_run_resume`,
  and a browse-tab banner that a live run outranks and a terminal one can leave.

What is left is one genuine design question and four mechanical items. This
document exists mostly for the question; the items are here so they stop living
in `LEFTOVERS.md`, where a thing waiting on a decision does not belong.

---

# Part I — The question: confirm, or not confirm?

**This is the decision to make. Everything in Part II is smaller than it.**

## What confirming is

After the human pays in the real window, `Commerce.confirm_purchase/2`
(`commerce.ex:58`) captures the confirmation page to
`<workspace>/browser-control/captures/`, assembles a receipt (run id, frozen cart,
confirmation id), and completes the run. It refuses unless the run is in
`awaiting_human` with a non-empty cart. **Only the browse tab's form can call it**
(`browse_live.ex:85`). The field test filed that as Finding 2 — *"`confirm_purchase`
has no command surface"* — and asked for `agent_run_confirm_purchase`.

We did not do that, and the introduction now tells the model the opposite: *"You
cannot confirm a purchase; do not try, and do not offer to."* That was a defensible
call made in passing. It deserves to be made deliberately, because two things have
changed since the report.

## What changed, and why the question is now live

**1. The run is no longer stuck, so the pressure is off — and that is a trap.**
`agent_run_finish` means a commerce run can now end cleanly without anyone
confirming anything. The stuck-run symptom that made this urgent is gone. What
remains is quieter: an errand where money changed hands can now be marked `done`
with **no capture and no receipt**, and nothing will complain.

**2. The ledger the receipt was meant to reach no longer exists.** The report's
stated consequence was *"No `browser_agent` Wallets transaction was written… the
purchase is invisible to the ledger."* The wallets subsystem was **deleted** in
`db10a58`. So today, confirming produces a PNG on disk and a map returned to the
caller — `Commerce`'s own docstring says it plainly: *"The receipt is returned to
the caller and is not persisted as a financial ledger."*

That reframes the whole question. **Who may confirm** depends entirely on **what
confirming produces**, and right now it produces almost nothing durable.

## So there are two questions, in order

### Q1 — What should a confirmation produce?

- **(a) What it does now** — a capture on disk, a receipt to the caller, mode
  `done`. Honest, cheap, and forgettable: nothing indexes it, nothing can answer
  *"what has this agent bought?"*
- **(b) A durable record in the workspace** — the capture plus a line in a plain
  markdown/JSONL record under `browser-control/`, greppable like everything else.
  No schema, no subsystem, consistent with the product's one durable promise.
- **(c) Rebuild a ledger** — bring back something wallets-shaped. Large, and it was
  deleted for a reason; needs its own justification, not this roadmap's.

**Recommend (b).** It is the smallest thing that makes "what did it buy" answerable,
and it does not resurrect a subsystem we chose to delete.

### Q2 — Who may confirm?

- **(A) Human only — status quo, made deliberate.** The confirmation is the human's
  attestation that they paid. *Cost:* no receipt exists unless someone is sitting in
  the browse tab. An errand driven from the terminal, from on-duty, or from a phone
  request can complete but can never be receipted.
- **(B) The agent may confirm** — `agent_run_confirm_purchase`, as the report asked.
  *Argument for:* it spends nothing. The money already left, by hand, in the real
  window; this only writes down what happened, and the agent is the one that can
  read the order number off the page. *Cost:* the record then asserts a purchase no
  human ever affirmed, and a prompt-injected agent can fabricate one.
- **(C) The agent proposes, the human attests.** The agent captures the page and
  drafts the receipt — order number included, because it can read it — and the tab
  shows it pre-filled. The human's part stays a click, but stops being
  transcription. *Cost:* one more state to carry.

**Recommend (C), with (b).** The thing worth protecting is the human's attestation;
the thing worth deleting is the typing that makes people skip it. (B) stays
available later if genuinely unattended commerce ever becomes a product, and that
should be its own decision with its own justification.

**Whatever is chosen, the introduction must change with it** — it currently states
the (A) posture as a rule to the model, and a decision that leaves that text stale
is worse than no decision.

---

# Part II — The four mechanical items

Inherited from `LEFTOVERS.md` on 08-02; deleted from that file, because two
documents tracking one item is how they start disagreeing.

## 1. Walk a live signed-in checkout — **HIGH**

The acceptance test for the payment gate, left PARTIAL on 07-25. After the gate
rewrite, Amazon's live entry point is confirmed gated and the `/gp/buy/` funnel is
confirmed gated **by test** — never **by walk**, because that funnel is only
reachable from a logged-in session. Drive one real Agent-Mode commerce run to a
signed-in checkout and confirm the run halts.

**Why it stays HIGH.** This is the one item here that is safety-adjacent rather than
tidy. The field test found the gate failing *open* on exactly this funnel; the fix is
tested but unwalked, and the cost of being wrong is an agent standing on a live
payment page in the only mode that permits acting. Needs the operator's own
signed-in session; nothing in the repo can do it.

## 2. `find_elements` takes a selector

`page.ex:61` — it enumerates the page and slices the first 100 interactive elements,
ignoring any selector the caller passes. The field test passed `"input,form"` and
`"#variation_size_name li"` and got the same nav links both times, costing several
wasted round trips. `extract` honors selectors correctly, so the need is covered;
the command is simply misleading as documented.

## 3. Wire a Keychain-backed `secret_resolver`

`agent_mode.ex:218` defaults to `fn _ -> :error end` and `agent_run_start` never
passes `:secret_resolver`, so every `$secret.<name>` fails. `SecretRef` is pure,
correct and tested; the plumbing that consumes it shipped. **What was never built is
the store behind it.**

Consequence: no unattended run can touch a site requiring sign-in — logins must be
typed by the operator into the headful window. That is *safe*, and arguably safer
than the alternative; it is a ceiling, not a bug. **Precedent to follow:** the Tauri
shell already owns a Keychain-stored key and injects it into Elixir
(`recovery.ex:6`) — the Rust side holding Keychain access is the established shape,
not a new one to invent.

## 4. Per-host egress levels, with a surface

`Policy.level_for/2` already takes `:overrides` (`policy.ex:46-53`) — the mechanism
exists and is tested. But `AgentMode` calls `Egress.prepare(host, snapshot)` with no
opts (`agent_mode.ex:458`), so **nothing can ever feed it**. The field test measured
89.8 KB leaving the machine across 41 steps, all at `:full`, zero redactions —
correct per the documented default, and it meant complete Amazon page content
including order history went to the model.

Two halves: pass overrides through from the run, and give them somewhere to come
from. `amazon.com → :structure_only` is the first entry.

---

## Order

**Part I first, and it is a conversation, not a build.** Q1 then Q2; both are
cheap to decide and neither is cheap to get wrong later, because the introduction
teaches the model whichever answer we pick.

Then **1** (it needs the operator, and it is the one with a safety cost), then
**4** (small, and the only item that changes what leaves the machine), then **2**
and **3** whenever they are convenient. 3 is the largest thing here and the least
urgent: the ceiling it removes is one we are currently happy to have.
