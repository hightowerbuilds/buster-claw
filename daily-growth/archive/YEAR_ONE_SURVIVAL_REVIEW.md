# Buster Claw after one year: the survival review

> ## ARCHIVED 2026-08-16 — one recommendation acted on, the rest deliberately not
>
> **What was acted on.** Its finding that expressive one-off surfaces accumulate
> permanent maintenance cost without demonstrated recurring use ended **Scene3D**
> the same day — −7,264 lines. The review proposed a **Labs** section; the
> operator chose deletion for that one feature and kept Labs for the others.
>
> **What was deliberately not acted on, and why the review supplies the reason
> itself.** It recommends the largest change in it — rebuild Home as **Today**,
> one evidence layer, five areas — and then says, near its end, that the product
> needs local feature-usage evidence before deciding what stays. **That paragraph
> is the argument against the rest of it.** Restructuring navigation for a mature
> user who does not exist yet is the same error as building number provisioning
> before `IX.4` says anyone wants it.
>
> Scene3D was the one item needing no such data: **its own roadmap had recorded,
> in writing, that nobody had wanted it** — two leftovers entries both deferred
> *waiting on evidence* that never came.
>
> **Nothing else here is filed as a map row on purpose.** Its durable findings —
> six partial memories instead of one, Dispatch as a flat queue, the security
> feed training people to clear rather than read, no user-level backup story —
> are real and are all **year-two shaped**. They need the usage evidence the
> review asks for, and filing them as rows today would convert an honest
> hypothesis into a backlog nobody measured.
>
> Re-read this when there are users. It will be worth more then than it was the
> day it was written.

**Review date: 2026-08-16 · Perspective: a committed user twelve months in · Status: product review, not an implementation plan**

## Executive view

After a year, Buster Claw is no longer judged by how much it can do. The user has already opened every tab, connected every account, tried the phone, made a Pocket, played with Studio, watched the browser move, and felt the thrill of emailing an assistant. Capability has stopped being the question. The questions are now: What reliably saves me time? What needs attention today? Can I find what happened six months ago? Will this survive an update, a revoked credential, a provider change, or a new Mac?

This is where the product either becomes infrastructure or remains an impressive workshop. Buster Claw has the foundations of infrastructure: local files, durable queues, policy gates, security records, inspectable tools, and a user-controlled workspace. But its current shape still reflects discovery. Many features have permanent navigation weight whether they become daily habits or one-time experiments. Meanwhile, the boring needs that dominate mature use—retention, retrieval, backup, upgrade, integration health, and exception handling—are spread across the product or missing.

The year-two version should be smaller in presentation and deeper in operation. Chat, unattended work, Browser, Terminal, Workspace, Notes, notifications, and trustworthy receipts are the durable center. Everything else should earn its place through recurring use, become an optional mode, move to Settings or Labs, or disappear. Surviving broad use will require Buster Claw to stop presenting a catalog of inventions and become a calm command center for work, attention, and evidence.

## What the first year actually feels like

The first month is exploration. The user configures an AI provider, chooses a workspace, connects Google or Clinch, establishes trusted senders, changes the appearance, visits Explained, and tests the unusual surfaces. This is when the breadth feels valuable. Pockets, Phone, Studio, Calendar, Browser, Terminal, security controls, and model settings each help define what kind of machine this might become.

By months two and three, usage collapses into a few repeatable loops. The user asks questions in Chat, sends work through Dispatch, checks a result, searches notes, uses Browser or Terminal when the assistant needs hands, and responds to notifications. The product’s value is no longer the number of available modes. It is the reliability of those loops and how little supervision they require.

Around months four through six, accumulation changes the experience. There are archived conversations, completed dispatches, remembered run summaries, browser visits, journal entries, library artifacts, notification rows, security events, and workspace files. Each store makes sense alone. Together they produce a new problem: the user remembers the subject but not which subsystem owns the record. “What did we decide about the invoice workflow?” could require searching Chat, Notes, Memory, Activity, Dispatch, and the filesystem.

