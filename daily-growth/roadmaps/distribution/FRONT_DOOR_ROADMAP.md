# The front door — one sentence, four surfaces

**Carved out of the launch roadmap 2026-08-09 · Status: ACTIVE — `VI-a` DONE 08-16.**

> ### The one-sentence version
>
> **A user cannot answer "what is Buster Claw?" after a full session, because the
> answer changes with the screen — pick one sentence and make four surfaces say
> it.**

> ## The sentence, chosen 2026-08-16
>
> ### An assistant on your Mac that uses your tools, keeps working, and shows you what it did.
>
> **Operator's call, assistant-first**, over the incumbent runtime pitch and over
> the wizard's email-first one. The three clauses are not decoration — they are
> the three things this product has that a chat box does not, in the order a
> newcomer can verify them: it *uses your tools*, it *keeps working* when you are
> away, and it *shows you what it did*.
>
> **All four surfaces say it**, and the two that already agreed were the two
> nobody had touched:
>
> | Surface | Where | State |
> |---|---|---|
> | README | `README.md:3` | rewritten, plus the `VI-d` "no LLM inside" reframe → *"You bring the intelligence"* |
> | busterclaw.lol | `buster.md`, `index.html`, `hero.ts` | rewritten in the site repo — title, meta, `sr-only`, `noscript`, body, and the canvas hero. **Built clean, not deployed** |
> | The wizard | `setup_live.ex:256` | rewritten; the three clauses became the three bullets, and `VI-h` closed in the same edit |
> | Home chat | `chat_panel.ex:113` | rewritten; `VI-i` closed in the same edit |
>
> ### It is guarded, and the guard is honest about its reach
>
> **`test/buster_claw_web/front_door_test.exs`** asserts the sentence in all
> three in-repo surfaces, refuses all three retired pitches anywhere in them
> (the deprecated-name idiom from the 08-09 doc-drift comb), and pins `VI-i` by
> refusing the word *Claude* in the chat's empty state.
>
> **It reads source rather than rendering**, because the README is rendered by
> nothing and the two Elixir surfaces carry the sentence as a compile-time
> default — a render test would have passed while the README drifted, which is
> the case that actually happened.
>
> **It cannot reach busterclaw.lol and says so in its own moduledoc.** Four
> surfaces, three guarded. That is the honest number, and the unguarded one is
> the same repository that carried opposite licence terms for two weeks in
> August.
>
> **The guard failed on its first run against real code** — it caught the
> retired queue-jargon phrase quoted inside a comment I had just written
> explaining the retirement. The comment was reworded rather than the guard
> loosened: a retired pitch sitting beside the live one is how a surface ends up
> saying two things, and a comment is one copy-paste from being copy.

~~**This is the cheapest high-leverage work anywhere in the release**, because it
is mostly deletion and rewording. Hours of effort, and it blocks `G-23`.~~ **It
was, and it took an afternoon.** `G-23` is unblocked — the website half is
written and waiting on a deploy.

**It is measurable before and after, and the "before" was never taken.** `IX.1`,
the one-sentence test in [`DISTRIBUTION_ROADMAP`](DISTRIBUTION_ROADMAP.md),
costs an afternoon and was *expected to fail* against the old copy — that
failure was to be the evidence for **VI-a**, with a re-run afterwards making the
delta the finding.

