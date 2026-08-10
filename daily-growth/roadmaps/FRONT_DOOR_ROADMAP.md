# The front door — one sentence, four surfaces

**Split out of `LAUNCH_ROADMAP.md` 2026-08-09 · Status: ACTIVE, nothing done.**

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

**The fastest way to destroy trust is to tell the user to click something that isn't there.**
VI-b and VI-c are hours of deletion and they are the difference between a documentation set
that builds confidence and one that reveals the seams.


---

## The four surfaces that must agree

| Surface | Where it lives | Owner map |
|---|---|---|
| README | this repo | — |
| busterclaw.lol homepage | separate repo | [`WEBSITE_ROADMAP`](WEBSITE_ROADMAP.md) `G-23` |
| The onboarding wizard | `SetupLive` | this map, VI-c |
| The home screen's primary action | `StatusLive` | this map, VI-a |

**Changing one of them alone produces a fifth pitch, not a fix.**