By months seven through twelve, operational trust outranks novelty. Credentials expire. An external CLI changes behavior. A Google scope needs reauthorization. A queue item fails while the user is away. Seeded policy or job files remain frozen at their install-time versions because the application only writes missing defaults. The user wonders whether the workspace, database, and Keychain secrets can be restored together. Re-downloading a DMG is no longer a charming update strategy. The mature user’s strongest feelings come from failures, recovery, and proof—not another capability demo.

## Features touched once—and whether that is a problem

Some features are supposed to be used once. Setup, provider sign-in, workspace selection, trusted-contact configuration, recovery-key handling, and account connections create durable state. Appearance and terminal-theme choices can also be “one and done” while still delivering value every day. Low interaction is not evidence for removal when the effect persists or the feature exists for emergencies.

These controls should move out of the daily field of view once complete. Their year-two job is to report health: connected, expiring, degraded, or requiring action. Settings should remember why a permission exists and show the last successful use. Recovery should be rare but rehearsable. A user should be able to run a restore check without suffering a disaster first.

Explained and the Manual are also naturally front-loaded. They belong in Help, searchable from anywhere, not as a permanent peer of Chat on Home. Pockets may be a lasting visual preference, but choosing a shell is configuration, not a daily destination. Keeping these features prominent confuses availability with importance.

## The recurring core

The strongest survivor is the request-to-result loop: ask in Chat or submit unattended work, let Buster Claw use the appropriate tools, then inspect a result and receipt. Dispatch is the differentiated half of that loop because it lets work persist beyond a conversation or window. If Buster Claw becomes indispensable, it will be because this loop is predictable enough to trust with real responsibilities.

Browser, Terminal, and Workspace survive as the assistant’s visible hands. They let a user intervene, understand, and continue work without leaving the environment. Notes also has strong staying power because Markdown, search, backlinks, and user-owned files age better than proprietary conversation views. Notifications can become a genuine daily utility if reminders, timers, and alarms remain easy to clean up.

Activity and Security survive only if they become evidence rather than feeds. A mature user does not want to watch every normal event. They want fast answers to three questions: What happened? What needs me? Why was something allowed or blocked? Receipts should appear beside the work they prove, while the complete audit record remains available for investigation.

## Features that last but begin to suck

The first is history. Buster Claw records generously but retrieves by subsystem. Chat archives conversations; Memory stores headless-run summaries; Sentinel appends security events; Dispatch retains queue history; the journal and Activity reports produce another narrative; Library and the workspace hold outputs. After a year, this is not rich memory from the user’s perspective. It is six partial memories with different search and lifecycle rules.

Browser history already demonstrates a better contract: searchable full text, date-range clearing, and a 10,000-visit bound. Other durable stores need similarly explicit behavior. Security currently reads like an append-only event stream surfaced in a recent list. Conversation closing archives rather than deletes. Notifications and remembered runs have no clear end-of-life experience. Without retention controls, “local first” gradually becomes “locally unknowable.” Broad use needs a universal timeline and search index, plus per-category policies for keep, summarize, export, forget, and delete.

The second is Dispatch as a flat queue. Early on, states such as pending, in progress, completed, failed, blocked, and cancelled are enough. A year of real work adds projects, priorities, dependencies, recurring jobs, stale requests, retries, duplicate submissions, handoffs, and things waiting on a human. The user does not need more queue verbs. They need a work manager that answers what is active, what is late, what failed, what awaits approval, and what can be safely retried. Each item should carry its plan, attempts, outputs, costs, approvals, and final evidence in one place.

The third is the security feed. A permanent count and “acknowledge all” interaction will eventually train the user to clear warnings rather than understand them. Routine successful actions should be quiet. The main surface should contain exceptions: new callers, permission escalation, repeated refusal, unusual volume, changed credentials, or an autonomy boundary being approached. Filtering, grouping, retention, and incident resolution matter more at year one than another raw event type.

The fourth is recovery. Buster Claw’s state spans SQLite in Application Support, a user-selected workspace, and secrets in the macOS Keychain. That is defensible architecture but not yet a user-level backup story. Copying one folder does not recreate the assistant. A year-two product must export a manifest, verify workspace integrity, explain what cannot be exported, restore onto a fresh Mac, and safely reconnect secrets. Backup and restore should be tested product paths, not documentation puzzles.

