# Buster Claw through the eyes of someone new to AI

> ## FILED AND ARCHIVED 2026-08-16 — the findings live in the maps now
>
> **Everything actionable here was distributed the day it arrived**, per the rule
> that a finding lives in a map rather than in the document that found it:
>
> - **P0 "visible stop control"** was already `G-30` in
>   [`TRUST_AND_SUPPORT`](../roadmaps/platform/TRUST_AND_SUPPORT_ROADMAP.md) —
>   **promoted from R2 to R1 and BUILT the same day** (`DutyLive`). This review
>   is cited there as the outside half of the argument.
> - **P0 one sentence · progressive permissions · a first task needing no
>   account** were already `VI-a` / `VI-e` / `VI-f` in
>   [`FRONT_DOOR`](../roadmaps/distribution/FRONT_DOOR_ROADMAP.md).
> - **Three findings were new** and are now `VI-h` (the "everything runs on your
>   machine" claim), `VI-i` (the chat empty state naming Claude when the harness
>   may be codex or opencode — a defect, not a wording preference) and `VI-j`
>   (outcome-based starter prompts).
> - **Cost in human language** was already owned by
>   [`LEFTOVERS_AGENT_CORE`](../roadmaps/agent-core/LEFTOVERS_AGENT_CORE.md)
>   §"Cost aggregation", in more depth than this review has — including the
>   correction that the governor is a **run-count** cap, not a spend cap, so this
>   review's phrasing would have shipped a fresh false claim.
>
> **Five of the seven P0 items were rediscoveries**, by a reader with no access
> to the maps. That is decent evidence the maps point at real things — and equal
> evidence that writing an item down does nothing for it: `VI-a` had been ACTIVE
> with nothing done since 08-09.
>
> **One caution travels with everything here: the reviewer never ran the app.**
> Every claim promoted into a map was re-verified at HEAD first and every quoted
> string is verbatim. The wider recommendations were not, and this repo's
> standing lesson is that *a finding written from reading is a lower bound*.

**Review date: 2026-08-16 · Perspective: a capable computer user who has never used an AI agent · Status: product review, not an implementation plan**

## Executive view

Buster Claw is an impressive agent workstation, but it is not yet an approachable first AI product. Its underlying ideas are unusually strong: the user owns the files, work survives restarts, powerful actions pass through policy, and there is a record of what happened. Those are exactly the qualities a newcomer needs. The trouble is that the interface introduces the machinery before the user has experienced the benefit.

A person new to AI arrives with a simple mental model: type something, receive an answer. Buster Claw asks them to understand Claude Code, a workspace, OAuth, trusted senders, a terminal, a shift, Dispatch, and Sentinel before completing one task. The user is still asking: What can it do? Will it act without me? Where does my information go? How do I stop it? How will I know it succeeded?

My recommendation is not to add a larger tutorial. It is to redesign the ramp around one safe, supervised success. Let the user experience the loop before naming the parts. Once they have watched Buster Claw take a small request, use a tool, produce a result, and show a receipt, the vocabulary becomes an explanation of something real rather than a test they must pass to enter.

## What the app already gets right

The welcome screen is pointed in a promising direction. “Your assistant, reachable by email” is concrete. It describes a relationship rather than a runtime. “Email it like a person” is understandable to someone who has never heard the word agent. The four-step structure, real completion checks, “Skip for now,” one-click Google connection, and persistent finish-setup nudge all reduce the chance of getting stranded.

The application also has persuasive physicality. Files live in an inspectable folder; Chat exposes running and interruption states; Activity can connect a claim to an event; Browser and Terminal make the assistant’s “hands” visible. Strong typography and consistent industrial styling give the product identity.

Most importantly, Buster Claw has real controls underneath the presentation. It distinguishes callers, gates consequential commands, limits unattended runs, guards web requests, encrypts credentials, and records security events. Many AI products try to manufacture trust with friendly copy. Buster Claw has enough actual mechanism to earn trust. The onboarding opportunity is to translate that mechanism into a small number of promises a newcomer can understand and verify.

