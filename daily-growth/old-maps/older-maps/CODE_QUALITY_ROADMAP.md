# Code Quality and Modularization Roadmap

Generated on 2026-04-28 after a full pass over the owned Go, Solid, TypeScript, and CSS code. Generated Wails bindings, `frontend/dist`, `frontend/node_modules`, and local cache directories are intentionally outside the refactor scope.

## Current Code Shape

Owned code is roughly 9.6k lines. The main maintainability pressure comes from four files:

- `frontend/src/styles.css` - 1,647 lines
- `frontend/src/App.tsx` - 1,429 lines
- `app.go` - 1,093 lines
- `internal/orchestrator/orchestrator.go` - 783 lines

These files are not bad because they are large in isolation. They are risky because each mixes unrelated responsibilities, making behavior harder to test and changes harder to localize.

## Review Findings

### 1. Wails App Binding Is Too Broad

`app.go` currently handles dependency construction, startup/shutdown, chat streaming, slash commands, source management, providers, memory, scheduler jobs, reports, documents, webhooks, delivery, and reactive hooks.

Risks:

- Small UI changes require editing the same file as lifecycle and pipeline wiring.
- Most exported Wails methods cannot be tested independently from the full `App` object.
- DTOs, filesystem access, and domain workflow logic are mixed together.
- `NewApp` wires callbacks inline, which hides the application graph.

Target direction:

- Keep `App` as the Wails binding root, but split methods by feature.
- Move domain workflows into internal services that are usable outside Wails.
- Keep DTO mapping close to bindings, not inside domain packages.

### 2. Frontend Is a Single Component App

`frontend/src/App.tsx` owns layout, navigation, queries, mutations, event subscriptions, form state, and every view.

Risks:

- Form state for unrelated views is always loaded in the root component.
- Queries and mutations are difficult to reuse or test.
- View JSX is hard to scan and easy to break with misplaced edits.
- Runtime-sensitive expressions like `new URL(...)` and markdown rendering are embedded directly in markup.

Target direction:

- Extract a shell layout, route/view registry, feature views, data hooks, and reusable UI components.
- Keep `App.tsx` under 150 lines.

### 3. CSS Is Global and Feature-Blind

`frontend/src/styles.css` contains reset/base styles, layout shell, controls, every feature view, report markdown styles, chat styles, homepage styles, and responsive rules.

Risks:

- Class names are reused across unrelated features.
- Inline styles in JSX bypass the CSS system.
- View-specific changes can regress unrelated views.
- The file is too large to safely reason about visual scope.

Target direction:

- Split CSS by shell, primitives, views, report markdown, and homepage.
- Prefer feature-specific classes and shared utility classes only where intentional.

### 4. Orchestrator Has Too Many Jobs

`internal/orchestrator/orchestrator.go` coordinates queue state, ingestion, analysis workers, prompt construction, provider selection, report extraction, report writing, delivery dispatch, hook dispatch, and frontmatter parsing.

Risks:

- Queue state exists both in memory and in `Library/queue.json`, with different purposes.
- Analysis status updates, worker lifecycle, and report generation are tightly coupled.
- Ingestion code is duplicated between `RunIngest` and `IngestSingle`.
- Report parsing and frontmatter helpers are domain utilities but live inside the orchestrator.
- Comments are stale in places, such as analysis being described as sequential while parallel workers now exist.

Target direction:

- Keep `Orchestrator` as the public facade.
- Extract queue tracking, ingestion planning, analysis workers, prompt building, report writing, and delivery dispatch into small collaborators.

### 5. Persistence Patterns Are Repeated

Several packages implement their own JSON load/save flow: providers, scheduler, webhook, hooks, delivery, queue, sources, reports.

Risks:

- Parent directories are not consistently created before writes.
- JSON ordering is inconsistent for map-backed stores.
- Error wrapping is uneven.
- Atomic writes are not used, so crashes can corrupt config files.

Target direction:

- Add a shared `internal/store/jsonfile` helper with load, save, mkdir, stable ordering support, and atomic write behavior.

### 6. Network Clients Need Clear Boundaries

`provider`, `websearch`, `hooks`, and MCP tooling use package-level or implicit HTTP/process behavior in places.

Risks:

- Harder to test without real network/process calls.
- `http.DefaultClient` has no package-specific timeout policy.
- Some streaming parsers ignore malformed JSON chunks silently.
- MCP process lifecycle lacks stderr capture, startup timeout, and graceful shutdown.

Target direction:

- Introduce small client interfaces for model providers, search, delivery, and MCP process transport.
- Inject `*http.Client` where network behavior matters.
- Add test fixtures for streaming parse edge cases.

### 7. Security and Trust Boundaries Need Explicit Policy

The app intentionally supports shell hooks, webhooks, external provider keys, remote fetching, markdown report rendering, browser cookies, and MCP tools.

Risks:

- Webhook `Secret` exists but is not enforced.
- Shell hook execution ignores errors and output.
- Hook webhook requests ignore response errors.
- Report markdown is rendered via `innerHTML` after `marked(...)` without a sanitization layer.
- Path safety exists for document deletion, but similar path policies are not centralized.

Target direction:

- Define an explicit local-trust policy.
- Enforce webhook secrets.
- Add hook execution result logging.
- Sanitize rendered markdown or restrict generated HTML.
- Centralize path validation for files under `Library`.

### 8. Tests Are Valuable but Sparse

Current tests cover selected ingestion, library, websearch detection, and orchestrator flows.

Risks:

- Wails binding behavior has little direct test coverage.
- Scheduler, webhook, hooks, provider streaming, delivery, MCP, and frontend views have limited coverage.
- UI regressions can compile but still break expected workflows.

Target direction:

- Add package-level tests before each extraction.
- Add frontend component tests or Playwright smoke coverage for primary views.
- Keep every phase behavior-preserving until tests are in place.

## Modularization Roadmap

### Phase 0 - Guardrails Before Refactors

Goal: create safety rails so future modularization is mechanical and reviewable.

Tasks:

- Add documented quality commands:
  - `go test ./...`
  - `go vet ./...`
  - `cd frontend && npx tsc --noEmit`
  - `cd frontend && npm run build`
- Add a repo note that `frontend/wailsjs/**` is generated and should not be hand-refactored.
- Add a short architecture note describing runtime directories: `Library/raw`, `Library/reports`, `Library/queue.json`, `sources.json`, `providers.json`, `mcp.json`.
- Add tests around current behavior before moving code.

Exit criteria:

- No behavior changes.
- All current verification commands pass.

### Phase 1 - Split the Frontend Shell

Goal: reduce `App.tsx` from 1,429 lines to a small app shell.

Proposed structure:

```text
frontend/src/
  app/
    App.tsx
    AppShell.tsx
    navigation.ts
  components/
    Sidebar.tsx
    Header.tsx
    StatusBar.tsx
    EmptyState.tsx
    DataTable.tsx
  features/
    home/HomeView.tsx
    home/WeeklyPlanCalendar.tsx
    chat/ChatView.tsx
    ingestion/IngestionView.tsx
    documents/DocumentsView.tsx
    orchestration/OrchestrationView.tsx
    analysis/AnalysisView.tsx
    models/ModelsView.tsx
    providers/ProvidersView.tsx
    memory/MemoryView.tsx
    scheduler/SchedulerView.tsx
    webhooks/WebhooksView.tsx
    delivery/DeliveryView.tsx
    hooks/HooksView.tsx
    docs/DocsView.tsx
  lib/
    api.ts
    dates.ts
    markdown.ts
    urls.ts
  stores/
    chatStore.ts
    appStatusStore.ts
```

Tasks:

