# Browser control — closing out the field test

**Scoped 08-02-26 · Status: CLOSED + ARCHIVED 08-03-26.**

Everything this document existed to settle is settled. Part I's design question
was **decided by the operator and built the same day**; Part II items **2, 3 and
4 are built**; and item **1 — the live signed-in checkout walk — moved to
`LAUNCH_ROADMAP.md` G-40**, because it was never an item an agent could close.
It needs a packaged build and the operator's own session, so it belongs with the
other things that need exactly that, as one sitting rather than four errands.

**The five findings this roadmap inherited from the 07-25 field test are now all
resolved:** the payment gate failing open (fixed 07-25), `text` targeting nearly
buying the wrong size (fixed, `ambiguous_text`), the unnamed stuck-run defect
(fixed 08-02, `f979afd`), `confirm_purchase` having no command surface (shipped
08-03), and `find_elements` ignoring its selector (fixed 08-03).

**Read the decision blocks below before changing this surface** — Part I records
a posture chosen with its cost stated, and items 2, 3 and 4 each record a trap
that was not visible from the item's one-line description.

> ### The one thing to carry forward
>
> **G-40's checkout walk is not optional bookkeeping.** Three capabilities
> shipped on 08-03 that all terminate at the same gate: the agent can file a
> purchase receipt, it can reach signed-in sites unattended, and its egress on
> those sites is newly bounded but unobserved. The gate between them and a live
> payment page is **tested and never walked**, and the field test that started
> this roadmap found that exact gate failing **open**. Nothing further should be
> built on the browser commerce surface until it passes.

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

