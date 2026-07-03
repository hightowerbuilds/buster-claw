# Buster Claw Code QX Report

Generated: 2026-04-30 23:48 PDT

This report is an original pass over the current codebase, using `CODE_QUALITY_ROADMAP.md`, `docs/QUALITY.md`, `docs/ARCHITECTURE.md`, and `ANALYSIS.md` as context. It reflects the code as it exists now, not only the older roadmap state.

## Executive Summary

Buster Claw is past the early "single-file frontend" stage, but it is still carrying several concentrated quality risks. The app has a clear product shape and the package layout is mostly sensible: Wails facade, Go domain packages, Solid feature views, local library storage, provider abstractions, automation, and delivery. The main issue is not feature absence. The main issue is that several feature-complete areas still lack hard boundaries around reliability, trust, persistence, and testability.

Current verification status:

- `go test ./...`: passed.
- `cd frontend && npx tsc --noEmit`: passed.
- `cd frontend && npm run build`: passed.

Current hotspots by size:

- `frontend/src/styles.css`: 1874 lines.
- `app.go`: 1185 lines.
- `internal/orchestrator/orchestrator.go`: 906 lines.
- `frontend/src/app/useAppController.ts`: 493 lines.
- `internal/provider/provider.go`: 393 lines.

The build is healthy, but the risk profile is still medium-high because the highest-risk behaviors are runtime behaviors: long-running analysis, streaming model responses, webhook triggering, shell hooks, external provider streaming, MCP process management, and unsanitized markdown rendering.

## What Improved Since The Prior Review

The older quality roadmap correctly identified a monolithic frontend. That has improved. `frontend/src/App.tsx` is now a small shell that delegates to `AppViews`, `Sidebar`, `Header`, `StatusBar`, and feature view modules.

The backend also has more package-level test coverage than the older analysis described. Current owned tests exist for:

- `internal/calendar`
- `internal/ingest`
- `internal/library`
- `internal/orchestrator`
- `internal/websearch`

The app now has more domain breadth: calendar, delivery, webhooks, hooks, provider routing, and a richer document workflow are present. The tradeoff is that orchestration and binding code grew around those features instead of being separated into smaller service boundaries.

## Critical Findings

### 1. Analysis Can Deadlock After Multiple Failures

Location: `internal/orchestrator/orchestrator.go`

`RunAnalysis` creates `errCh := make(chan error, workerCount)` and workers send each analysis error into that channel. The channel is only drained after `wg.Wait()`.

With `workerCount == 1`, the first failed document fills the buffer. A second failed document blocks forever on `errCh <- err`, which prevents the worker from returning, which causes `wg.Wait()` to block forever. With more workers, the same failure appears once failures exceed the buffer.

Impact:

- A bad batch of documents can hang analysis.
- The UI can remain busy indefinitely.
- Scheduled or webhook-triggered analysis can wedge silently.

Fix:

- Do not send every worker error into a bounded channel that is not concurrently drained.
- Store only `lastErr` under a mutex, or make `errCh` length equal to the maximum queue length, or drain it in a separate goroutine.
- Add a test that queues at least two documents that force `analyzeOne` to fail and asserts `RunAnalysis` returns.

### 2. Markdown Rendering Has No Sanitization Boundary

Locations:

- `frontend/src/lib/markdown.ts`
- `frontend/src/features/analysis/AnalysisView.tsx`
- `frontend/src/features/documents/DocumentsView.tsx`

`renderMarkdown` returns raw `marked(markdown)` output, and the views inject it with `innerHTML`. Raw documents and reports can originate from fetched web content or model output, so this is a direct trust boundary.

Impact:

- Scriptable HTML or unsafe attributes can render inside the desktop app.
- A malicious source document or provider response can affect the UI context.

Fix:

- Add an HTML sanitizer such as DOMPurify for rendered markdown output.
- Prefer a single `MarkdownArticle` component so no feature view can bypass the policy.
- Add a fixture test or Playwright smoke check with hostile markdown.

### 3. Webhook Secrets Exist In The Model But Are Not Enforced

Locations:

- `internal/webhook/webhook.go`
- `app.go`

