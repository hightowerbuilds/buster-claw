# iMessage for text; Twilio for voicemail

**Scoped 2026-09-19 · Status: ACTIVE — Phase 0 partial. Read-only connection and
probe implemented; local app/DMG now bundles the pinned adapter and an About-page
readiness check. Release-eval reports database unavailable; desktop read/send
permission acceptance remains open.** See
[feasibility evidence](../../research/imessage-feasibility.md). No channel cutover.

**Operator decision: iMessage replaces Twilio for text. Twilio stays for
voicemail.** This is a replacement of the existing text channel, not a separate
personal-inbox assistant project. Incoming text, conversation history, and text
replies belong to the Messages integration. Voicemail greeting, recording,
transcription, storage, playback, and the existing caller/PIN gates stay on
Twilio and its Supabase relay.

| Channel | Destination | Migration |
|---|---|---|
| Voicemail | Existing Twilio → Supabase → Telephony path | Preserve and regression-test |
| New text conversations | iMessage → local Messages adapter | Replace active Twilio SMS intake and the Phone Texts data source |
| Historical Twilio SMS | Existing local archive | Keep readable and labelled; never replay as new iMessage tasks |

Inbound text is a core milestone. Enabling text-triggered agent work remains an
explicit setting, as does any automatic reply policy. Sending policy, Apple
account identity, and helper distribution below are proposals still to settle.
The next engineering task is Phase 0; editing this map changes no live service.

## 1. What exists in this repository

Read from source on 2026-09-19:

- `lib/buster_claw/commands.ex`, `commands/catalog/`, and `policy_engine.ex`
  provide canonical dispatch, caller tiers, operator rules, and audit hooks.
- `agent/chat.ex` owns conversation state and delegates transport details.
  It is a useful process-lifecycle reference, not the Messages transport itself.
- `dispatch.ex`, `dispatcher.ex`, and `mailman.ex` provide durable work, crash
  recovery, and a supervised intake pattern. The dispatcher already has shift,
  STOP-file, timeout, and run-budget controls.
- `telephony.ex` and `telephony/drain.ex` are the Twilio/Supabase intake path.
  BusterPhone currently has no outbound capability. Preserve the voicemail path;
  replace only active SMS intake. Do not repurpose Twilio identifiers or voicemail
  PIN verification for Apple Messages. Migrate text trust settings explicitly.
- `supabase/functions/sms/index.ts` accepts Twilio SMS; the SMS branch in
  `telephony/drain.ex` dispatches `sms-triage` work. `PhoneComponent` already has
  a Texts filter backed by `Telephony.sms_threads()`. These are cutover points,
  not a reason to replace the shared voicemail infrastructure.
- `browser/bridge.ex` carries native requests through connected LiveViews.
  Background Messages intake must not require an open page or JS hook.
- `desktop/tauri/src/main.rs` starts the packaged Phoenix release. The exact
  parent/child process chain matters when testing macOS permissions.
- `desktop/tauri/Info.plist` explicitly omits Apple Events usage text because
  the app currently scripts nothing. Sending would invalidate that explanation;
  update it with the implementation and establish which executable needs which
  signing settings through the packaged test.
- Sentinel refusals are recorded, but there is no general approval-and-retry UI.
  A send-review flow is new work, not something Pending already supplies.

## 2. Integration route and evidence

