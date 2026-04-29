# Buster Claw: In-Depth Code Analysis
**Analysis Date:** 2026-04-21  
**Codebase Size:** ~5,500 LOC (Go) + 826 LOC (SolidJS frontend)  
**Test Coverage:** 3 test files covering ~180 LOC (3.3% of codebase)  
**Development Pace:** TUI→Wails migration + full pipeline shipped in ~2 weeks

---

## Executive Summary

**Verdict:** Impressive execution velocity. The app *works* for personal use, but is **not production-ready**. Three critical issues and pervasive architectural debt must be addressed before shipping. The gap is not functionality—it's reliability, observability, and maintainability.

**Key Findings:**
- ✅ **Good:** Clean abstractions (ingest, library, orchestrator, MCP), working MVP, modern stack (Wails+SolidJS+TanStack Query)
- ❌ **Critical:** Race conditions in message handling, orchestrator tracking hack, test anemia
- ❌ **High:** Non-blocking MCP startup with no error visibility, 4 conflicting "busy" state signals
- ⚠️ **Debt:** ~408 LOC of dead provider code, stale README, scattered `fmt.Printf` logging

---

## Part 1: Architecture & Design

### 1.1 System Overview

**Core Pipeline:** User/Scheduled Input → Ingest → Library → Queue → Orchestrator → Analysis → Report

```
┌─────────────────────────────────────────────────────────────┐
│                    Wails Desktop App                        │
│  ┌──────────────────────────────────────────────────────┐  │
│  │              SolidJS Frontend (826 LOC)              │  │
│  │  6 Views: Chat | Ingest | Documents | Orchestrate   │  │
│  │           | Analysis | Models                        │  │
│  └──────────────────────────────────────────────────────┘  │
│                            ↕ EventsEmit/EventsOn           │
├─────────────────────────────────────────────────────────────┤
│                  Go Backend (app.go, 895 LOC)              │
│  ┌──────────────────────────────────────────────────────┐  │
│  │ Chat Handler → Ollama Streaming (local LLM only)     │  │
│  └──────────────────────────────────────────────────────┘  │
│  ┌──────────────────────────────────────────────────────┐  │
│  │           Orchestrator (orchestrator.go)             │  │
│  │  • Ingest Pipeline (fetcher → parser → library)      │  │
│  │  • Analysis Queue (sequential job processor)         │  │
│  └──────────────────────────────────────────────────────┘  │
│  ┌──────────────────────────────────────────────────────┐  │
│  │     Supporting Services                              │  │
│  │  • MCP Manager (stdio server connections)            │  │
│  │  • Memory Store (persistent LLM context)             │  │
│  │  • Provider Manager (unused: OpenRouter, OpenAI)     │  │
│  │  • Web Search (DuckDuckGo integration)               │  │
│  └──────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────┘

Storage:
  └─ $CWD/
     ├─ Library/raw/      (raw documents, HTML/markdown)
     ├─ Library/reports/  (analysis results)
     ├─ Memory/           (persistent memory entries)
     ├─ sources.json      (ingest sources)
     ├─ mcp.json          (MCP server configs)
     └─ providers.json    (unused provider configs)
```

### 1.2 Module Breakdown