## The first-run problem

The wizard begins with an email assistant and ends by opening a terminal. That is the first major break in the story. Step two says “no terminal knowledge needed,” but installation opens a terminal with a Homebrew command. The last step again sends the user to a terminal and asks them to press Enter so the assistant can watch the inbox. Meanwhile, the screen they see after setup defaults to Chat, which says no terminal is needed. These are two different front doors: conversational Chat and the unattended email shift. A veteran can understand that they are two modes of the same system. A newcomer will wonder which one is the real product.

The second break is Claude Code. “Your assistant runs as Claude Code” introduces another brand and account without explaining the division of responsibility. Is Buster Claw the AI, or is Claude? Why install both? The product also supports Codex and OpenCode, while the wizard presents Claude as mandatory. The beginner path can recommend one default, but it needs a plain explanation: “Buster Claw provides the tools, memory, and controls. Your chosen AI service provides the intelligence through your existing account.”

The third break is permission timing. Before Buster Claw has demonstrated any value, it asks for broad access to Gmail, Calendar, Drive, Docs, Sheets, Slides, Contacts, and Tasks and tells the user to approve everything. For an AI novice, this is not one convenient connection. It is a trust cliff. The phrase “full access” is especially costly because a newcomer does not yet know which actions require confirmation, what is read automatically, or whether an incorrect answer can become an incorrect edit.

Finally, “Everything runs on your machine” is too easy to misunderstand. The application and local data run on the Mac, but prompts and relevant content are processed by the selected AI provider, while connected actions reach Google, Twilio, GitHub, and other services. A newcomer may interpret “everything” as “my data never leaves this computer.” The honest, confidence-building version is more precise: “Buster Claw stores its records and files on your Mac. When you ask the assistant to work, the needed content is sent to your chosen AI service and any service you connected.”

## The home screen problem

Home is visually confident but cognitively expensive: eight content tabs, a corner widget, browser-style tab strip, and five-item dock. Before the user learns one loop, they meet a notebook, media collections, phone, sound workstation, tutorials, and communications controls. Thoughtful features collectively make the core product look ambiguous.

Chat is the natural beginner surface, but “check your mail, work the queue, or look something up” assumes knowledge of mail access and queues. Offer outcomes instead: “Summarize this document,” “Draft a reply without sending it,” or “Research a question and save the sources.” Say what each uses and whether it drafts or acts.

The current interface also teaches capability more loudly than fallibility. Someone new to AI needs to learn that the assistant can misunderstand, invent facts, or report success imprecisely. They should be shown the distinction between a response and a receipt: the chat message is what the model said; Activity or Security is evidence of what the app actually did. This is one of Buster Claw’s strongest differentiators, yet it is buried in terminology instead of demonstrated during the first task.

Explained is good reference material, but “Learn the machine” and a grid of feature tours describe an encyclopedia, not a ramp. Reference documentation is valuable after curiosity exists. It should not carry responsibility for teaching the first ten minutes.

## Vocabulary and mental models

Buster Claw has rich internal language: agent, harness, CLI, workspace, job, shift, queue, Dispatch, fridge, Sentinel, Clinch, and policy tiers. It is accurate and sometimes charming. Almost none belongs in the first task.

The first layer needs only four ideas:

1. **Assistant:** it can answer and use connected tools.
2. **Review:** it may be wrong; preview important work before acting.
3. **Access:** it can only use accounts and folders the user connects.
4. **Control:** the user can stop it and inspect what actually happened.

The next layer can introduce “workspace” as “the folder where Buster Claw keeps your files,” “trusted contacts” as “people allowed to give your assistant work,” and “on duty” as “keep working when this window is closed.” Queue, Dispatch, harness, policy tiers, and command catalog can remain expert language until the user opens an advanced explanation.

The product should also be consistent about identity. In user-facing copy, “Buster Claw” can be the assistant experience, while “Claude,” “Codex,” or “OpenCode” is the selected AI service. “Agent” can be introduced later as the difference between a chatbot that only answers and an assistant that can use tools.

## Trust must be experienced