> **The rewrite shipped without it, which costs something real and is recorded
> rather than glossed.** There is now no baseline: running `IX.1` today measures
> whether the new sentence lands, not whether it is *better*. The counterfactual
> is gone for good. It was the right trade only because the old copy contained
> three verifiable falsehoods (`VI-h`, `VI-i`, and the site's four stale claims)
> — you do not A/B-test against a version that lies. **Run `IX.1` on the new copy
> anyway**; a single absolute reading against the 7-of-10 bar is still a real
> gate, it just cannot report a delta.

> ### An outside reader rediscovered five of these on 08-16
>
> The [novice review](../../archive/NOVICE_AI_APP_REVIEW.md) was written by
> someone with no access to this map, and its seven P0 items land on **VI-a**
> (one sentence), **VI-e** (progressive permissions), **VI-f** (a first task that
> needs no account), the terminal handoffs, and the missing stop control — which
> was already `G-30`. Three of its findings were new and are now VI-h, VI-i and
> VI-j.
>
> **That overlap is the useful part, and it cuts both ways.** It is decent
> evidence the map points at real things rather than invented ones. It is also
> evidence that **writing an item down has done nothing for it**: `VI-a` has been
> ACTIVE with nothing done since 08-09, and a stranger walked into the same wall
> a week later. A map is not a mitigation.
>
> **One caution carried with it:** the reviewer did not run the app, and this
> repo's standing lesson is that *a finding written from reading is a lower
> bound*. Every claim quoted in VI-h/i/j was re-checked at HEAD before filing —
> they are verbatim — but the review's wider recommendations were not, and should
> be re-walked in a packaged build before any of them becomes a row here.

---

## Part VI — Focus: the product story

*The cheapest high-leverage work in this document, because it is mostly deletion and
rewording. It is in Part V territory for engineering effort and Part IV territory for impact.*

### VI.1 — The core problem: no front door

Buster Claw was several products sharing one shell, and a new user could not form a single
mental model in the first session. **Resolved 08-16** — kept as the record of what was wrong,
because the table is the argument for the guard that now exists:

| Surface | What it pitched | Now |
|---|---|---|
| README | "Agent runtime + audit trail" | the sentence |
| busterclaw.lol | *this row was itself stale* — by 08-16 the site already said the README's line verbatim | the sentence |
| Onboarding wizard | "Your assistant, reachable by email" | the sentence |
| Home screen | "Chat with Claude" — and it literally said **Claude** while the harness might be codex (`VI-i`) | the sentence |
| Phone tab | "An answering machine for your agent" (mostly unbuilt) | **now built** — inbound live, outbound calling shipped 08-15. Not a front-door surface and deliberately not given the sentence |

**A user could not answer "what is Buster Claw?" after a full session — the answer changed
with the screen.** The competitor that wins the comparison is the one whose one-sentence pitch
matches its first screen.

> **One row of this table was wrong when the map was written and stayed wrong for a week**,
> which is its own small lesson: the busterclaw.lol row described a pitch the site had already
> replaced. **A map that records another surface's copy is a copy of a copy** and goes stale
> silently — the reason the fix is a *test*, not a corrected table.

**Two agent entry points with contradictory docs.** The terminal `on-duty` loop (durable,
queued, auditable) and the home headless chat (ephemeral, conversational) are two ways to use
the same agent, with different state and different trust presentation. The wizard routes you
to one; the default tab shows you the other. ~~**Pick one as the front door and make the other
an advanced mode.**~~

> **The chosen sentence dissolves this rather than deciding it, and that was deliberate.**
> *"Uses your tools, keeps working, shows you what it did"* is true of both entry points —
> "keeps working" is the shift, "uses your tools" is the chat, and the receipt is common to
> them. So neither had to be demoted to an advanced mode, and the wizard can still route to
> email while Home still opens on Chat without the two contradicting each other.
>
> **What remains open is navigation, not story.** A newcomer still meets both paths; they just
> no longer hear two different claims about what the product is. If the two entry points prove
> genuinely confusing in `IX.3`, demoting one is still available — it is now a UX decision
> rather than a positioning one.

### VI.2 — The worklist

| # | Task | Cost |
|---|---|---|
| **VI-a** | ~~**Pick one front door.** Make README + busterclaw.lol + wizard welcome + home primary action say the same sentence~~ **DONE 08-16.** All four say it, and a guard keeps the three in this repo from drifting | ~~Hours~~ **Done** |
| VI-b | Delete retired features from `user-guide/introduction.md` — Scheduler, Webhooks, Delivery, and Memory are all retired and still documented | Hours |
| VI-c | Fix `user-guide/setup.md`: it describes a 3-step wizard; the app has five steps and never asks for a name | Hours |
| ~~VI-d~~ | **DONE 08-16, with VI-a.** *"There is no LLM inside Buster Claw"* became **"You bring the intelligence"** — same fact, stated as what the user supplies rather than what the app lacks — and the README's opening now leads with Chat, which it had never mentioned | Hours |
| VI-e | Least-privilege onboarding: Gmail read-only first, widen later | A day |
| VI-f | Seed a test dispatch item so the first run isn't an empty box | Hours |
| VI-g | Agent-orientation health check: "your agent found its workspace guide" | A day |
| ~~**VI-h**~~ **DONE 08-16** — rewritten with the welcome step. **Was:** rewrite the wizard's local-data claim. `setup_live.ex:272` says *"Everything runs on your machine."* The app and its records do; **prompts and the content they touch go to the chosen AI provider, and connected actions reach Google, Twilio and GitHub.** Same class as the 08-10 licence drift — a public claim more generous than the truth | Hours |
| ~~**VI-i**~~ **DONE 08-16** — the empty state names no harness, and `front_door_test.exs` refuses the word. **Was:** the chat's empty state names a harness that may not be running. `chat_panel.ex:115` reads *"It runs headless **Claude** — no terminal needed,"* but the harness is `ModelPolicy.backend_for(:chat)`, which returns codex or opencode just as readily. The front door names the wrong brand for any operator who switched | Hours |
| **VI-k** | **The wizard still calls the kill switch a CLI command.** `setup_live.ex:268` — *"a kill switch (`./buster-claw off-duty`)"*. Not false (the verb still works), but incomplete since `G-30` shipped the dock brake on 08-16, and it is the exact sentence the novice review pointed at: *"a new user should never need a command to regain control."* **Left untouched deliberately** — another session had an open hunk in that file — so it is one line and one commit | Minutes |
| ~~**VI-j**~~ **DONE 08-16** — the empty state now offers summarize / draft-without-sending / look-up-and-check-Activity. **Was:** outcome-based starter prompts. The same empty state says *"check your mail, work the queue, or look something up"* — three phrasings that each assume a concept (mail access, a queue) the newcomer does not have yet. Offer outcomes: summarise this document · draft a reply without sending it · research a question and save the sources. Say what each uses and whether it drafts or acts | Hours |

**VI-h, VI-i and VI-j came from the 08-16 novice review** and are filed here
rather than in it, per the rule that findings live in maps. They are all the same
shape as VI-a — the front door telling a story the app does not match — which is
why they are rows in this table and not a document of their own.

> **VI-i is a defect, not a wording preference**, and worth separating from its
> neighbours for that reason: the sentence is false whenever the operator has
> switched harness, and nothing tests it. It is the review's identity confusion —
> *"Is Buster Claw the AI, or is Claude?"* — arriving as a literal bug rather
> than a matter of framing.

**The fastest way to destroy trust is to tell the user to click something that isn't there.**
VI-b and VI-c are hours of deletion and they are the difference between a documentation set
that builds confidence and one that reveals the seams.


---

## The four surfaces that must agree

| Surface | Where it lives | Owner map |
|---|---|---|
| README | this repo | — |
| busterclaw.lol homepage | separate repo | [`WEBSITE_ROADMAP`](../website/WEBSITE_ROADMAP.md) `G-23` |
| The onboarding wizard | `SetupLive` | this map, VI-c |
| The home screen's primary action | `StatusLive` | this map, VI-a |

**Changing one of them alone produces a fifth pitch, not a fix.**
