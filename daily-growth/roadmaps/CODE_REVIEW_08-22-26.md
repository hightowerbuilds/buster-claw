# Buster Claw critical codebase review — 2026-08-22

**Status:** Open review

**Snapshot:** `e0b7e3b` plus the working-tree changes present during review

**Scope:** 1,349 tracked files and approximately 191,000 lines across Elixir,
HEEx, JavaScript, CSS, Rust, migrations, CI, scripts, tests, and documentation.
The Phoenix and native desktop applications were also run and inspected.

## Blunt verdict

Buster Claw is an exceptionally ambitious, often well-engineered private
laboratory pretending to be a trustworthy autonomous product before its most
important trust boundaries are real.

The code is not sloppy. That would be easier to fix. The problem is that
competent engineering, excellent documentation, thousands of tests, and a
striking interface create more confidence than the actual security model
deserves.

As a personal experimental workstation: impressive.

As an unattended assistant that reads email, inherits the operator's
environment, receives full Google access, and works without permission prompts:
not ready for broad distribution.

## The worst holes

### 1. Critical: the unattended-agent sandbox is mostly prose

The security architecture assumes consequential work passes through
`BusterClaw.Commands`. That surface has thoughtful tiers, provenance, rate
limiting, redaction, and policy checks.

The unattended agent is not actually confined to that surface.