`webhook.Hook` has a `Secret` field, but `handleHook` never checks it. `AddWebhook` also does not accept or persist a secret from the frontend binding.

Impact:

- Any local process can POST to enabled hooks on `127.0.0.1:9090`.
- Hooks can trigger ingestion, analysis, full runs, or custom commands without authentication.
- The existence of a `Secret` field creates a false sense of protection.

Fix:

- Require a secret for command/full/analyze actions, or explicitly label unauthenticated hooks as local-only.
- Enforce a header such as `X-Buster-Claw-Secret` using constant-time comparison.
- Add tests for missing, wrong, and correct secrets.

### 4. Shell Hooks Are Powerful But Unobservable

Location: `internal/hooks/hooks.go`

Shell hooks run through `bash -c`, receive JSON on stdin, and discard errors/output. Webhook hooks also ignore request creation and response errors.

Impact:

- A misconfigured hook looks successful.
- A slow hook can block synchronous pipeline phases.
- Shell execution is an intentional power feature, but the current implementation has no audit trail.

Fix:

- Capture exit code, stderr, stdout size-limited output, and duration.
- Return or record hook execution results.
- Add per-hook timeout support for shell hooks.
- Surface hook failures in the app status or a local log.

## High-Priority Quality Issues

### 5. `app.go` Is Still A Broad Wails Facade

`app.go` handles dependency construction, lifecycle, chat, slash commands, ingestion, analysis, sources, providers, memory, scheduler, calendar, reports, documents, webhooks, delivery, and hooks.

Impact:

- Feature changes share one large file and one large object.
- Most behavior is hard to test without constructing the full app graph.
- DTOs, filesystem reads, domain calls, event emission, and user command parsing are mixed.

Recommended direction:

- Keep `App` as the stable Wails binding root.
- Split bindings into feature-owned files in package `main`, such as `app_chat.go`, `app_documents.go`, `app_webhooks.go`, and `app_calendar.go`.
- Move workflow logic into internal services where tests can avoid Wails runtime dependencies.
- Keep generated `frontend/wailsjs/**` untouched except through Wails generation.

### 6. `useAppController` Became The New Frontend Bottleneck

Location: `frontend/src/app/useAppController.ts`

The UI shell was extracted, but the controller now owns all view state, all queries, all mutations, runtime event subscriptions, form state for unrelated features, selected report/document state, status derivation, and action wiring.

Impact:

- Views are visually separated but still operationally coupled.
- Adding a feature means editing the central controller and the central return object.
- A single `busy` flag cannot accurately represent concurrent operations.
- Wails event cleanup uses `EventsOff(event)` by name, which is broad. The generated type indicates `EventsOn` returns an unsubscribe function; using that would be safer for HMR and future multiple listeners.

Recommended direction:

- Create `frontend/src/api/*` wrappers and shared query keys.
- Create feature controllers such as `useChatController`, `useDocumentsController`, `useSourcesController`, and `useAutomationController`.
- Replace global `busy` with operation-specific pending state from mutations and queries.
- Store unsubscribe callbacks from `EventsOn` and call those in cleanup.

### 7. The Orchestrator Mixes Too Many Responsibilities

Location: `internal/orchestrator/orchestrator.go`

The orchestrator owns queue state, status state, ingestion expansion, fetch execution, report prompt construction, provider routing, analysis worker lifecycle, report parsing, report writing, manifest updates, delivery dispatch, and hook dispatch.

Impact:

- It is hard to change queue behavior without touching model, report, and delivery behavior.
- Comments are stale in places, such as analysis being described as sequential while provider-backed parallelism exists.
- There are two queue concepts: in-memory UI queue entries and persisted `Library/queue.json` processed-file tracking. That may be intentional, but the naming makes the contract unclear.
- `DrainQueue` ignores enqueue errors, so queue capacity can silently defer work without telling the caller why.

Recommended direction:

- Extract `AnalysisQueue`, `IngestPlanner`, `AnalysisWorker`, `ReportWriter`, and `PromptBuilder`.
- Rename persisted processed-file tracking to avoid calling it the analysis queue.
- Make capacity behavior explicit in `DrainQueue` results.
- Keep `Orchestrator` as the public facade only.

### 8. Persistence Is Repeated And Not Atomic

