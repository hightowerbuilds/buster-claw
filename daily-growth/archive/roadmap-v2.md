# Buster Claw: Roadmap v2 — Agentic Capabilities (Updated)

Six phases to bring Buster Claw from a local research tool to an autonomous agentic platform.

---

## Phase 1: Browser Automation

**Goal:** Let ingestion handle JS-rendered pages, paywalled content, and authenticated sources via headless browser.

**Status:** In Progress (Partial)

- [x] 1.1 Headless Browser Backend (`internal/browser/`)
- [x] 1.2 Browser-Backed Ingestion (`internal/ingest/`)
- [x] 1.3 Interactive Browser Tool (`/browse`)
- [ ] 1.4 Anti-Detection (Stretch)

---

## Phase 2: Scheduled Pipelines

**Goal:** Fully autonomous research cycles.

**Status:** Completed

- [x] 2.1 Scheduler Engine (`internal/scheduler/`)
- [x] 2.2 Job Types
- [x] 2.3 Frontend — Scheduler View
- [x] 2.4 Delivery Hooks (File/Webhook)

---

## Phase 3: Subagent Parallelism

**Goal:** Analyze multiple documents simultaneously.

**Status:** Not Started

- [ ] 3.1 Worker Pool Refactor
- [ ] 3.2 Provider-Aware Routing
- [ ] 3.3 Subagent Architecture (`internal/agent/`)
- [ ] 3.4 Coordinator Pattern

---

## Phase 4: Webhook Triggers

**Goal:** External events trigger Buster Claw pipelines automatically.

**Status:** Completed

- [x] 4.1 Webhook Server (`internal/webhook/`)
- [x] 4.2 Hook Configuration
- [x] 4.3 Built-in Hook Templates
- [x] 4.4 Frontend — Webhooks View
- [x] 4.5 Security

---

## Phase 5: Multi-Platform Delivery

**Goal:** Push research digests, reports, and alerts to Slack, Discord, Telegram, or email.

**Status:** Completed

- [x] 5.1 Delivery Interface (`internal/delivery/`)
- [x] 5.2 Platform Adapters
- [x] 5.3 Delivery Configuration
- [x] 5.4 Frontend — Delivery Settings
- [x] 5.5 Report Formatting

---

## Phase 6: Reactive Hooks

**Goal:** Pre/post processing hooks on pipeline events.

**Status:** Completed

- [x] 6.1 Hook System (`internal/hooks/`)
- [x] 6.2 Hook Types
- [x] 6.3 Hook Configuration
- [x] 6.4 Built-in Hook Patterns
- [x] 6.5 Frontend — Hooks View

---

## Implementation Priority

| Phase | Dependencies | Effort | Impact |
|-------|-------------|--------|--------|
| 1 | None | Medium | High — unlocks JS/auth content |
| 3 | Provider system | Medium | Medium — speeds up analysis |

**Current Focus:** Complete Phase 1 Anti-Detection and Phase 3 Subagent Parallelism.