- The runner inherits the user environment and login state, including `HOME`
  and `PATH` ([`agent_runner.ex`](../../lib/buster_claw/agent_runner.ex#L22)).
- Its default is `bypassPermissions`
  ([`agent_runner.ex`](../../lib/buster_claw/agent_runner.ex#L31)).
- Every workspace gets a Claude configuration that permanently enables that
  mode ([`jobs.ex`](../../lib/buster_claw/jobs.ex#L205)).
- Dispatcher provenance only selects an API token. It does not supply
  `dontAsk`, an allowlist, or the existing built-in denial policy
  ([`dispatcher.ex`](../../lib/buster_claw/dispatcher.ex#L303),
  [`dispatcher.ex`](../../lib/buster_claw/dispatcher.ex#L317)).
- The only defense against malicious email content is a sentence in the prompt
  ([`dispatcher.ex`](../../lib/buster_claw/dispatcher.ex#L346)).
- The project's own trust document admits that CLI built-ins sit outside
  URLGuard and Sentinel ([`LOCAL_TRUST.md`](../../docs/LOCAL_TRUST.md#L13)).

The exact exposure varies by backend—Codex is mapped to workspace-write, while
OpenCode can receive `--auto`—but none of this makes `Commands` the universal
authorization boundary advertised by the product.

Worse, Dispatcher treats an entire run as trusted when queued mail came from a
trusted sender, while simultaneously acknowledging that the body is untrusted
data. A trusted sender proves identity, not that every quoted email, attachment,
or forwarded instruction is safe. A compromised account or hostile forwarded
content can steer the model toward Bash, filesystem, network, or the fully
trusted Buster Claw token.

The cynical summary: Buster Claw built a beautifully audited hallway and left a
side door open beside it.

Before unattended work ships, it needs:

- A deny-by-default agent profile with filesystem, shell, and native web tools
  refused.
- An OS-level sandbox or narrowly provisioned worker environment.
- A minimal inherited environment—no login shell and incidental credentials.
- A content-derived provenance model, not merely sender-derived provenance.
- End-to-end hostile email, SMS, webpage, and attachment regression tests.

### 2. Critical: agent-authored HTML can read and exfiltrate workspace files

Workspace HTML is deliberately served verbatim as `text/html`
([`workspace_file_controller.ex`](../../lib/buster_claw_web/controllers/workspace_file_controller.ex#L19)).

The router explicitly records that the route is missing CSP
([`router.ex`](../../lib/buster_claw_web/router.ex#L149)).

The in-app browser's content webview correctly has no Tauri capability, which
prevents direct native command access
([`browser/mod.rs`](../../desktop/tauri/src/browser/mod.rs#L13)). That is good,
but insufficient.

An agent-authored HTML file runs on the same loopback origin as:

- The unauthenticated workspace index
  ([`browser_workspace_controller.ex`](../../lib/buster_claw_web/controllers/browser_workspace_controller.ex#L17)).
- The raw workspace file endpoint.
- History, bookmarks, browser pages, and other local controller surfaces.

A malicious HTML document can recursively enumerate the workspace, fetch
readable files, and transmit their contents outward. `nosniff` does nothing
because the response intentionally declares itself HTML.

"Local trust" makes no sense once an autonomous model can author local files.

Raw HTML should be served from an isolated, unprivileged origin or custom scheme,
with scripts disabled by default. If executable previews are necessary, put them
in an explicit sandbox with no access to local application endpoints.

### 3. High: Sentinel is telemetry, not a dependable audit log

The front page promises that everything changed lands on an auditable feed
([`README.md`](../../README.md#L3)).

The implementation explicitly says audit failure must never prevent the action:

- Sentinel swallows persistence failures
  ([`sentinel.ex`](../../lib/buster_claw/sentinel.ex#L12)).
- Production audit writes run in unsupervised fire-and-forget tasks
  ([`commands.ex`](../../lib/buster_claw/commands.ex#L399)).
- The README quietly admits the limitation later
  ([`README.md`](../../README.md#L32)).

The test run repeatedly logged `DBConnection.OwnershipError` from Sentinel while
remaining green. That was a test-sandbox artifact, but it demonstrates the
contract perfectly: the action can pass and its receipt can disappear.

If receipts are the product's trust differentiator, use a durable outbox or
transaction for consequential operations. At minimum, represent separate
states—requested, authorized, executed, receipt persisted—and retry missing
receipts. Until then, stop saying "everything."

### 4. High: Google authorization begins at maximum privilege

The default OAuth request asks for full Gmail, Calendar, Drive, Docs, Sheets,
Slides, Contacts, and Tasks access
([`oauth.ex`](../../lib/buster_claw/google/oauth.ex#L9)).

Stored scopes cannot narrow that set because defaults are always merged back in
([`oauth.ex`](../../lib/buster_claw/google/oauth.ex#L70)).

Onboarding then instructs the user to approve everything for "full access" and
promises every action will appear in Sentinel
([`setup_live.ex`](../../lib/buster_claw_web/live/setup_live.ex#L373)). The
second promise is already false under audit failure.

This is the worst possible permission sequence: maximum trust before the user
has received one useful result. Progressive scopes should follow actual
outcomes—read Gmail first, draft later, sending separately, and Drive and
Contacts only when requested.

### 5. High: "Requires confirmation" means "dead end"

The policy engine repeatedly describes refusals as surfaced for human approval
([`policy_engine.ex`](../../lib/buster_claw/policy_engine.ex#L9)).

But `Sentinel.Pending` is only a bounded, volatile, 100-item memory list. It has
list, count, clear—and no approval operation
([`pending.ex`](../../lib/buster_claw/sentinel/pending.ex#L1)).

The README is honest that approval does not exist. Therefore:

- `requires_confirmation` is a misleading error name.
- "Pending" actions disappear on restart.
- The user cannot inspect and approve exact immutable arguments.
- The agent cannot resume safely after approval.

Confirmation without an approval workflow is just refusal with aspirational
vocabulary.

### 6. High: onboarding contradicts the product's backend support

The README claims Claude Code, Codex, and OpenCode support. The real runner
detects all three.

First-run setup does not:

- `Setup.agent_cli_available?/0` checks only Claude and Codex
  ([`setup.ex`](../../lib/buster_claw/setup.ex#L74)).
- A detected Codex installation is displayed as "Claude Code installed"
  ([`setup_live.ex`](../../lib/buster_claw_web/live/setup_live.ex#L327)).
- The only installer offered is Claude Code.
- The final step still sends the user to a terminal and tells them to press Enter
  ([`setup_live.ex`](../../lib/buster_claw_web/live/setup_live.ex#L495)).

That is not a "no terminal knowledge needed" onboarding. It is a terminal
workflow hiding behind a wizard.

First success should be a safe local task inside Chat, followed by a visible
result and receipt. Google and unattended email should be an optional second
act.

## Product and feature review

The product has no shortage of capability. It has a shortage of hierarchy.

Two hundred fifteen commands is not inherently a benefit. It is 215 things to
secure, document, test, explain, and support.

The likely core loop is excellent:

1. Ask for work.
2. See a plan or active run.
3. Let the assistant use workspace, browser, and tools.
4. Receive the result.
5. Inspect what happened.
6. Intervene or stop it.

Instead, that core loop competes with Notes, Pockets, Calendar, Phone,
Explained, Activity, Studio, music, notifications, finance, weather, shaders,
custom dock art, browser tabs, terminal tabs, and several overlapping records
of activity.

The app now feels like several products sharing a striking shell:

- An agent orchestration runtime.
- A personal information manager.
- A browser/terminal workstation.
- A sound and voice studio.
- A visual customization system.
- A telephony inbox.

Pockets, shader tooling, Studio, and Phone are interesting. They should live
under Customize, Labs, or optional modules until usage proves they deserve equal
prominence with Chat and Workspace.

The information model is similarly fragmented: chat transcripts, Dispatch
history, Sentinel, Activity, Journal, Library, Notes, browser history,
notifications, and memory summaries all answer variations of "what happened?"
There should be one universal timeline/search surface with filters and retention
controls.

## Design review

The visual identity is excellent. Industrial Claw does not look like a stock
Phoenix or daisyUI application. The orange/black palette, textures, typography,
micro-interactions, shader background, custom artwork, and visible Stand Down
control are memorable.

Unfortunately, the design often performs the brand instead of serving the task.

The native window has:

- A macOS menu.
- A browser-style top application tab strip.
- A bottom application dock.
- Seven Home sub-tabs.
- More rails inside Settings, Explained, Studio, Browser, and widgets.

That is an operating system inside an operating system. The user must understand
route tabs, persistent application tabs, Home tabs, dock destinations, and
component tabs before understanding the assistant.

The Home header devotes prime space to the enormous Buster Claw banner and
weather/contact widget while the actual work surface begins underneath
([`status_live.ex`](../../lib/buster_claw_web/live/status_live.ex#L600)). Branding
and weather win the visual hierarchy over the thing the product exists to do.

The dock contains six destinations, while Home adds seven peer-level features
([`layouts.ex`](../../lib/buster_claw_web/components/layouts.ex#L10),
[`status_live.ex`](../../lib/buster_claw_web/live/status_live.ex#L38)). Settings
inexplicably links to `/appearance`, relying on tab-label grouping to pretend it
is `/settings`.

Legibility is the most concrete design failure:

- The UI contains 473 occurrences of `text-xs` or explicit sub-12px sizing.
- It contains 292 low-contrast `text-base-content/35–60` declarations.
- The critical unattended-status and Stand Down area uses 0.62–0.66rem text
  ([`duty_live.ex`](../../lib/buster_claw_web/live/duty_live.ex#L103)).

On the running app, this looks polished from a distance and exhausting at
working distance. Monospaced uppercase microcopy should be seasoning, not the
default language of the application.

Reduced-motion support exists for several shader surfaces, which is good. But
the Shader Preview still runs an unconditional animation loop, reads layout
every frame, and ignores reduced motion and page visibility
([`shader_preview.js`](../../assets/js/hooks/shader_preview.js#L83)).

## Code and maintenance

The architecture is substantially better than the product sprawl suggests:

- Domain contexts are generally well separated.
- Req is used correctly.
- Command authorization is centralized inside the command surface.
- SSRF handling and redirect pinning are unusually thoughtful.
- Secret redaction has both key- and value-based defenses.
- Path traversal and symlink boundaries receive serious attention.
- Tauri capabilities are deliberately divided.
- The queue, run caps, crash-loop brake, STOP latch, and Stand Down UI are good
  safety mechanisms.

The maintainability problem is weight and historical sediment.

Notable production hotspots include:

- `commands/sound.ex`: 2,464 lines.
- `agent/chat.ex`: 1,510 lines.
- `appearance_live.ex`: 1,064 lines.
- `chat_panel.ex`: 1,001 lines.
- `sound_studio_component.ex`: 973 lines.
- `cli.ex`: 947 lines.
- Rust browser `mod.rs`: 934 lines.
- `chrome.js`: 864 lines.

The file-size gate passes because these existing monoliths are marked `FROZEN`
([`check_file_sizes.sh`](../../scripts/check_file_sizes.sh#L796),
[`check_file_sizes.sh`](../../scripts/check_file_sizes.sh#L1266)). That is a
height restriction introduced after the skyscrapers were built.

Comments and roadmaps are often excellent, but there are far too many production
essays describing deleted phases, old defects, and historical decisions. Worse,
they already disagree:

- The QA backlog says browser-engine tests run nowhere in CI
  ([`QA_BACKLOG.md`](platform/QA_BACKLOG.md#L40)).
- A nightly browser-engine workflow now exists
  ([`browser-engine.yml`](../../.github/workflows/browser-engine.yml#L1)).
- The app currently requires macOS 15
  ([`tauri.conf.json`](../../desktop/tauri/tauri.conf.json#L37)).
- Current distribution roadmaps still repeatedly promise macOS 14.

The docs-drift check passes because it verifies selected CLI references, not
whether the project tells one coherent story.

## What the green checks actually prove

The verification results were genuinely strong:

| Check | Result |
|---|---:|
| Elixir compile with warnings as errors | Pass |
| Format check | Pass |
| Credo strict | Pass, 762 source files |
| Dependency audit | Pass |
| Elixir tests | 4,187 tests + 7 doctests, 0 failures, 22 excluded |
| JavaScript | 348 tests, 0 failures |
| Rust | 46 tests, fmt and clippy pass |
| Docs drift, file-size and cycle guards | Pass |

But the suite is strongest where pure functions and server-rendered behavior are
concerned.

The repository itself acknowledges there are no true end-to-end
LiveView/browser tests, no soak/leak tests, and no prompt-injection regression
suite ([`QA_BACKLOG.md`](platform/QA_BACKLOG.md#L42)). The last one is described
as the highest-value backlog item—and it should be a release blocker, not
backlog.

Sobelow also emitted multiple findings during the review, but `.sobelow-conf`
specifies `exit: false` ([`.sobelow-conf`](../../.sobelow-conf#L1)). Therefore the
CI "security scan" cannot fail the build. Findings should be triaged and false
positives documented, but new high-confidence findings need to block. Right now
it is an advisory report dressed as a gate.

## What should happen before expanding the audience

1. Confine unattended agents at both the tool and OS-process levels. Treat
   content provenance separately from sender identity.
2. Isolate executable workspace HTML from every local application endpoint.
3. Make consequential audit records durable or fail closed when receipts cannot
   be persisted.
4. Add hostile email, SMS, webpage, attachment, and forwarded-content tests.
5. Replace the pending-refusal stub with a durable exact-arguments approval
   workflow—or rename it honestly as blocked.
6. Replace all-at-once Google authorization with progressive scopes.
7. Rebuild onboarding around one safe, local, successful Chat outcome.
8. Collapse navigation around Chat/Work, Workspace, Browser, Terminal, and
   Attention/Receipts. Move novelty into secondary areas.
9. Establish a 12–13px minimum for auxiliary text, improve contrast, and stop
   treating uppercase monospace as body copy.
10. Add real DOM/package-boundary tests and make Sobelow capable of failing CI.
11. Split the large command, chat, UI, and browser modules before adding more
    commands.
12. Replace the documentation archaeology with a smaller canonical product and
    security specification.

## Final conclusion

Buster Claw already has enough features to look finished and enough engineering
discipline to feel safe. That combination is dangerous because the two most
consequential boundaries—what an unattended external agent can do, and what
agent-authored local content can access—are weaker than the surrounding polish
implies.

Fix those boundaries and cut the product hierarchy in half. Underneath the
sprawl is a genuinely compelling application.