**First candidate: an adapter around a pinned `imsg` release.** Its upstream
project describes a Swift CLI that reads the local Messages database and uses
Messages.app automation for ordinary sends. It offers history, watching, and
JSON-RPC. Upstream currently requires macOS 14+. Its advanced features include
private-framework/injection paths; those are outside this roadmap. Verify the
chosen release rather than assuming the moving main branch is the contract.
([Upstream repository](https://github.com/openclaw/imsg))

Upstream documents Full Disk Access for database reads and Automation permission
for ordinary sending. The launch context affects permission attribution.
([Permission guide](https://imsg.sh/permissions.html)) Apple documents a hardened
runtime Apple Events entitlement and an accompanying usage-description key.
([Entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.automation.apple-events),
[usage description](https://developer.apple.com/documentation/bundleresources/information-property-list/nsappleeventsusagedescription))

The documented RPC is newline-delimited JSON over stdio, with request IDs,
responses, and watch notifications. Its distinction between an operation that
never started and one that may have completed is particularly relevant to send
retries. Treat these as versioned adapter inputs, not promises our app has
already verified. ([RPC reference](https://imsg.sh/rpc.html))

All external references were consulted on 2026-09-19. Phase 0 must record the
actual version, source revision, license, checksum, and supported macOS versions.

| Route | Proposed treatment |
|---|---|
| `imsg` ordinary read/watch/send surface | First feasibility candidate; isolate behind a small behaviour |
| App-owned native helper | Fallback if packaging or dependency control makes the candidate unsuitable; requires its own spike |
| BlueBubbles or another server bridge | Deferred alternative; adds another service and credential lifecycle to assess |
| Direct SQL throughout Elixir / UI scripting by coordinates | Do not adopt: spreads schema assumptions or UI fragility through the app |

No change to SIP, injected Messages helper, Apple account credential collection,
or writes to Apple's database is part of this proposal. The local Messages
account is the identity; this does not provision a BusterPhone number.

## 3. First usable scope: replace the Texts channel

1. Connect locally and show precise readiness, including missing dependency,
   unsupported version, denied access, disconnected account, and unavailable Mac.
2. Receive new iMessage text into the Phone Texts surface with durable cursors
   and deduplication. Browse bounded conversations/history. Clearly distinguish
   empty history from unreadable history and keep legacy Twilio SMS labelled.
3. Support text triage through the existing Dispatch system when explicitly
   enabled. Keep task identity and replies tied to the originating conversation.
4. Review the exact recipient address, conversation, service, and body before
   sending one plain-text message. Treat a helper acknowledgment as accepted,
   not proof that a recipient received or read the message.
5. Cut over active text intake from Twilio after the iMessage acceptance walk.
   Verify a real voicemail still records, transcribes, drains, and plays back.

Text replies are a new capability relative to the current intake-only Twilio
implementation. The reviewed-send policy below is a proposed first delivery
mode; automatic replies require a separate decision. Summarization can use the
existing chat, but it is not the reason for this integration or the cutover gate.

Defer attachment download/send, group sends, new group creation, reactions,
edits, unsend, typing indicators, read receipts, SMS/RCS fallback, bulk sends,
remote-Mac hosting, and automatic reply delivery. Read-only group display may
follow once participants are represented accurately. A service we cannot prove
is iMessage is unavailable for sending in this first scope.

The setup page must explain that access is local, but text the operator sends
to a cloud-backed agent can leave the Mac through that agent. Connecting does
not authorize uploading the whole inbox or copying it into workspace markdown.

## 4. Architecture and contracts

Proposed new modules live under `BusterClaw.Messages`, keeping Apple Messages
separate from `BusterClaw.Agent.Message` and `BusterClaw.Telephony`.

```text
LiveView / CLI / agent
        → Commands → PolicyEngine → Messages context
                                     ├─ local drafts + send ledger
                                     └─ supervised adapter → local helper → Messages

helper events → intake → local transaction + cursor → Dispatch → Dispatcher

Twilio voicemail → existing Supabase relay → Telephony → Phone Voicemail
iMessage text    → Messages context                    → Phone Texts
```

- `Messages.Adapter`: status, bounded chats/history, subscription lifecycle,
  and send. Test implementation returns deterministic fixtures and failures.
- `Messages.Connection`: a single supervised local child with framed input,
  request correlation, bounded buffers, timeouts, capped pending requests,
  restart backoff, and shutdown cleanup. Readiness can recover after permissions
  change without pretending an empty response means success.
- `Messages`: validates selection scope, service, stable identities, and limits.
  Never accept arbitrary database paths, shell commands, scripts, or adapter RPC
  method names from a command caller. Spawn with structured arguments; keep
  message text in structured payloads rather than interpolated shell source.
- `Messages.Intake`: core text reception, enabled subscriptions, and durable catch-up.
  Watching is a latency aid, not a substitute for replay and deduplication.
- The Phoenix release is the proposed connection owner. If Phase 0 shows that
  a signed native owner is required, retain these contracts and use a private,
  authenticated local transport. Do not copy the browser's page-dependent bridge.

Proposed SQLite state, created through timestamped Ecto migrations:

| State | Required properties |
|---|---|
| Connection/settings | Enabled state, tested adapter identity, source generation, scope; no Apple password |
| Intake subscriptions | Explicit chat/handle allowlist, activation boundary, independent task permission |
| Cursor + event ledger | Source generation + stable message/event identity, processing state, unique dedupe key |
| Drafts | Exact recipient/service/body, revision, author/source, expiration |
| Send attempts | Draft revision, unique request key, state, timestamps, adapter reference, redacted failure |

Read older history on demand; do not mirror the whole database. Store only text
from enabled conversations needed for the text archive, drafts, or accepted
tasks. Choose and expose a retention policy before persistent intake ships.
Disconnect stops Messages access and leaves Twilio voicemail operating;
“Delete imported data” additionally removes our stored copies, never Apple data.
Explain that Dispatch results or agent transcripts can contain separate copies.

## 5. Authorization and send correctness

Proposed catalog entries below are **not implemented commands**:

| Command | Tier / behavior |
|---|---|
| `messages_status` | Safe; redacted readiness only, no addresses or history |
| `messages_chats`, `messages_history` | Restricted; bounded reads within operator-enabled scope |
| `messages_draft` | Restricted; creates a local draft, no delivery |
| `messages_send` | Restricted and gated; requires a reviewed, current draft revision |

Current `trusted` and `terminal` callers can pass the generic command gate;
therefore **`gated: true` alone cannot enforce a review requirement**. Implement
that requirement in the Messages domain. Draft confirmation must originate from
an authenticated operator UI action, be bound to exact content and recipient,
expire, and be consumed atomically. A generic command must not manufacture its
own confirmation. Verify the chosen UI channel's CSRF, origin, token, and Tauri
ACL protections; do not accept an agent-provided `confirmed: true` boolean.

Draft edits invalidate review. Resolve display names to explicit addresses
before review. Revalidate chat membership and service immediately before send;
reject ambiguity, group changes, or fallback rather than silently rerouting.

Persist a send attempt before invoking the adapter. Use atomic claims to prevent
double-clicks and concurrent requests from sending twice. On timeout or process
death after invocation, mark the attempt **unknown**, not failed/retryable.
Reconcile only with strong transport evidence; body/time matching alone is not
proof. Unknown attempts require operator inspection and an explicit new attempt.
Local idempotency does not create an exactly-once guarantee in Messages.app.

Audit actions and outcomes with identifiers and redacted metadata, not raw
conversation bodies. Revocation/disable must block reads, new intake, and new
sends immediately; queued work rechecks current policy. Already-issued sends
may complete and must not be reported as canceled without evidence.

These controls govern the app's command path. A CLI agent with general shell
access might invoke an installed helper itself. Do not claim a sandbox this
architecture does not provide; review runtime/tool access before promising
strong confinement for unattended work.

## 6. Text reception and inbound task rules

Reception and task execution are separate: a text can appear in the archive
without becoming agent work. The rules below gate task creation, not visibility
of ordinary texts in an enabled conversation.

- Reading permission, trusted task senders, and sending permission are distinct.
  Do not inherit the BusterPhone phone-number allowlist or trust display names.
- Require an enabled direct conversation, explicit sender address, active
  unattended shift, clear STOP file, and a task marker (proposed: `/buster`).
  Ordinary conversation must never become work merely because its sender is known.
- Ignore our own outgoing messages, echo notifications, reactions, historical
  imports, unsupported event kinds, and groups. Preserve phone/email identity;
  do not equate addresses solely because a Contacts name matches.
- Default new subscriptions to an activation cursor, not a whole-history replay.
  Prove there is no gap between capturing that boundary and subscribing. On
  reconnect use bounded catch-up with dedupe. Database/account replacement must
  invalidate cursors and require a new source boundary, not execute old history.
- Persist the event, eligible Dispatch item, and cursor transactionally. A crash
  before commit replays; a crash after commit dedupes. If enqueue fails, do not
  advance past unprocessed work. Bound backlog and report overflow visibly.
- Mark Messages-origin tasks untrusted in Dispatch (`trusted: false`) so the
  existing provenance gate applies. Sender allowlisting permits intake; it does
  not turn quoted/forwarded message content into trusted instructions.
- Suppress loops by source IDs, direction, and recorded send IDs, not just text.
  Recheck subscription and sender eligibility when starting queued work.
- Results initially stay in the app. Automatic acknowledgments or result replies
  require a later, explicit reply policy, recipient binding, budgets, expiry,
  dedupe, STOP checks, and a separately reviewed authorization design. Do not
  silently promote the worker to `trusted` to bypass gated sends.

## 7. Phases and acceptance gates

| Phase | Deliverable | Exit evidence |
|---|---|---|
| 0 — feasibility (IN PROGRESS) | Pinned 0.15.6 candidate, stdio status probe and fixture tests built; launch-owner decision open | Real packaged-app read and one operator-directed send with SIP enabled — NOT YET VERIFIED |
| 1 — adapter | Supervised connection, fake adapter, redacted status, disabled-by-default configuration | Protocol failures, permissions, restarts, and limits tested |
| 2 — text reception | Phone Texts integration, archive/history, subscriptions, durable cursors, Dispatch wiring | New text and eligible task survive disconnect/restart without duplicates or history replay |
| 3 — text replies | Draft/review UI, durable send ledger, command gate, disable controls | Correct-recipient send, concurrency and unknown-outcome tests |
| 4 — Twilio text cutover | Retire active SMS path, retain legacy archive, preserve voicemail | New texts use iMessage; real Twilio voicemail still records, transcribes, drains, and plays |
| 5 — distribution | Signed helper delivery if selected, documentation, support matrix | Clean-machine install/update/revocation and both-channel acceptance walks |

### Phase 4 cutover checklist

1. Inventory SMS-only code/configuration, relay rows still pending, `sms-triage`
   job/skill seeds, trusted text senders, and the Phone Texts presentation.
   Document the cutoff and preserve source IDs on all legacy work.
2. Establish the iMessage address used for text. Do not assume the existing
   Twilio voicemail number can become its Apple identity. Show the text address
   and voicemail number separately in setup, Phone, and contact instructions.
3. Prove iMessage receive/reply and restart recovery before retiring Twilio SMS.
   Keep voicemail credentials, the Twilio number, voice callbacks, recordings,
   transcript handling, shared signature validation, and the relay drain intact.
4. Prepare the SMS webhook/configuration cutover separately from voice settings.
   Reconcile queued Twilio SMS before removing its drain branch; preserve their
   archive and already-created Dispatch work. Do not bulk-delete the shared queue.
5. Remove active Twilio SMS ingestion after reconciliation. Keep a legacy archive
   read path, clearly separated from new iMessage threads. Update SMS-only seeds
   through the existing seed migration machinery; preserve edited operator files.
6. Reconfirm text sender identities for iMessage. Existing voicemail trusted
   callers/PINs remain in place. A phone or email match must not silently grant
   a new channel permission.
7. Verify both channels after deployment, including with Messages disabled or the
   Mac offline: cloud voicemail capture must continue, and local draining resumes
   on recovery. Document rollback of the SMS cutoff without replaying old work.

The cutover changes live Twilio/Supabase configuration only as an explicitly
authorized deployment step, after a concrete configuration diff is prepared.
This roadmap itself authorizes no number release, service cancellation, or send.

### Phase 0 is the next task

Use synthetic messages and an operator-selected test conversation. Record:

1. Adapter version/license/checksum, required OS/architecture, and whether its
   ordinary operations can be selected without activating advanced helpers.
2. The real packaged chain: Tauri → Phoenix → helper (or a measured native-owner
   alternative). Identify the process macOS attributes reads and sends to.
3. Read access denied, granted, revoked, and recovered. No permission change is
   automated; a person grants it in macOS. Record useful error signals.
4. An explicitly approved plain-text test send, Automation denied/granted,
   service selection, unknown-recipient behavior, and send outcome evidence.
5. Restart, sleep/wake, database/WAL changes, helper crash, account unavailability,
   and a missing dependency. Confirm no busy restart loop or false-ready status.
6. Whether a Mac sharing the operator's Apple account distinguishes a remote
   instruction from the operator's outgoing sync. Do not promise text-yourself
   control until this is measured; a separate signed-in account may be needed.
7. Packaging feasibility and macOS compatibility against the existing release
   floor. An optional helper must not silently raise the entire app's minimum OS.

Write the evidence in `daily-growth/research/imessage-feasibility.md`, including
failed cases and the chosen ownership boundary. Terminal success alone does not
close this phase. Do not build the full UI before this gate is resolved.

### Implementation tests

- Pure adapter fixtures: fragmented/malformed/oversized JSON, notifications,
  out-of-order responses, unknown IDs, timeouts, crash recovery, and cancellation.
- Data: non-ASCII and attributed text, missing text, unsupported events,
  duplicate GUIDs, source replacement, cursor gaps, and bounded pagination.
- Policy: every caller tier, outside-scope history, spoofed confirmation,
  modified/expired draft, recipient changes, permission revocation, and STOP.
- Sends: concurrent attempts, crash before/after invocation, unknown disposition,
  no automatic retry, no group or SMS fallback, and redacted audit output.
- Intake: backlog/replay, atomic enqueue/cursor failure, outgoing echoes,
  nonallowlisted sender, task marker absent, revoked subscription, and untrusted
  provenance at execution time.
- Channel split: iMessage failure cannot stop voicemail; SMS retirement cannot
  remove shared relay/voice resources; legacy SMS remains readable; pre-cutover
  queue items are reconciled once; voicemail caller/PIN gates still apply.
- LiveView: setup states, selected conversation, draft editing/review, disabled
  send, pending/unknown status, and disconnect. Follow AGENTS.md component/form
  conventions; use IDs and selectors rather than raw HTML assertions.
- Fake transports and temporary fixtures are the default. Real account/device
  tests are opt-in; CI must never read a developer's Messages database or send.

Run `mix precommit` for implementation changes and record all failures. Run the
packaged gate separately; unit tests do not establish macOS permission behavior.

## 8. File ownership and decisions still open

Expected implementation scope: new `lib/buster_claw/messages.ex` and
`messages/`, new command/catalog modules, Ecto migrations, application supervision,
a Messages-backed Phone Texts UI under `lib/buster_claw_web/`, retirement of the
SMS-only webhook/drain/seed wiring, and corresponding tests. Native helper
ownership, bundle resources, signing, ACLs, and plist edits depend on Phase 0.
Update architecture/trust docs and the generated command documentation when
commands actually ship, not while they are merely proposed.

Before their respective phases, settle:

- Which Apple account/address supplies the replacement text channel, and how
  callers learn that it differs from the retained Twilio voicemail number.
- The operator subsequently requested a build with the adapter: the local app
  now bundles pinned `imsg` 0.15.6. Signed distribution and permission attribution
  remain acceptance work; no system-wide helper installation is required.
- Which conversations may be read, and how long locally imported task/draft
  content is retained. Setup must make both visible.
- Whether automatic replies are wanted. The channel cutover can use reviewed replies;
  automated outbound permission is not implied by enabling intake.

Completion means iMessage supplies the app's text channel, active Twilio SMS
intake is retired, legacy texts remain readable, and Twilio voicemail still
works end to end. Text receipt and eligible tasks survive restart, replies use
the agreed send policy, and disconnecting Messages does not disable voicemail.
No phase is marked shipped on the strength of scaffolding alone.