> ## DECIDED 08-03-26 — Q1 **(b)**, Q2 **(B)**. Built the same day.
>
> **Q1 → (b) a durable workspace record.** Every confirmation appends one JSON
> object to `<workspace>/browser-control/receipts.jsonl` — run id, cart, total,
> confirmation id, capture path, timestamp. Greppable, no schema, no subsystem.
> `Commerce.confirm_purchase/2` returns `recorded: true|false` so a caller is
> never told a receipt was filed when the write failed.
>
> **Q2 → (B) the agent may confirm.** `agent_run_confirm_purchase` ships
> (`:restricted`, catalog + `Commands` delegate + handler), answering the field
> test's Finding 2. The operator chose (B) over this document's (C)
> recommendation with the cost stated: **a receipt filed this way asserts a
> purchase no human affirmed, and a prompt-injected page can reach the verb.**
>
> **What (B) obliged, beyond the verb itself.** Since a receipt is no longer
> self-evidently a person's word, every receipt records `confirmed_by` —
> `:human` (the browse tab's form), `:agent` (the new verb), or `:unknown` for
> an unlabelled caller, which never silently inherits a human's attestation. The
> record is honest about its own provenance rather than pretending the question
> does not exist. The existing guards are unchanged and remain the real floor:
> `awaiting_human` + a non-empty frozen cart, so no agent can conjure a receipt
> for a run that never reached payment.
>
> **A real bug fell out of building it.** `Commerce.capture_confirmation/1`
> trapped exits so "a post-payment engine death cannot also lose the handoff
> confirmation" — but the very next line, `AgentMode.complete/1`, was untrapped.
> A CDP method that *raises* (rather than returning an error) killed the run
> mid-capture and threw away the receipt for money that had already left,
> which is precisely what the trap was written to prevent. Now the receipt is
> built and written **first** and the mode transition is best-effort. Regression
> test: `ExplodingCaptureSession`.
>
> **Both introduction sites were updated**, not one — `introduction.ex` (the
> model's rules) and `explore_panel.ex` (the Explore tutorial, which told the
> user "the agent cannot confirm a purchase"). A decision that leaves either
> stale is worse than no decision.

**The original question and its analysis are kept below, because the reasoning
is why (b) is small and why (B) has a cost worth remembering.**

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

## 1. Walk a live signed-in checkout — **MOVED 08-03 → `LAUNCH_ROADMAP.md` G-40**

*Kept here for its reasoning; the live item is G-40's first line.*

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

## 2. `find_elements` takes a selector — **DONE 08-03**

`page.ex:61` — it enumerated the page and sliced the first 100 interactive elements,
ignoring any selector the caller passes. The field test passed `"input,form"` and
`"#variation_size_name li"` and got the same nav links both times, costing several
wasted round trips. `extract` honors selectors correctly, so the need is covered;
the command is simply misleading as documented.

**Fixed, and it was not the one-line change it looks like.** `Page.find_elements`
now takes `:selector`, and the selector was being dropped in *three* places, not
one: the option never existed on `Page`, and both callers threw their args away —
`agent_mode.ex` (`page_read(session, :find_elements, _args, opts)`) and
`background_flow.ex` (`"find_elements", _args ->`). All three are wired.

**The trap worth recording.** The moduledoc states that `@enumerate_js` is kept
identical between `find_elements` and index targeting *"so an index means the
same element in both"* — `click index: n` resolves `@enumerate_js[n]` against the
**unfiltered** list. So filtering and renumbering would have handed back indices
`click` could not honour: a quieter and worse bug than the one being fixed.
Indices are therefore assigned from the full enumeration **before** the filter
runs, and a test asserts that ordering in the generated JS. Filtering changes
which rows come back, never what an index means.

A malformed selector throws in the page and surfaces as
`{:error, {:js_exception, _}}`, same as `extract/3`.

**Not a bug, for the record:** the live-tab `browser_find_elements` takes
`query`, a case-insensitive *label substring*, and always honoured it. The field
test passed CSS to it, which is a naming trap but not a defect.

## 3. Wire a Keychain-backed `secret_resolver` — **DONE 08-03**

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

> ## DECIDED and BUILT 08-03-26 — yes, unattended runs may sign in.
>
> Asked as a posture question rather than a bug, because everything here worked
> as designed and the "fix" removes a ceiling. **The operator said yes.**
>
> **The store is the database, not a second Keychain integration.** Values live
> in a `browser_secrets` row typed `BusterClaw.Encrypted` — AES-256-GCM through
> `Vault`, keyed from `secret_key_base`, which the Tauri shell **already** keeps
> in the macOS Keychain and injects at boot. So values are Keychain-protected
> through the one key the app already has. Following this roadmap's stated
> precedent literally — new Rust commands holding Keychain access — would have
> added an IPC surface needing `build.rs` registration and ACL lockstep, for no
> more protection than the existing one-key design gives. (That registration is
> exactly what left the co-presence commands ACL-dead for weeks.)
>
> `Encrypted` also fails closed: a blob that will not decrypt loads as `nil`, so
> a rotated key makes a secret *unknown* and fails the resolve rather than typing
> ciphertext bytes into a form.
>
> **The wiring, which is the actual bug.** `agent_run_start` now passes
> `secret_resolver: Secrets.resolver()`. It is a function, not a snapshot: it
> reads on demand, so a secret deleted mid-run stops resolving and no plaintext
> sits in the run's state for the life of the errand.
>
> **The surface, and the invariant.** `browser_secret_put` and
> `browser_secret_delete` are `:restricted` **and `gated`** — an untrusted
> agent's attempt to write or destroy a credential surfaces for human approval.
> `browser_secret_list` is `:safe` and returns **names and notes only**.
> **There is no command that returns a value, and there must never be one** —
> the whole point is a model that can drive a form it cannot read. A test
> asserts the absence of `browser_secret_{get,read,show}` so adding one fails
> there first.
>
> **Item 1 is still not done, and this makes it matter more.** Unattended runs
> can now reach signed-in sites, and the payment gate protecting them has still
> only been tested, never walked.

## 4. Per-host egress levels, with a surface — **DONE 08-03**

`Policy.level_for/2` already takes `:overrides` (`policy.ex:46-53`) — the mechanism
exists and is tested. But `AgentMode` calls `Egress.prepare(host, snapshot)` with no
opts (`agent_mode.ex:458`), so **nothing can ever feed it**. The field test measured
89.8 KB leaving the machine across 41 steps, all at `:full`, zero redactions —
correct per the documented default, and it meant complete Amazon page content
including order history went to the model.

Two halves: pass overrides through from the run, and give them somewhere to come
from. `amazon.com → :structure_only` is the first entry.

**Both halves built, plus the surface.**

- **Through the run.** `AgentMode` freezes `egress_overrides` at start, exactly
  like the scope, and passes them to every `Egress.prepare/3`. Frozen means a
  change cannot alter what a run in flight has been sending.
- **Somewhere to come from.** `Settings`, not a workspace file — a seeded file
  could never be improved on an install that already had one (**V.8**), and this
  is a list we expect to grow. `amazon.com → :structure_only` ships as a **code**
  default so new entries reach every install on upgrade; the operator's stored
  entries layer over them and win, and clearing one returns the host to the
  shipped default rather than to `:full`.
- **The surface.** `browser_egress_level` (`:restricted`) — no args lists what is
  in force and what the operator set; `host` + `level` records one; `level: null`
  clears it. A bad level is refused rather than silently stored as no rule.

**One design correction made mid-build.** The first cut had `AgentMode.init/1`
call `Policy.overrides()`, which put a **database read in run startup** — it
broke every async AgentMode test, and worse, it would have meant a run that
cannot boot when the repo is unavailable. `AgentMode` reads nothing from the
database and should not start now. The lookup moved to `agent_run_start`, which
already runs in a DB context; `AgentMode` falls back to
`Policy.default_overrides/0`, which is pure.

---

## Order

**Part I is done (08-03).** What remains is Part II, unchanged.

**Item 1 is now more urgent than it was, not less.** The agent can file a
receipt; a signed-in checkout walk is the only thing that has ever tested the
gate that stands between it and a live payment page, and it is still untested by
walk. Do it before the next commerce change, not after.

**Everything here is done or moved (08-03).** Part I decided and built; items 2,
3 and 4 built; item 1 → `LAUNCH_ROADMAP.md` **G-40**, where it leads a
consolidated human walkthrough alongside the Chart Build look, the first-open
workspace, and the packaged media walk — one build, every answer.

The order that mattered, in hindsight: **the decision first** (Part I gated
everything and cost one conversation), then the two items that turned out to be
unreachable mechanisms rather than missing features (2 and 4), then the one that
was a posture question wearing a bug's clothes (3). The walk was always last and
always the operator's.