- Extract `Header`, `Sidebar`, and `StatusBar`.
- Extract `HomeView`, including `WeeklyPlanCalendar` and `AnalogClock`.
- Extract one view at a time, starting with passive views (`Docs`, `Models`) before state-heavy views (`Scheduler`, `Providers`).
- Move date helpers into `lib/dates.ts`.
- Move safe hostname formatting into `lib/urls.ts` so `new URL(...)` does not throw during render.
- Move markdown rendering behind `lib/markdown.ts` to prepare for sanitization.

Exit criteria:

- `frontend/src/App.tsx` is under 150 lines.
- Each view owns only its local form state.
- All frontend checks pass after every view extraction.

### Phase 2 - Split Frontend Data Access

Goal: make Wails calls and query keys consistent.

Proposed structure:

```text
frontend/src/api/
  models.ts
  sources.ts
  documents.ts
  queue.ts
  reports.ts
  providers.ts
  memory.ts
  scheduler.ts
  webhooks.ts
  delivery.ts
  hooks.ts
```

Tasks:

- Create typed API wrappers around `window.go.main.App`.
- Create feature hooks such as `useSources`, `useReports`, `useSchedulerJobs`.
- Centralize query keys.
- Normalize mutation invalidation behavior.

Exit criteria:

- Views do not call `window.go.main.App.*` directly.
- Query keys are defined in one place.

### Phase 3 - Split CSS by Ownership

Goal: make styling track component ownership.

Proposed structure:

```text
frontend/src/styles/
  base.css
  shell.css
  controls.css
  tables.css
  report-markdown.css
  features/
    home.css
    chat.css
    ingestion.css
    documents.css
    orchestration.css
    scheduler.css
    providers.css
```

Tasks:

- Move reset, variables, body, inputs, and buttons to `base.css` and `controls.css`.
- Move `.app`, `.header`, `.sidebar`, `.main-content`, `.status-bar` to `shell.css`.
- Move homepage styles into `features/home.css`.
- Move report rendering styles into `report-markdown.css`.
- Remove inline styles from JSX as views are extracted.

Exit criteria:

- No single CSS file exceeds 350 lines.
- Feature styles live next to feature components or in clearly named feature CSS files.

### Phase 4 - Split Wails Bindings by Feature

Goal: keep `App` as the Wails root but stop using one enormous file.

Proposed structure:

```text
app.go                 # App struct and constructor only
app_lifecycle.go       # startup/shutdown/wiring
app_chat.go            # chat and slash commands
app_ingestion.go       # ingestion methods
app_sources.go         # source CRUD
app_documents.go       # documents and pending files
app_reports.go         # report manifest/content
app_providers.go       # provider methods
app_memory.go          # memory methods
app_scheduler.go       # scheduler methods
app_webhooks.go        # webhook methods
app_delivery.go        # delivery methods
app_hooks.go           # reactive hook methods
app_dto.go             # Wails DTOs
```

Tasks:

- Move methods without changing package or exported method names.
- Keep generated Wails binding names stable.
- Extract repeated path construction into `AppPaths`.

Exit criteria:

- `app.go` is under 200 lines.
- No exported Wails method changes name or signature unless intentionally coordinated with regenerated bindings.

### Phase 5 - Create Backend Service Boundaries

Goal: move reusable workflows out of Wails binding methods.

Proposed new packages:

```text
internal/chat/
  service.go
  commands.go
  search.go
internal/documents/
  service.go
  frontmatter.go
internal/planner/
  weekly.go
internal/store/jsonfile/
  jsonfile.go
internal/runtimepaths/
  paths.go
```

Tasks:

- Move slash command parsing and execution into `internal/chat`.
- Move document listing, pending file DTO mapping, frontmatter extraction, and path checks into `internal/documents`.
- Add `internal/planner` before expanding weekly plan features beyond cron jobs.
- Add `internal/runtimepaths` for all paths derived from `saveDir`.
- Add `internal/store/jsonfile` for atomic JSON persistence.

Exit criteria:

- Wails bindings mostly delegate to service methods.
- Domain packages can be tested without Wails runtime.

