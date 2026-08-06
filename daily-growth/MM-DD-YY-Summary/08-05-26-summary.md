# 08-05-26

One feature, and it is the one that changes what this app is willing to let a
model do. The Trading chat can now cancel a resting order on its own say-so.

The through-line is not the feature. It is that **the operator overruled the
recommendation, and the right response was to build their choice properly rather
than to build it grudgingly** — which meant working out what the choice actually
costs and paying for the parts that could still be paid for.

## The recommendation, and the decision against it

The roadmap laid out three shapes and recommended **A**: mirror placement — a
` ```cancel ` fence, a confirmation card built from parsed values, a third
confined run. Every existing property survives; cancel simply joins place as a
thing the operator clicks.

The operator chose **B**: put the cancel tool in the chat's own allowlist.

Both are in the roadmap. The losing option was not deleted, because the record of
*why* a shape was rejected is worth more later than the tidiness of only
documenting what shipped.

### What the choice traded

This tab's safety was **structural**. `@read_tools` was eleven `get_*` verbs
behind a three-part confinement that had been probe-verified tool by tool. The
model was not asked to behave well — it was handed nothing to misuse. Under B it
holds one write verb and is told how to use it. **The prompt is the guard rail;
there is no second one.**

That is worth stating flatly because the one measured failure on this surface was
*silent fabrication* (07-28: a cheaper model invented a broker answer rather than
erroring). The four new rules — read the id from `get_equity_orders` first, stop
and ask when several orders could match, agentic accounts only, report UNKNOWN
when the tool does not confirm — are instructions to a model, not constraints on
one. They are the honest best available under B, and they are not the same kind
of thing as an allowlist.

### What the choice did not have to trade

The **record**. `:audit_tools` hands the cancel verb to `Agent.Chat`, which posts
a Sentinel `:outbound_send` line the moment the tool is called, with its
arguments, as it happens rather than at the end of the run. The operator gave up
the click; they did not have to also give up the ability to see what was done in
their account, so they did not.

The hook is generic on purpose: `Agent.Chat` does not learn what a broker is, only
that some verbs are worth recording on use. Trading supplies the list.

### The guarantee that could not be kept

Under A, cancellation would have been scoped to `agentic: true` accounts by us.
Under B the tool call is the model's, so we ask in the prompt and rely on
Robinhood refusing the rest. **That is a real difference from placement and is
recorded as one** rather than described as equivalent. It is the one thing the
chosen shape genuinely cannot do.

## Rewriting promises instead of appending to them

The Authority paragraph said: *"You have NO order tool and you never will in this
conversation. You cannot place, amend, or cancel anything."* It named cancel
specifically. Shipping the verb under that sentence would have been the worst of
both — a model holding a capability its instructions deny.

The Trading banner said *"the assistant proposes, it never sends."* True until
this shipped, and then the same kind of lie about a different verb that the
banner had already told once before about placement — the copy that said "Buster
Claw cannot place, amend, or cancel Robinhood orders" for a full day after the
confirm card landed. **Twice now, that sentence has outlived its truth.** It now
says which half still needs a click and where the record of a cancellation lives.

Three existing tests asserted the old boundary. They were **repointed rather than
deleted**, and the allowlist one is stronger for it: it now asserts the chat
reaches EXACTLY ONE non-`get_` tool, so a second write verb appearing later is a
change somebody has to decide rather than notice.

## A hook that survived a refactor, and the test that proved it

The audit hook landed in `agent/chat.ex` — a file the other session was
simultaneously rewriting, extracting a `ChatTransport` boundary (+261/−64). The
commit was deliberately held rather than sweep their unfinished work into it, and
an `AUDIT_HOOK_TO_REAPPLY.txt` was written to the scratchpad in case a `git
checkout` discarded it, as one had discarded the Settings picker the day before.

It survived. But *present* is not *called*, and the refactor rewrote precisely the
receive path the hook sits on. So the end-to-end test was written and then
**probed by disabling the hook**: both positive cases fail without it.

That mattered more than usual. Two user-facing sentences — the Trading banner and
the Explore tutorial — now tell the operator that every cancellation is recorded.
A hook that was present but no longer called would have made both of them false,
silently, on a money path.

## The stale claim in yesterday's own summary

The 08-04 summary closed with "the sweep does not read the watchlist". It was
true when written and wrong four hours later, when the sweep was wired the same
night. Corrected today — the third such correction in three days, in a document
whose own stated theme is claims going stale.

The fix records what shipped: tracked symbols are named in the sweep prompt
because the agent cannot discover them, and the ten-symbol cap finally has its
explicit answer — **holdings win**, largest position first, anything dropped named
in `"skipped"`. The backfill queue's order is a spending decision rather than a
sort: one run a day at ~$0.57 means the list is the order the operator's money
gets spent, so benchmarks precede a watchlist that would otherwise delay the
baseline every comparison chart needs.

## The day in one line

**When the operator overrules you, the job is to make their choice work, name
what it costs in the code that ships it, and pay for whatever can still be
paid for.** The click was not recoverable. The record was, so it was kept. The
agentic-account guarantee was not, so it is written down as lost rather than
quietly implied to still hold.
