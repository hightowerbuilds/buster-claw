# The front door — one sentence, four surfaces

**Carved out of the launch roadmap 2026-08-09 · Status: ACTIVE, nothing done.**

> ### The one-sentence version
>
> **A user cannot answer "what is Buster Claw?" after a full session, because the
> answer changes with the screen — pick one sentence and make four surfaces say
> it.**

**This is the cheapest high-leverage work anywhere in the release**, because it
is mostly deletion and rewording. Hours of effort, and it blocks `G-23`.

**It is measurable before and after.** `IX.1`, the one-sentence test in
[`DISTRIBUTION_ROADMAP`](DISTRIBUTION_ROADMAP.md), costs an afternoon and is
expected to fail today — that failure is the evidence for doing **VI-a**, and
re-running it afterwards makes the delta the finding.

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

Buster Claw is several products sharing one shell, and a new user cannot form a single mental
model in the first session:

| Surface | What it pitches |
|---|---|
| README | "Agent runtime + audit trail" |
| busterclaw.lol | "A desktop runtime where an AI agent manages your web interactivity" |
| Onboarding wizard | "Your assistant, reachable by email" |
| Home screen | "Chat with Claude" |
| Phone tab | "An answering machine for your agent" (mostly unbuilt) |

**A user cannot answer "what is Buster Claw?" after a full session — the answer changes with
the screen.** The competitor that wins the comparison is the one whose one-sentence pitch
matches its first screen.

**Two agent entry points with contradictory docs.** The terminal `on-duty` loop (durable,
queued, auditable) and the home headless chat (ephemeral, conversational) are two ways to use
the same agent, with different state and different trust presentation. The wizard routes you
to one; the default tab shows you the other. **Pick one as the front door and make the other
an advanced mode.**

### VI.2 — The worklist

| # | Task | Cost |
|---|---|---|
| **VI-a** | **Pick one front door.** Make README + busterclaw.lol + wizard welcome + home primary action say the same sentence | Hours. **Highest leverage in this document.** Blocks **G-23** |
| VI-b | Delete retired features from `user-guide/introduction.md` — Scheduler, Webhooks, Delivery, and Memory are all retired and still documented | Hours |
| VI-c | Fix `user-guide/setup.md`: it describes a 3-step wizard; the app has five steps and never asks for a name | Hours |
| VI-d | Reword the README's bold *"There is no LLM inside Buster Claw"* — technically true, practically misleading when the default tab is a chat box driving the user's Claude. The README also never mentions the home chat at all | Hours |
| VI-e | Least-privilege onboarding: Gmail read-only first, widen later | A day |
| VI-f | Seed a test dispatch item so the first run isn't an empty box | Hours |
| VI-g | Agent-orientation health check: "your agent found its workspace guide" | A day |
| **VI-h** | **Rewrite the wizard's local-data claim.** `setup_live.ex:272` says *"Everything runs on your machine."* The app and its records do; **prompts and the content they touch go to the chosen AI provider, and connected actions reach Google, Twilio and GitHub.** Same class as the 08-10 licence drift — a public claim more generous than the truth | Hours |
| **VI-i** | **The chat's empty state names a harness that may not be running.** `chat_panel.ex:115` reads *"It runs headless **Claude** — no terminal needed,"* but the harness is `ModelPolicy.backend_for(:chat)`, which returns codex or opencode just as readily. The front door names the wrong brand for any operator who switched | Hours |
| **VI-k** | **The wizard still calls the kill switch a CLI command.** `setup_live.ex:268` — *"a kill switch (`./buster-claw off-duty`)"*. Not false (the verb still works), but incomplete since `G-30` shipped the dock brake on 08-16, and it is the exact sentence the novice review pointed at: *"a new user should never need a command to regain control."* **Left untouched deliberately** — another session had an open hunk in that file — so it is one line and one commit | Minutes |
| **VI-j** | **Outcome-based starter prompts.** The same empty state says *"check your mail, work the queue, or look something up"* — three phrasings that each assume a concept (mail access, a queue) the newcomer does not have yet. Offer outcomes: summarise this document · draft a reply without sending it · research a question and save the sources. Say what each uses and whether it drafts or acts | Hours |

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