Repeated JSON load/save logic appears in providers, scheduler, webhook, hooks, delivery, queue, sources, calendar, memory, and reports. Most write paths use `os.WriteFile` directly.

Impact:

- A crash or interrupted write can corrupt config.
- Directory creation is inconsistent.
- Map-backed stores write nondeterministic ordering.
- Error wrapping varies by package.
- Secrets are stored in plaintext without a stated local trust policy.

Recommended direction:

- Add `internal/store/jsonfile` with load, mkdir, atomic write, stable sorting hooks, and consistent error wrapping.
- Use temp-file-plus-rename writes.
- Document the local secret storage policy.

### 9. Network And Process Clients Need Timeouts And Test Seams

Locations:

- `internal/mcp/client.go`
- `internal/provider/provider.go`
- `internal/websearch/search.go`
- `internal/hooks/hooks.go`

MCP calls can wait on scanner reads without a request timeout. MCP stderr is not captured. Provider and websearch paths use `http.DefaultClient` in places. Streaming parsers ignore malformed JSON chunks.

Impact:

- External tools can hang startup or calls.
- Provider streaming bugs can be hidden.
- Network behavior is harder to test deterministically.

Recommended direction:

- Inject `*http.Client` into provider and search clients.
- Add request-level timeouts for MCP initialize, tools/list, and tools/call.
- Capture stderr from MCP processes with size limits.
- Add parser tests for malformed, partial, and non-data SSE lines.

### 10. CSS Is Still Too Global

Location: `frontend/src/styles.css`

The frontend component tree is split, but most styling remains in one 1874-line global stylesheet.

Impact:

- Feature-specific styling changes can regress unrelated views.
- It is hard to see which classes are shared primitives versus local feature classes.
- Calendar already has its own CSS file, but the split is not systematic.

Recommended direction:

- Keep base reset, shell layout, tokens, and reusable primitives in global CSS.
- Move feature-specific styles into feature-local CSS files.
- Name shared primitives intentionally, and keep one-off view classes local.

## Test Coverage Gaps

The green checks are a good baseline, but the current tests do not cover several important behavior surfaces:

- Wails binding behavior in `app.go`.
- Webhook auth and action dispatch.
- Hook execution results and timeout behavior.
- Provider streaming parsers.
- MCP process startup, timeout, and tool-call behavior.
- Frontend rendering/smoke tests for primary views.
- Markdown sanitization.
- Analysis multi-error failure handling.

Minimum next tests:

- `TestRunAnalysisReturnsAfterMultipleFailures`.
- `TestWebhookRejectsMissingOrInvalidSecret`.
- `TestRenderMarkdownSanitizesUnsafeHTML`.
- `TestProviderStreamingMalformedChunks`.
- A Playwright smoke test that opens Home, Documents, Analysis, Calendar, Intelligence, Webhooks, and Advanced.

## Recommended Priority Plan

### Immediate Fixes

1. Fix the analysis error-channel deadlock.
2. Sanitize markdown rendering behind a single component/helper.
3. Enforce or remove webhook secrets. Do not leave the unused field as implied security.
4. Capture hook execution errors and make failures observable.
5. Change Wails event cleanup to use unsubscribe functions returned by `EventsOn`.

### Next Refactor Slice

1. Split `app.go` by Wails feature area without changing exported method names.
2. Split `useAppController` into feature controllers and API modules.
3. Add `internal/store/jsonfile` and migrate one persistence package at a time.
4. Extract orchestrator report writing and prompt building before touching worker behavior.

### Later Hardening

1. Add MCP call timeouts and stderr capture.
2. Inject HTTP clients into provider and websearch packages.
3. Add frontend smoke coverage.
4. Move feature-specific CSS out of `styles.css`.
5. Document the local trust model for shell hooks, webhooks, provider keys, cookies, MCP, and fetched markdown.

## Bottom Line

The app is in a workable development state and currently passes the standard checks. The next quality push should not be a broad cleanup. It should be a short reliability pass on the runtime hazards, followed by small boundary extractions that keep Wails method names stable.

The highest-value first move is to fix the analysis deadlock and then lock down markdown and webhook trust boundaries. Those are real defect and security risks, not just style issues.