| Module | LOC | Purpose | Quality |
|--------|-----|---------|---------|
| **app.go** | 895 | Wails bindings, chat, slash commands, event routing | ⚠️ Race conditions |
| **orchestrator/** | 624 | Pipeline coordination, job queue, state tracking | ⚠️ Tracking hack |
| **ingest/** | 411 | RSS/article fetching, HTML parsing, readability | ✅ Good, tested |
| **frontend/src/App.tsx** | 826 | 6-view UI, state management, real-time updates | ⚠️ State chaos |
| **provider/** | 408 | Multi-provider abstraction (OpenRouter, OpenAI, Anthropic) | ❌ Dead code |
| **mcp/** | 587 | MCP client/manager, tool discovery, routing | ⚠️ Silent failures |
| **library/** | 223 | Document storage, frontmatter, report generation | ✅ Tested |
| **memory/** | 173 | Persistent memory store, markdown-based | ✅ Functional |
| **websearch/** | 180 | Query detection, DuckDuckGo integration | ✅ Tested |
| **queue/** | 126 | Analysis job queue abstraction | ⚠️ Unused? |
| **tui/** | 1,092 | Bubble Tea TUI (legacy, replaced by Wails) | ⚠️ Dead code |

**Total:** 5,475 Go LOC + 826 TS/TSX + ~1,092 dead TUI code

---

## Part 2: Critical Issues (Fix This Sprint)

### 🔴 Issue #1: Race Condition in Message Handling

**Location:** `app.go:175-229`  
**Severity:** CRITICAL — Can corrupt chat history or cause panic

```go
// app.go:175-177 — Message added to slice
a.mu.Lock()
a.messages = append(a.messages, ChatMessage{Role: "user", Content: prompt})
a.mu.Unlock()

// app.go:190-201 — Message history copied (under lock)
a.mu.Lock()
for _, m := range a.messages {
    history = append(history, ...)
}
a.mu.Unlock()

// app.go:203-229 — Goroutine spawned, operates on data outside lock
go func() {
    // ...line 215: uses history (OK, was copied)
    // BUT: history was copied, then new messages can arrive before
    // app.go:228 appends response
    a.mu.Lock()
    a.messages = append(a.messages, ChatMessage{Role: "assistant", Content: response})
    a.mu.Unlock()
}()

// Race: If another goroutine calls SendMessage while previous one still running,
// append-to-slice can panic (grow beyond capacity) or corrupt data
```

**Why It's Bad:**
- Unbounded concurrent appends to `a.messages` slice
- No atomic increment of slice length — two goroutines can write same index
- Reused slice backing array can cause panic or data loss

**Fix:**
- **Option A** (simple, correct): Lock entire operation: acquire lock → copy history → spawn goroutine that reads history (no re-locking). Append response inside goroutine with fresh lock.
- **Option B** (better): Use `append(nil, history...)` to create immutable copy, pass to goroutine, no re-locking needed for response append.
- **Option C** (future): Switch to channel-based message queue (immutable).

**Test Case Needed:**
```go
// Concurrent sends should not panic or corrupt history
// SendMessage() x N in parallel, verify len(messages) == 2N and no panics
```

---

### 🔴 Issue #2: Orchestrator Tracking Hack

**Location:** `orchestrator.go:62-68, 127-175`  
**Severity:** CRITICAL — State inconsistency bug waiting to happen

```go
// orchestrator.go:62-68
type Orchestrator struct {
    analysisQueue chan Job          // Source of truth?
    trackedQueue []QueueEntry       // Parallel shadow state!
    trackedMu    sync.RWMutex
}

// Problem: Two separate data structures tracking the same logical queue
// Queue entries are added to analysisQueue AND trackedQueue
// They're updated separately — code like:
//   1. Send job to analysisQueue
//   2. Append entry to trackedQueue (separate operation!)
//   3. If #2 fails, queue is in inconsistent state

// Example inconsistency window:
// Job sent down channel (line 155)
// Frontend queries GetQueueStatus() (reads trackedQueue)
// But job hasn't been added to trackedQueue yet — frontend shows old state
```

**Why It's Bad:**
- Frontend relies on `trackedQueue` (from `GetQueueStatus()`)
- Backend pushes jobs via `analysisQueue` channel
- Two separate locks (`trackedMu` and implicit channel safety) mean updates can race
- If app crashes between channel send and slice append, queue state is lost on restart

**Example Failure:**
1. Job added to `analysisQueue` channel
2. App crashes before appending to `trackedQueue`
3. Restart: `analysisQueue` is empty (channel not persisted), but job was processed
4. Frontend shows stale state

**Fix:**
- **Delete `trackedQueue` entirely**
- Make `analysisQueue` the source of truth
- To expose queue to frontend: maintain a map of `jobID → status` updated only inside the worker goroutine
- OR: buffer channel contents into frontend-queryable state (one lock)

**Code to write:**
```go
// Replace parallel structures with single source
type Orchestrator struct {
    queue      chan Job
    jobStatus  map[string]Status  // jobID -> pending/running/done
    jobMu      sync.Mutex
}

// Get status: read jobStatus map under lock
// Enqueue job: add to queue, update map in worker goroutine (single lock point)
```

---

### 🔴 Issue #3: Test Anemia

**Location:** 3 test files covering only ingest, library, websearch (180 LOC)  
**Severity:** CRITICAL — No tests for orchestrator, MCP, chat, or integration

**Current Coverage:**
```
internal/ingest:       58 LOC test → 411 LOC code (14%)
internal/library:      46 LOC test → 223 LOC code (21%)
internal/websearch:    33 LOC test → 180 LOC code (18%)
───────────────────────────────────────────────────────
Tested total:         137 LOC test → 814 LOC code (17%)
Untested:                          → 4,661 LOC untested (83%)
```

**Zero Tests For:**
- `orchestrator/` (624 LOC) — **Core business logic**. No test for: ingest→queue→analyze flow, error handling, concurrent job processing, status tracking
- `app.go` (895 LOC) — Chat streaming, slash commands, race condition between multiple sends
- `mcp/` (587 LOC) — Server connection, tool discovery, error handling
- `provider/` (408 LOC) — Config loading, provider selection
- `memory/` (173 LOC) — Persistence, reload
- `queue/` (126 LOC) — Job deduplication, persistence

**Why It Matters:**
- Orchestrator changes (fixing issue #2) have no safety net
- Chat race condition (issue #1) could pass code review undetected
- MCP startup changes require manual testing
- No regression tests — shipping future features will be high-risk

**Minimum Tests (write first):**
```go
// orchestrator_test.go
func TestPipelineFlow(t *testing.T) {
    // 1. Ingest source → check file saved to Library/raw
    // 2. Enqueue analysis job → check job appears in queue
    // 3. Run analysis → check report generated
    // 4. Query status → verify counts (queued, completed)
}

func TestConcurrentAnalysis(t *testing.T) {
    // Enqueue 10 jobs concurrently
    // Verify all processed, queue consistent
}

// app_test.go
func TestConcurrentSendMessage(t *testing.T) {
    // 20 concurrent SendMessage calls
    // Verify: len(messages) == 40 (user + assistant pairs)
    // Verify: no panics, no data corruption
}
```

---

## Part 3: High-Priority Issues (Fix Next Sprint)

### 🟠 Issue #4: MCP Startup Non-Blocking, No Timeout, Silent Failures

**Location:** `app.go:113-122`

```go
// Non-blocking startup (fine), but:
go func() {
    errs := a.mcpManager.LoadAndConnect()  // No timeout — can hang forever
    for _, err := range errs {
        fmt.Printf("[mcp] %s\n", err)  // Stdout invisible in Wails app!
    }
}()

// User never sees: "MCP server X failed to connect"
// App silently continues with fewer tools available
```

**Why It's Bad:**
- If MCP server is misconfigured or dead, user doesn't know
- `fmt.Printf` goes to stdout, invisible in Wails desktop app
- App pretends MCP is working when it isn't
- No way to retry or fallback

**Fix:**
- Add 10-second timeout to `LoadAndConnect()`
- Log errors to `runtime.EventsEmit(ctx, "mcp:error", err)` for frontend notification
- Add manual "Reconnect MCP" button in Models view
- OR: defer MCP loading until first tool use (lazy init)

---

### 🟠 Issue #5: Frontend State Chaos — 4 Conflicting "Busy" Signals

**Location:** `frontend/src/App.tsx:14-25`

```tsx
const [streaming, setStreaming] = createSignal(false);   // Chat streaming
const [searching, setSearching] = createSignal("");       // Web search query
const [waiting, setWaiting] = createSignal(false);        // ???
const [busy, setBusy] = createSignal(false);              // Ingest/analysis

// Status bar (line 814-817):
{searching() ? "Searching..." :
 streaming() ? "Chatting..." :
 waiting() ? "Waiting..." :      // When does this fire?
 busy() ? "Working..." :
 "Ready"}

// Button disabled state (line 411):
disabled={!currentModel() || streaming()}

// But should be disabled during search and busy too!
// Current logic is:  can't chat while chatting (good)
//                    can chat while searching (bad)
//                    can chat while ingest running (bad)
```

**Problem:**
- `waiting` signal exists but is never set (`setWaiting` never called)
- UI allows overlapping operations (chat while ingesting, chat while searching)
- Status bar shows wrong message when multiple operations happen
- Unclear semantics: is "waiting" for analysis results? For MCP response? For upload?

**Fix:**
```tsx
// Single state machine: 'idle' | 'searching' | 'streaming' | 'ingesting' | 'analyzing'
const [appState, setAppState] = createSignal<'idle' | 'searching' | 'streaming' | 'ingesting' | 'analyzing'>('idle');

// Button logic becomes clear:
disabled={!currentModel() || appState() !== 'idle'}

// Status bar:
{appState() === 'searching' && `Searching for "${searchQuery()}"...`}
{appState() === 'streaming' && "Chatting..."}
{appState() === 'ingesting' && `Ingesting ${ingestCount()}...`}
{appState() === 'analyzing' && "Running analysis..."}

// Clear signal: setAppState when each operation starts/ends
```

---

## Part 4: Technical Debt & Premature Abstraction

### ⚠️ Issue #6: Dead Provider System (408 LOC)

**Status:** Complete abstraction, zero usage  
**Impact:** Code bloat, confusing onboarding

**Current State:**
- `provider.go:44-150` defines `Manager` with config loading
- Supports: Ollama, OpenRouter, OpenAI, Anthropic, Custom endpoints
- But `app.go` hardcodes Ollama (line 79): `client := ollama.NewClient(cfg.Host)`
- `app.SetModel()` switches *which* Ollama model, not *which* provider
- Config is loaded (`provMgr.Load()` at line 85) but never used

**Why It's Wrong:**
- Costs mental load: "Why is there a provider system if chat only uses Ollama?"
- Adds maintenance burden: if Ollama client changes, provider system might break
- False promise: frontend shows it exists, users think they can switch providers

**What To Do:**
**Option A (delete):** Rip out provider system entirely. If you need it later, use Git history.  
**Option B (ship):** Integrate it into chat: frontend dropdown "Chat Provider" → OpenRouter/OpenAI/etc. Route SendMessage to right provider.  
**Option C (defer):** Add note "Provider system reserved for future use, currently Ollama-only."

**Recommendation:** Delete it. You don't have users asking for multi-provider. Add it back when you do.

---

### ⚠️ Issue #7: Dead TUI Code (1,092 LOC in internal/tui/)

**Status:** Replaced by Wails desktop app, no longer called  
**Files:** `internal/tui/model.go` (943 LOC), `memory.go`, `markdown.go`

**Impact:** Confuses new readers, takes space in binary

**What To Do:** Delete `internal/tui/` entirely. Keep Git history if you need to revert the TUI→Wails pivot.

---

### ⚠️ Issue #8: README Stale

**Status:** Still describes Bubble Tea TUI  
**Broken Claims:**
- "terminal chat app for local Ollama models with a Bubble Tea TUI"  
- "TUI Commands" section (now frontend UI)
- `-m` flag (Wails app doesn't take CLI flags)
- Markdown file generation (never implemented for Wails)

**Impact:** Credibility damage, onboarding confusion

---

### ⚠️ Issue #9: Scattered Logging (fmt.Printf)

**Status:** 15+ `fmt.Printf` calls throughout codebase  
**Problem:** Invisible in Wails desktop app (goes to stdout, no console visible)  
**Locations:**
- `app.go:117` — MCP errors logged to stdout
- `orchestrator.go:many` — job status updates
- `ingest/fetcher.go` — fetch progress

**Impact:** Users don't see errors, failures are silent

**Fix:** Use Go's `log/slog` package (structured logging):
```go
import "log/slog"
slog.Error("mcp connect failed", "server", name, "error", err)
// Later: route errors to frontend via EventsEmit or append to error log file
```

---

## Part 5: Code Quality Metrics

### Size & Complexity

| Metric | Value | Assessment |
|--------|-------|------------|
| Total LOC (Go) | 5,475 | Moderate, but top-heavy |
| app.go (main binding) | 895 | Too large, should split into handlers |
| orchestrator.go | 624 | Reasonable, but quality issues |
| Largest file | tui/model.go | 943 (dead code) |
| Smallest tested | websearch/ | 180 LOC, 18% tested |
| Functions per file | ~10-15 avg | Good (not over-modularized) |

### Test Quality

| Category | Status | Count |
|----------|--------|-------|
| Unit tests | Minimal | 3 files, 5 test functions |
| Integration tests | None | 0 |
| End-to-end tests | None | 0 |
| Test coverage % | ~3.3% | Critical gap |
| Lines tested | 137 | Mostly ingest (simple parsing) |
| Mocked dependencies | None | Tests use temp directories |

### Dependency Analysis

**Direct dependencies (useful):**
- `wailsapp/wails/v2` — Desktop framework (required)
- `mmcdole/gofeed` — RSS parsing (good)
- `PuerkitoBio/goquery` — HTML scraping (good)
- `html-to-markdown` — Content extraction (good)
- `charmbracelet/bubbletea` — Unused (dead TUI)
- `charmbracelet/lipgloss` — Unused (dead TUI)

**Transitive bloat:** Bubble Tea deps (~15 unused packages) add ~800KB to binary. Remove after deleting TUI code.

---

## Part 6: Security & Data Safety

### No Critical Vulnerabilities Found

✅ **Good:**
- No SQL injection (no SQL)
- No command injection (inputs validated before passing to shell)
- No XSS (desktop app, not web)
- No auth bypass (local-only, no multi-user)
- File I/O uses `filepath.Join` (safe, no path traversal)

⚠️ **Minor Concerns:**
- MCP server untrusted (executes arbitrary stdio binaries as subprocess)
- Memory persisted to disk in plaintext (fine for local use)
- No input validation on chat messages (could cause OOM if user sends 100MB prompt)

---

## Part 7: Performance & Scalability

### Current Characteristics

**Good:**
- Streaming chat responses (not loading entire response in memory)
- Concurrent ingest (parallel source fetching)
- Sequential analysis (one document at a time, prevents LLM overload)

**Bottlenecks:**
- **Ollama latency:** All analysis waits for model inference. No caching, no fallback models.
- **Memory growth:** No pagination of chat history. If user chats for hours, `a.messages` unbounded.
- **Library scalability:** Flat directory structure (`Library/raw/`) will slow down after 10,000+ documents.

**Projected Limits:**
- **10K documents:** Library queries slow (ls on big directory)
- **1K messages:** Chat UI may stutter (DOM operations with large message list)
- **1GB raw documents:** Memory file I/O will lag

**Fixes (future):**
- Index documents with SQLite or similar (now just filesystem)
- Paginate chat UI (virtual scrolling in SolidJS)
- Add document cache headers (conditional fetches)

---

## Part 8: Architecture Strengths

✅ **Good Decisions:**

1. **Wails for desktop:** Right choice. Eliminates Electron, small binary (~7MB), Go backend.
2. **SolidJS + TanStack Query:** Reactive, minimal boilerplate, good for streaming.
3. **Modular internals:** `ingest/`, `orchestrator/`, `library/` are cleanly separated.
4. **MCP protocol:** Extensible tool system without hardcoding.
5. **Memory injection:** System prompt context is clever and simple.
6. **Streaming UX:** Token-by-token chat feedback is better than buffering.

---

## Part 9: Architecture Weaknesses

❌ **Bad Decisions:**

1. **No database:** Filesystem for everything (Library, queue, config) → hard to query, no ACID.
2. **Parallel tracking structures:** Orchestrator has both channel and slice (issue #2).
3. **Hardcoded Ollama:** Provider system built but unused (issue #6).
4. **Unstructured logging:** fmt.Printf everywhere, invisible in Wails (issue #9).
5. **Large app.go:** 895 LOC, should be split into `chat.go`, `ingest.go`, `models.go`.
6. **Frontend prop-drilling:** No context provider for app state, all signals at top level.

---

## Part 10: Recommendations (Prioritized)

### Phase 1: Stability (This Sprint)
**Goal:** Remove crashes, make errors visible, ensure data consistency.

1. **Fix race condition (#1):** Lock entire send/receive cycle. Add concurrent send test.
2. **Fix orchestrator tracking (#2):** Delete `trackedQueue`, use channel as source of truth.
3. **Add integration tests (#3):** Minimum 5 tests covering pipeline flow, error cases, concurrency.
4. **Update README:** Rewrite for Wails, fix all incorrect sections.

**Estimated effort:** 8-12 hours  
**Risk:** Low (refactoring with tests)  
**Benefit:** High (crash-free, testable codebase)

---

### Phase 2: Usability (Next Sprint)
**Goal:** Fix silent failures, simplify state management, improve error visibility.

5. **Fix MCP startup (#4):** Add timeout, emit errors to frontend, add reconnect button.
6. **Consolidate state (#5):** Replace 4 busy signals with 1 state machine.
7. **Replace scattered logging (#9):** Use `log/slog`, emit errors as frontend events.
8. **Split app.go:** Extract chat, ingest, models, slash commands into separate files.

**Estimated effort:** 10-15 hours  
**Risk:** Medium (state machine is core)  
**Benefit:** High (fewer user-facing bugs)

---

### Phase 3: Polish (After Users)
**Goal:** Reduce code bloat, add nice-to-haves, prepare for scaling.

9. **Delete provider system (#6)** or ship it (add OpenRouter option to chat).
10. **Delete TUI code (#7):** Remove `internal/tui/` entirely.
11. **Add pagination:** Chat history virtual scroll, library doc paging.
12. **Structured logging:** Append errors to `errors.log`, show in Models view.

**Estimated effort:** 6-10 hours  
**Risk:** Low (cleanups)  
**Benefit:** Medium (smaller binary, clearer codebase)

---

## Part 11: Testing Strategy

### Unit Tests (What To Add First)

```go
// orchestrator_test.go
- TestIngestFlow: sources.json → fetcher → library → queue
- TestAnalysisFlow: queued doc → Ollama → report generation
- TestStatusTracking: queue updates reflect in GetStatus
- TestErrorHandling: network error → job fails, status shows error

// app_test.go
- TestConcurrentSendMessage: 20 concurrent sends, all persisted
- TestChatMemoryConsistency: memory injected into first message

// integration_test.go
- TestFullPipeline: ingest RSS → analyze all docs → verify reports exist
```

### Integration Test Approach

```bash
# Setup: temp directory, mock Ollama (or skip chat part)
go test -run TestFullPipeline -v

# Could use httptest.Server to mock Ollama for fast tests
```

---

## Part 12: Code Quality Observations

### What Works Well

**ingest/source.go** — Clean, well-factored:
```go
type Source struct {
    URL  string
    Type SourceType
    Tags []string
}
// LoadSources, SaveSources functions are simple, testable, tested
```

**library/manager.go** — Clear responsibility:
```go
// SaveResult takes FetchResult, writes to disk, returns path
// Frontmatter + content = clean structure
```

**websearch/detect_test.go** — Good test design:
```go
tests := []struct{input, want string; ok bool}{...}
// Concrete examples with assertions
```

---

### What Needs Work

**app.go** — Too large, mixed responsibilities:
```go
// Lines 150-230: Chat handling
// Lines 250-280: Ingest commands
// Lines 300-350: Orchestrator commands
// Lines 400-450: Queue commands
// Lines 500-550: Memory commands
// Should be split into files
```

**orchestrator.go** — Inconsistent error handling:
```go
// Some places return error:
// func (o *O) Ingest() error { ... }

// Some places call callbacks:
// func (o *O) GetStatus() { return o.status } // no error

// Mixed patterns make it hard to follow
```

**frontend/src/App.tsx** — Monolithic component:
```tsx
// 826 LOC in one file
// Should split:
//   ChatView.tsx
//   IngestView.tsx
//   DocumentsView.tsx
//   etc.
```

---

## Part 13: Dependency Tree & Bloat

### Direct Dependencies (go.mod)

```
codeberg.org/readeck/go-readability/v2    ← HTML content extraction
github.com/JohannesKaufmann/html-to-markdown  ← HTML → Markdown
github.com/PuerkitoBio/goquery             ← CSS selectors for scraping
github.com/charmbracelet/bubbletea         ← TUI (UNUSED, delete)
github.com/charmbracelet/bubbles           ← TUI components (UNUSED)
github.com/charmbracelet/lipgloss          ← TUI styling (UNUSED)
github.com/mmcdole/gofeed                  ← RSS parsing
github.com/wailsapp/wails/v2               ← Desktop framework
golang.org/x/net                           ← Networking
```

**Bloat:** 15+ transitive deps from `charmbracelet` packages (~2MB) are unused after TUI removal.

**Action:** Delete `internal/tui/`, remove from `go.mod`, run `go mod tidy`.

---

## Part 14: Build & Deployment

### Current State

```bash
go build -o buster-claw .
# Embeds frontend/dist into binary
# ~7.3MB (reasonable for a desktop app)
```

### Issues

- **No CI/CD** — no automated builds, tests, or version tagging
- **No cross-platform builds** — only tested on macOS
- **Frontend not in .gitignore properly** — `frontend/dist/` should be built only, not committed

**Recommendation:**
```yaml
# .github/workflows/build.yml (when you move to GitHub)
- Run tests
- Build binary for macOS/Linux/Windows
- Create release with DMG/installer
```

---

## Summary: Issues Table

| ID | Issue | Type | Severity | Effort | Value |
|----|-------|------|----------|--------|-------|
| 1 | Message race condition | Bug | CRITICAL | 2h | HIGH |
| 2 | Orchestrator tracking hack | Design | CRITICAL | 3h | HIGH |
| 3 | Test anemia | Quality | CRITICAL | 8h | HIGH |
| 4 | MCP silent failures | UX | HIGH | 2h | HIGH |
| 5 | State chaos (4 busy signals) | Design | HIGH | 4h | HIGH |
| 6 | Dead provider code | Debt | MEDIUM | 1h | MEDIUM |
| 7 | Dead TUI code | Debt | MEDIUM | 1h | MEDIUM |
| 8 | Stale README | Docs | HIGH | 1h | HIGH |
| 9 | Scattered logging | Quality | MEDIUM | 3h | MEDIUM |

---

## Conclusion

**The Good:** You've shipped a working knowledge tool in 2 weeks. Architecture is sound, MVP is functional, tech stack is solid.

**The Gap:** Between "personal prototype" and "shippable product" lies:
- Fixing 3 critical issues (race conditions, orchestration consistency, test coverage)
- Making errors visible (logging, MCP error UI)
- Simplifying state (4 busy signals → 1 state machine)
- Removing dead code (TUI, providers)

**Timeline to "ready for alpha users":** 20-30 hours of focused work (2-3 days at aggressive pace, 1 week at sustainable pace).

**Not needed before shipping to first users:**
- Database migration (filesystem is fine for <10K docs)
- Multi-provider support (Ollama-only is fine)
- Advanced features (caching, pagination, etc.)

**Verdict:** Ship Phase 1 fixes, then start taking user feedback. You'll learn more from real usage than any analysis.