### Phase 6 - Refactor Orchestrator Internals

Goal: preserve `Orchestrator` as the facade while making pipeline pieces testable.

Proposed structure:

```text
internal/orchestrator/
  orchestrator.go      # facade and constructor
  status.go            # status updates and snapshots
  queue.go             # in-memory queue tracking
  ingest.go            # RunIngest/IngestSingle shared logic
  analysis.go          # RunAnalysis/DrainQueue facade
  workers.go           # worker pool lifecycle
  prompt.go            # analysis prompt construction
  report_parse.go      # <<FILE:...>> extraction
  report_write.go      # report frontmatter/write/manifest
  frontmatter.go       # raw doc metadata extraction or delegate to documents package
```

Tasks:

- Extract shared RSS expansion and fetch/save/queue logic.
- Extract active provider resolution.
- Extract prompt construction and test it with golden files.
- Extract report block parsing and test malformed cases.
- Extract report write plus manifest append into a single unit.
- Replace polling `time.Sleep` worker wait with a queue signal or explicit queue drain model.

Exit criteria:

- No orchestrator file exceeds 250 lines.
- Report parsing, prompt building, queue transitions, and ingest planning have direct tests.

### Phase 7 - Normalize Persistence

Goal: remove hand-rolled JSON persistence from each package.

Tasks:

- Implement `jsonfile.Load(path, defaultValue)` and `jsonfile.SaveAtomic(path, value)`.
- Ensure parent directories are created consistently.
- Use atomic temp-file-and-rename writes.
- Provide stable ordering helpers for map-backed stores.
- Migrate providers, scheduler, webhook, hooks, delivery, queue, and sources.

Exit criteria:

- No package repeats raw JSON load/save boilerplate.
- File writes are atomic where practical.

### Phase 8 - Tighten Security and Reliability

Goal: make local automation power explicit and safer.

Tasks:

- Enforce webhook secrets when configured.
- Capture hook command output and errors.
- Add hook execution result history.
- Add markdown sanitization before report `innerHTML`.
- Add URL formatting helpers that never throw during render.
- Add provider streaming parser tests for OpenAI-compatible and Anthropic chunks.
- Add delivery payload validation per destination type.
- Add MCP client startup timeout, stderr capture, and graceful shutdown.

Exit criteria:

- Security-sensitive features have explicit tests and user-visible error states.

### Phase 9 - Test Coverage Expansion

Goal: protect each extracted module.

Backend tests:

- `internal/chat`: slash command parsing, web search intent, memory commands.
- `internal/documents`: frontmatter parsing, safe path validation, document listing.
- `internal/orchestrator`: queue transitions, worker status, prompt construction, report parsing.
- `internal/scheduler`: add/update/delete/toggle/run-now lifecycle.
- `internal/webhook`: method handling, disabled hooks, secret checks.
- `internal/hooks`: shell/webhook execution result behavior.
- `internal/provider`: streaming parser fixtures.
- `internal/store/jsonfile`: missing files, invalid JSON, atomic save.

Frontend tests:

- Smoke render for each view.
- Homepage weekly calendar placement.
- Chat streaming state transitions.
- Scheduler add/toggle/delete behavior with mocked API.
- Report rendering with sanitized markdown.

Exit criteria:

- Refactors can be reviewed as movement, not behavior changes.

## Suggested Execution Order

1. Split frontend shell and `HomeView`.
2. Split passive frontend views.
3. Split Wails binding files by feature.
4. Introduce shared runtime paths and JSON storage.
5. Extract document/frontmatter service.
6. Refactor orchestrator internals.
7. Add planner package for weekly plans.
8. Harden security-sensitive surfaces.
9. Expand tests and CI-style quality scripts.

## Non-Goals For The First Pass

- Rewriting the app architecture.
- Replacing Wails, Solid, or TanStack Query.
- Changing generated Wails bindings by hand.
- Changing user-visible behavior while moving code.
- Designing the full weekly planning product before the existing app is modularized.
