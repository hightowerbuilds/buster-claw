# 04-21-2026 Summary

## Today

- Full codebase review with new Claude agent — verified understanding of architecture, all packages, and frontend.
- **Dead code cleanup — TUI removal:**
  - Deleted `internal/tui/` entirely (3 files: `model.go`, `memory.go`, `markdown.go`, ~1,092 LOC). No imports existed anywhere in the codebase — fully dead since the Wails migration.
  - `go mod tidy` removed all Charm/Bubble Tea dependencies: `charmbracelet/bubbles`, `charmbracelet/bubbletea`, `charmbracelet/lipgloss`, `charmbracelet/colorprofile`, `charmbracelet/x/ansi`, `charmbracelet/x/cellbuf`, `charmbracelet/x/term`, plus transitive deps (`erikgeiser/coninput`, `muesli/ansi`, `muesli/cancelreader`, `muesli/termenv`, `atotto/clipboard`, `mattn/go-localereader`, `xo/terminfo`).
- **Dead code cleanup — unused Go methods & types:**
  - Removed `GetIntentions()` from `app.go` — never called from frontend. Removed now-unused `intentions` import.
  - Removed `GetOrchestratorStatus()` from `app.go` — redundant with `orchestrator:status` event push.
  - Removed `GetPendingCount()` from `app.go` — redundant with `GetPendingFiles()`.
  - Removed `StartFullPipeline()` and `FullPipelineResult` from `app.go` — never called from frontend.
  - Removed `ChatStream()` and `Active()` from `internal/provider/provider.go` — app uses Ollama client directly; these were unused routing stubs.
- **Frontend type cleanup:**
  - Removed `FullPipelineResult` interface and stubs for `StartFullPipeline`, `GetOrchestratorStatus`, `GetIntentions`, `GetPendingCount` from `frontend/src/wails.d.ts`.
- Clean build confirmed after all removals. All tests pass.

## Notes

- The `cmd/mcp-server/main.go` standalone MCP binary was reviewed and confirmed still needed — it's a separate entry point for external MCP clients.
- `memory/pneuma.md` reviewed — part of the memory package's expected directory structure, kept.
- Wails dev server running with hot reload throughout the session.