Finally, integrations become liabilities when their health is invisible. Claude, Codex, OpenCode, Google, Twilio, Clinch, GitHub, and scraped web behavior all change outside Buster Claw’s release cycle. “Configured” is not the same as “working.” Each connection needs a last-success timestamp, a lightweight test, actionable repair, and a clear distinction between authentication, permission, compatibility, network, and provider failure.

## What must be rebuilt

Home needs the largest product rewrite. Eight equal tabs and a separate tool dock make sense while demonstrating scope. They do not reflect a mature user’s day. Home should become **Today**: active work, failures needing attention, pending approvals, upcoming reminders, recent completions, current autonomy status, a visible stop control, and Chat. Modules should appear because the user configured or regularly uses them, not because the binary contains them.

History should be rebuilt as one navigable evidence layer. A global search result should say whether an item is a conversation, request, browser visit, note, file, decision, or security event and link to its source. A single timeline should join the request, tool actions, approval, artifact, and receipt without pretending they are the same kind of data.

Upgrades and support must become first-class. Automatic signed updates, versioned migrations, mergeable defaults, log rotation, crash reporting with consent, a redacted diagnostic bundle, and compatibility checks are not administrative extras after twelve months. They are the difference between a trusted appliance and a repository the user happens to know how to nurse.

Finally, Buster Claw needs local feature-usage evidence: last used, frequency, successful outcomes, and cohort adoption, collected with a privacy-respecting design. The team should not preserve a permanent tab because it was expensive to build or remove it because one reviewer dislikes it. Mature navigation should follow demonstrated habits.

## What should move, narrow, or disappear

Studio, Voice, Cutup, Scene3D, and custom visual experiments should live in Labs unless a measurable cohort uses them weekly. They are expressive and memorable, but for most users they risk becoming year-one souvenirs with ongoing maintenance cost. Studio may even deserve a separate product if its creative users have needs unrelated to unattended knowledge work.

Phone should be a provisioned mode. For someone who owns a number and builds communication workflows, it may be core and worth dedicated navigation. For everyone else, it is a dead promise occupying the main interface. Calendar has a similar test: if Buster Claw’s local calendar does not sustain a distinct workflow beside Google Calendar, the two experiences should consolidate rather than compete.

Pockets and appearance belong in Settings. Explained belongs in Help. Command catalogs, model policy, skill suggestions, and low-level editors belong under Advanced. None must be deleted merely for being specialized, but none deserves universal prominence. Features that cannot justify maintenance through usage, safety, or strategic differentiation should be removed rather than preserved as a museum of capability.

## The app that survives broad use

A viable year-two Buster Claw has five understandable areas:

1. **Today:** Chat, attention, approvals, active autonomy, recent results, reminders, and Stop.
2. **Work:** Dispatch, scheduled and recurring jobs, retries, projects, and complete request histories.
3. **Tools:** Browser, Terminal, and Workspace—the surfaces used to inspect or take over.
4. **Library:** Notes, artifacts, decisions, universal search, and the cross-system timeline.
5. **Connections and Settings:** service health, permissions, backup, recovery, appearance, model policy, Help, Advanced, and Labs.

The survival standard is practical. After a year, a user should find any important prior result in thirty seconds, understand today’s exceptions without clearing a wall of alerts, restore the assistant on a new Mac, receive safe updates, see when a connection last worked, and know that no data store grows forever without consent. Unconfigured products should not appear as empty tabs. Unattended work should always expose its scope and stop control.

## Verdict

Buster Claw’s risk is not that it will do too little. It is that the first year’s experiments will harden into permanent product geography while the accumulated work becomes harder to operate. Broad use rewards a ruthless shift from capability to continuity.

Keep the durable loop: ask, work, verify, remember. Deepen the few tools that support it. Turn configuration into health, feeds into exceptions, histories into memory, and queues into manageable work. Move creative and specialized machinery to the users who actively choose it. If Buster Claw makes those changes, a year of use will not leave behind a crowded control room. It will produce something rarer: an assistant whose history is useful, whose autonomy remains legible, and whose reliability compounds instead of decays.