The current trust story is technically sophisticated but operationally abstract. “Trusted contacts only,” “audit feed,” and “kill switch” sound reassuring, yet the kill switch is presented as `./buster-claw off-duty` or a `STOP` file. A new user should never need a command to regain control. A persistent, plainly labeled **Stop assistant** control should appear whenever unattended work is active. It should say what will stop, what will finish, and how to resume.

Permissions should be progressive. The first run should require no Google connection. The second might offer Gmail read access for a supervised summary. Sending, deleting, changing calendars, sharing Drive files, and trusting other people should be separate moments with specific explanations. “Connect everything now” saves setup screens but spends trust before it has been earned.

The first consequential action should be a designed teaching moment. Show a short plan, highlight “Draft only” versus “Send,” require confirmation, then open Activity and point to the receipt. If the action is refused, explain that the guardrail worked and offer the safe next step. A newcomer will understand policy after seeing it protect them once.

Cost needs the same treatment. Explain that longer or unattended work uses more of the user’s AI plan, that Buster Claw limits runaway work, and where the limit lives. Prevent the belief that background work is free and infinite without giving a token lecture.

## A better beginner ramp

I would make the first session a seven-stage experience:

1. **One sentence.** “Buster Claw is an assistant on your Mac that can use tools, keep working, and show you what it did.” Use the same sentence in the README, website, wizard, and Home.
2. **Explain the AI provider.** Detect installed options, recommend one, and handle installation and sign-in as one guided state. Do not expose competing model choices yet.
3. **Complete a local demo.** Provide a sample document or staged task that needs no external account. Ask the user to request a summary, rename a file, or produce a small plan.
4. **Preview before action.** Show which file will be read and what will be created. Let the user approve it.
5. **Show the receipt.** After completion, reveal the output and the matching Activity entry. Explicitly say, “This is how you verify what happened.”
6. **Choose one connection.** Ask what the user wants next—email help, calendar help, browser research—and request only the access needed for that outcome.
7. **Offer autonomy later.** After several supervised tasks, introduce trusted senders and on-duty work as an optional upgrade: “Would you like Buster Claw to accept work while you are away?”

This makes Chat the front door and unattended email the earned second act. If email must lead, stage one harmless message, show its request plainly, preview the reply, and hide the terminal. Either can work; teaching both entry points at once cannot.

## Priority recommendations

**P0 — before inviting AI newcomers:** align the one-sentence promise; choose one first-run mode; add a no-integration demo; replace terminal handoffs with guided app states; put a visible stop control in the shell; rewrite the local-data disclosure; and request permissions progressively.

**P1 — make the first week coherent:** add outcome-based starter prompts; unify installation and authentication errors; distinguish model claims from app receipts; add a short “AI can be wrong” review habit; explain cost in human language; and move Security or a simplified activity receipt into the normal completion flow.

**P2 — preserve depth without presenting it all:** reveal Phone, Studio, Pockets, model policy, command catalogs, and unattended orchestration through progressive discovery. Keep Explained as the deep reference library, but create a much smaller “First three things” guide that tracks real completion.

Measure the ramp with five questions after ten minutes: Can the user explain what Buster Claw is? Do they know which AI service powers it? Have they completed one useful task? Can they say what information was used? Can they stop the assistant and verify what it actually did? A successful ramp gets five yeses without the participant opening a manual or typing a shell command.

## Verdict

Buster Claw does not lack onboarding: it has a wizard, manual, Explained section, status, and empty states. The problem is that they teach the builder’s components and workflows. Someone new to AI needs a small request, visible plan, safe action, useful result, and proof.

The app is closest to excellent when it makes agent work tangible: a file appears, a browser moves, a queue survives, a dangerous action stops, or a receipt lands. Build the ramp out of those moments. Do not begin with a glossary or a permission wall. Let the newcomer feel, in order: “I understand what this is; I got something useful; I saw what it touched; I know how to stop it; now I am willing to give it more.”

That would turn Buster Claw from an expert’s powerful private workshop into a credible first encounter with agentic AI—without flattening the depth that makes it special.
