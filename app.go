package main

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"buster-claw/internal/calendar"
	"buster-claw/internal/config"
	"buster-claw/internal/delivery"
	"buster-claw/internal/hooks"
	"buster-claw/internal/ingest"
	"buster-claw/internal/library"
	"buster-claw/internal/mcp"
	"buster-claw/internal/memory"
	"buster-claw/internal/ollama"
	"buster-claw/internal/orchestrator"
	"buster-claw/internal/provider"
	"buster-claw/internal/queue"
	"buster-claw/internal/scheduler"
	"buster-claw/internal/webhook"
	"buster-claw/internal/websearch"

	"github.com/wailsapp/wails/v2/pkg/runtime"
)

// App is the primary Wails binding struct. All exported methods
// are callable from the SolidJS frontend.
type App struct {
	ctx          context.Context
	client       *ollama.Client
	model        string
	saveDir      string
	orchestrator *orchestrator.Orchestrator
	memory       *memory.Store
	mcpManager   *mcp.Manager
	providers    *provider.Manager
	scheduler    *scheduler.Engine
	webhooks     *webhook.Server
	delivery     *delivery.Manager
	hooks        *hooks.Manager
	calendar     *calendar.Manager
	messages     []ChatMessage
	mu           sync.Mutex
}

// ChatMessage is a single chat entry visible in the frontend.
type ChatMessage struct {
	Role    string `json:"role"`
	Content string `json:"content"`
}

// OrchestratorStatus mirrors the orchestrator status for the frontend.
type OrchestratorStatus struct {
	Phase         string   `json:"phase"`
	QueueDepth    int      `json:"queueDepth"`
	ActiveJob     string   `json:"activeJob"`
	ActiveJobs    []string `json:"activeJobs"`
	CompletedJobs int      `json:"completedJobs"`
	FailedJobs    int      `json:"failedJobs"`
}

// IngestResult is returned after an ingestion run.
type IngestResult struct {
	SavedCount int    `json:"savedCount"`
	Error      string `json:"error,omitempty"`
}

// AnalysisResult is returned after an analysis run.
type AnalysisResult struct {
	ProcessedCount int    `json:"processedCount"`
	Error          string `json:"error,omitempty"`
}

const (
	analysisQueueTimeout = 4 * time.Hour
	fullPipelineTimeout  = 5 * time.Hour
)

// NewApp creates a new App instance.
func NewApp(saveDir string) *App {
	cfg := config.Load()
	client := ollama.NewClient(cfg.Host)
	mcpMgr := mcp.NewManager(filepath.Join(saveDir, "mcp.json"))
	provMgr := provider.NewManager(filepath.Join(saveDir, "providers.json"))
	provMgr.Load()
	deliv := delivery.NewManager(filepath.Join(saveDir, "Library", "delivery.json"))
	hks := hooks.NewManager(filepath.Join(saveDir, "Library", "hooks.json"))

	orch := orchestrator.New(client, provMgr, deliv, hks, cfg.Model, saveDir)
	orch.WorkerCount = 3
	mem := memory.NewStore(saveDir)
	mem.Load()

	sched := scheduler.New(filepath.Join(saveDir, "Library", "scheduler.json"))
	hooks := webhook.NewServer(filepath.Join(saveDir, "Library", "webhooks.json"), 9090)
	cal := calendar.NewManager(filepath.Join(saveDir, "Library", "calendar.json"))

	app := &App{
		client:       client,
		model:        cfg.Model,
		saveDir:      saveDir,
		orchestrator: orch,
		memory:       mem,
		mcpManager:   mcpMgr,
		providers:    provMgr,
		scheduler:    sched,
		webhooks:     hooks,
		delivery:     deliv,
		hooks:        hks,
		calendar:     cal,
	}

	// Wire up scheduler handlers
	sched.OnIngest = func() error {
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Minute)
		defer cancel()
		_, err := orch.RunIngest(ctx)
		return err
	}
	sched.OnAnalyze = func() error {
		ctx, cancel := context.WithTimeout(context.Background(), analysisQueueTimeout)
		defer cancel()
		_, err := orch.DrainQueue(ctx)
		return err
	}
	sched.OnFull = func() error {
		ctx, cancel := context.WithTimeout(context.Background(), fullPipelineTimeout)
		defer cancel()
		_, _, err := orch.RunFull(ctx)
		return err
	}
	sched.OnDigest = func(deliverTo string) error {
		return fmt.Errorf("digest not yet implemented")
	}
	sched.OnCustom = func(cmd string) error {
		return app.handleSlashCommand(cmd)
	}

	// Wire up webhook handlers
	hooks.OnTrigger = func(h webhook.Hook, payload []byte) error {
		switch h.Action {
		case webhook.ActionIngest:
			ctx, cancel := context.WithTimeout(context.Background(), 5*time.Minute)
			defer cancel()
			_, err := orch.RunIngest(ctx)
			return err
		case webhook.ActionAnalyze:
			ctx, cancel := context.WithTimeout(context.Background(), analysisQueueTimeout)
			defer cancel()
			_, err := orch.DrainQueue(ctx)
			return err
		case webhook.ActionFull:
			ctx, cancel := context.WithTimeout(context.Background(), fullPipelineTimeout)
			defer cancel()
			_, _, err := orch.RunFull(ctx)
			return err
		case webhook.ActionCommand:
			return app.handleSlashCommand(h.CustomCmd)
		}
		return nil
	}

	return app
}

// startup is called when the Wails app starts.
func (a *App) startup(ctx context.Context) {
	a.ctx = ctx

	if err := a.scheduler.Load(); err != nil {
		fmt.Printf("[scheduler] failed to load: %v\n", err)
	}
	a.scheduler.Start()

	if err := a.webhooks.Load(); err != nil {
		fmt.Printf("[webhooks] failed to load: %v\n", err)
	}
	if err := a.webhooks.Start(); err != nil {
		fmt.Printf("[webhooks] failed to start: %v\n", err)
	}

	if err := a.delivery.Load(); err != nil {
		fmt.Printf("[delivery] failed to load: %v\n", err)
	}

	if err := a.hooks.Load(); err != nil {
		fmt.Printf("[hooks] failed to load: %v\n", err)
	}

	if err := a.calendar.Load(); err != nil {
		fmt.Printf("[calendar] failed to load: %v\n", err)
	}

	// Wire orchestrator status changes to frontend events.
	a.orchestrator.OnStatusChange = func(s orchestrator.Status) {
		runtime.EventsEmit(a.ctx, "orchestrator:status", OrchestratorStatus{
			Phase:         s.Phase,
			QueueDepth:    s.QueueDepth,
			ActiveJob:     s.ActiveJob,
			ActiveJobs:    s.ActiveJobs,
			CompletedJobs: s.CompletedJobs,
			FailedJobs:    s.FailedJobs,
		})
	}

	// Connect to configured MCP servers (non-blocking, errors logged).
	go func() {
		errs := a.mcpManager.LoadAndConnect()
		for _, err := range errs {
			fmt.Printf("[mcp] %s\n", err)
			runtime.EventsEmit(a.ctx, "mcp:error", err.Error())
		}
		if names := a.mcpManager.ServerNames(); len(names) > 0 {
			fmt.Printf("[mcp] connected: %s\n", strings.Join(names, ", "))
			runtime.EventsEmit(a.ctx, "mcp:connected", names)
		}
	}()
}

// shutdown is called when the Wails app exits.
func (a *App) shutdown(ctx context.Context) {
	a.scheduler.Stop()
	a.mcpManager.Close()
}

// --- Model Management ---

// GetModels returns installed Ollama models.
func (a *App) GetModels() ([]string, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	return a.client.ListModels(ctx)
}

// GetCurrentModel returns the currently selected model.
func (a *App) GetCurrentModel() string {
	return a.model
}

// SetModel switches the active model.
func (a *App) SetModel(name string) {
	a.model = name
	a.orchestrator.SetModel(name)
}

// --- Chat ---

// GetMessages returns the chat history.
func (a *App) GetMessages() []ChatMessage {
	a.mu.Lock()
	defer a.mu.Unlock()
	msgs := make([]ChatMessage, len(a.messages))
	copy(msgs, a.messages)
	return msgs
}

// SendMessage sends a prompt to the model and streams the response.
// Supports slash commands: /search, /ingest, /status, /clear, /help.
// Emits "chat:token" events as chunks arrive, and "chat:done" when complete.
func (a *App) SendMessage(prompt string) error {
	trimmed := strings.TrimSpace(prompt)

	// Handle slash commands — these don't require a model
	if strings.HasPrefix(trimmed, "/") {
		return a.handleSlashCommand(trimmed)
	}

	if a.model == "" {
		return fmt.Errorf("no model selected")
	}

	a.mu.Lock()
	a.messages = append(a.messages, ChatMessage{Role: "user", Content: prompt})
	a.mu.Unlock()

	runtime.EventsEmit(a.ctx, "chat:message", ChatMessage{Role: "user", Content: prompt})

	// Build message history for Ollama, with memory and MCP context as system prompt
	var systemParts []string
	if mem := a.memory.SystemPrompt(); mem != "" {
		systemParts = append(systemParts, mem)
	}
	if tools := a.mcpManager.ToolSummary(); tools != "" {
		systemParts = append(systemParts, tools)
	}

	a.mu.Lock()
	var history []ollama.Message
	if len(systemParts) > 0 {
		history = append(history, ollama.Message{
			Role:    "system",
			Content: strings.Join(systemParts, "\n\n"),
		})
	}
	for _, m := range a.messages {
		history = append(history, ollama.Message{Role: m.Role, Content: m.Content})
	}
	a.mu.Unlock()

	go func() {
		ctx, cancel := context.WithTimeout(context.Background(), 10*time.Minute)
		defer cancel()

		// Check if the user is asking for a web search via natural language
		if query, ok := websearch.DetectQuery(prompt); ok {
			a.searchAndStream(ctx, query, history)
			return
		}

		var builder strings.Builder

		err := a.client.ChatStream(ctx, a.model, history, func(chunk string) error {
			builder.WriteString(chunk)
			runtime.EventsEmit(a.ctx, "chat:token", chunk)
			return nil
		})

		if err != nil {
			runtime.EventsEmit(a.ctx, "chat:error", err.Error())
			return
		}

		response := builder.String()
		a.mu.Lock()
		a.messages = append(a.messages, ChatMessage{Role: "assistant", Content: response})
		a.mu.Unlock()

		runtime.EventsEmit(a.ctx, "chat:done", response)
	}()

	return nil
}

// handleSlashCommand processes a /command and emits results as chat messages.
func (a *App) handleSlashCommand(input string) error {
	parts := strings.SplitN(input, " ", 2)
	cmd := strings.ToLower(parts[0])
	arg := ""
	if len(parts) > 1 {
		arg = strings.TrimSpace(parts[1])
	}

	// Add the command to chat history so the user sees it
	a.mu.Lock()
	a.messages = append(a.messages, ChatMessage{Role: "user", Content: input})
	a.mu.Unlock()
	runtime.EventsEmit(a.ctx, "chat:message", ChatMessage{Role: "user", Content: input})

	switch cmd {
	case "/search":
		if arg == "" {
			a.emitSystemMessage("Usage: `/search <query>`")
			return nil
		}
		go func() {
			ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
			defer cancel()

			if a.model == "" {
				// No model — just show raw results
				a.emitSystemMessage("No model selected. Showing raw search results:")
				runtime.EventsEmit(a.ctx, "chat:searching", arg)
				results, err := websearch.Search(ctx, arg, 8)
				if err != nil {
					runtime.EventsEmit(a.ctx, "chat:error", fmt.Sprintf("Search failed: %s", err))
					return
				}
				a.emitSystemMessage(websearch.FormatResults(results))
				return
			}

			// Build history and stream through the model
			a.mu.Lock()
			history := make([]ollama.Message, len(a.messages))
			for i, m := range a.messages {
				history[i] = ollama.Message{Role: m.Role, Content: m.Content}
			}
			a.mu.Unlock()

			searchCtx, searchCancel := context.WithTimeout(context.Background(), 10*time.Minute)
			defer searchCancel()
			a.searchAndStream(searchCtx, arg, history)
		}()
		return nil

	case "/ingest":
		if arg == "" {
			a.emitSystemMessage("Usage: `/ingest <url>`")
			return nil
		}
		go func() {
			src := ingest.Source{
				URL:  arg,
				Type: ingest.ArticleType,
				Tags: []string{"chat-ingest"},
				Name: arg,
			}
			ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
			defer cancel()

			saved, err := a.orchestrator.IngestSingle(ctx, src)
			if err != nil {
				a.emitSystemMessage(fmt.Sprintf("Ingest failed: %s", err))
			} else {
				a.emitSystemMessage(fmt.Sprintf("Ingested %d documents from `%s`", saved, arg))
			}
		}()
		return nil

	case "/browse":
		if arg == "" {
			a.emitSystemMessage("Usage: `/browse <url>`")
			return nil
		}
		go func() {
			src := ingest.Source{
				URL:  arg,
				Type: ingest.BrowserType,
			}
			ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
			defer cancel()

			fetcher := ingest.NewFetcher(1)
			results := fetcher.FetchAll(ctx, []ingest.Source{src})

			if len(results) == 0 {
				a.emitSystemMessage(fmt.Sprintf("Browse failed for `%s`: no results", arg))
				return
			}
			if results[0].Error != nil {
				a.emitSystemMessage(fmt.Sprintf("Browse failed for `%s`: %v", arg, results[0].Error))
				return
			}

			content := results[0].Content
			if len(content) > 8000 {
				content = content[:8000] + "\n\n... (content truncated for chat display)"
			}

			a.emitSystemMessage(fmt.Sprintf("**Browse Result: %s**\n\n%s", arg, content))
		}()
		return nil

	case "/status":
		s := a.orchestrator.GetStatus()
		msg := fmt.Sprintf("**Pipeline Status**\n- Phase: %s\n- Queue: %d\n- Active: %s\n- Completed: %d\n- Failed: %d",
			s.Phase, s.QueueDepth, s.ActiveJob, s.CompletedJobs, s.FailedJobs)
		a.emitSystemMessage(msg)
		return nil

	case "/clear":
		a.ClearMessages()
		runtime.EventsEmit(a.ctx, "chat:cleared", true)
		return nil

	case "/remember":
		if arg == "" {
			a.emitSystemMessage("Usage: `/remember <fact or pattern to save>`")
			return nil
		}
		if err := a.memory.Add(arg); err != nil {
			a.emitSystemMessage(fmt.Sprintf("Failed to save memory: %s", err))
		} else {
			a.emitSystemMessage(fmt.Sprintf("Remembered: %s (%d total)", arg, a.memory.Count()))
		}
		return nil

	case "/forget":
		if arg == "" {
			a.emitSystemMessage("Usage: `/forget <number>`")
			return nil
		}
		var idx int
		if _, err := fmt.Sscanf(arg, "%d", &idx); err != nil {
			a.emitSystemMessage("Usage: `/forget <number>` — use `/memories` to see numbers")
			return nil
		}
		if err := a.memory.Remove(idx); err != nil {
			a.emitSystemMessage(err.Error())
		} else {
			a.emitSystemMessage(fmt.Sprintf("Forgot memory #%d (%d remaining)", idx, a.memory.Count()))
		}
		return nil

	case "/memories":
		a.emitSystemMessage(a.memory.FormatList())
		return nil

	case "/mcp":
		names := a.mcpManager.ServerNames()
		if len(names) == 0 {
			a.emitSystemMessage("No MCP servers connected. Add servers to `mcp.json`.")
			return nil
		}
		tools := a.mcpManager.AllTools()
		var b strings.Builder
		fmt.Fprintf(&b, "**Connected MCP Servers:** %s\n\n", strings.Join(names, ", "))
		fmt.Fprintf(&b, "**Available Tools (%d):**\n", len(tools))
		for _, t := range tools {
			fmt.Fprintf(&b, "- `%s` — %s\n", t.QualifiedName, t.Description)
		}
		a.emitSystemMessage(b.String())
		return nil

	case "/help":
		help := "**Available Commands**\n" +
			"- `/search <query>` — Search the web and summarize results\n" +
			"- `/ingest <url>` — Ingest a URL into the library\n" +
			"- `/browse <url>` — Fetch and render a URL using headless browser\n" +
			"- `/status` — Show pipeline status\n" +
			"- `/remember <text>` — Save a fact to persistent memory\n" +
			"- `/forget <number>` — Remove a memory by number\n" +
			"- `/memories` — List all saved memories\n" +
			"- `/mcp` — List connected MCP servers and tools\n" +
			"- `/clear` — Clear chat history\n" +
			"- `/help` — Show this message"
		a.emitSystemMessage(help)
		return nil

	default:
		a.emitSystemMessage(fmt.Sprintf("Unknown command: `%s`. Type `/help` for available commands.", cmd))
		return nil
	}
}

// emitSystemMessage sends a one-shot assistant message through the chat event system.
func (a *App) emitSystemMessage(content string) {
	a.mu.Lock()
	a.messages = append(a.messages, ChatMessage{Role: "assistant", Content: content})
	a.mu.Unlock()
	runtime.EventsEmit(a.ctx, "chat:token", content)
	runtime.EventsEmit(a.ctx, "chat:done", content)
}

// searchAndStream performs a web search, injects results into history, and streams the LLM response.
func (a *App) searchAndStream(ctx context.Context, query string, history []ollama.Message) {
	runtime.EventsEmit(a.ctx, "chat:searching", query)

	searchCtx, searchCancel := context.WithTimeout(ctx, 30*time.Second)
	defer searchCancel()

	results, err := websearch.Search(searchCtx, query, 8)
	if err != nil {
		runtime.EventsEmit(a.ctx, "chat:error", fmt.Sprintf("Web search failed: %s", err))
		return
	}

	// Inject search results as a system message before the user's prompt
	searchContext := ollama.Message{
		Role: "system",
		Content: fmt.Sprintf("The user asked you to search the web. Here are the search results for %q:\n\n%s\nSummarize and answer based on these results. Cite sources by number when relevant.",
			query, websearch.FormatResults(results)),
	}
	history = append(history[:len(history)-1], searchContext, history[len(history)-1])

	var builder strings.Builder
	err = a.client.ChatStream(ctx, a.model, history, func(chunk string) error {
		builder.WriteString(chunk)
		runtime.EventsEmit(a.ctx, "chat:token", chunk)
		return nil
	})

	if err != nil {
		runtime.EventsEmit(a.ctx, "chat:error", err.Error())
		return
	}

	response := builder.String()
	a.mu.Lock()
	a.messages = append(a.messages, ChatMessage{Role: "assistant", Content: response})
	a.mu.Unlock()
	runtime.EventsEmit(a.ctx, "chat:done", response)
}

// ClearMessages clears the chat history.
func (a *App) ClearMessages() {
	a.mu.Lock()
	defer a.mu.Unlock()
	a.messages = nil
}

// --- Ingestion ---

// StartIngest runs the ingestion pipeline.
func (a *App) StartIngest() IngestResult {
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
	defer cancel()

	saved, err := a.orchestrator.RunIngest(ctx)
	if err != nil {
		return IngestResult{Error: err.Error()}
	}
	return IngestResult{SavedCount: saved}
}

// IngestSource runs ingestion for a single source by URL.
func (a *App) IngestSource(sourceURL string) IngestResult {
	sources, err := ingest.LoadSources(filepath.Join(a.saveDir, "sources.json"))
	if err != nil {
		return IngestResult{Error: err.Error()}
	}

	var target *ingest.Source
	for _, s := range sources {
		if s.URL == sourceURL {
			target = &s
			break
		}
	}
	if target == nil {
		return IngestResult{Error: fmt.Sprintf("source not found: %s", sourceURL)}
	}

	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
	defer cancel()

	saved, err := a.orchestrator.IngestSingle(ctx, *target)
	if err != nil {
		return IngestResult{SavedCount: saved, Error: err.Error()}
	}
	return IngestResult{SavedCount: saved}
}

// --- Analysis ---

// StartAnalysis runs the analysis pipeline on documents explicitly added to the queue.
func (a *App) StartAnalysis() AnalysisResult {
	ctx, cancel := context.WithTimeout(context.Background(), analysisQueueTimeout)
	defer cancel()

	processed, err := a.orchestrator.RunAnalysis(ctx)
	if err != nil {
		return AnalysisResult{Error: err.Error()}
	}
	return AnalysisResult{ProcessedCount: processed}
}

// --- Status ---

// QueueDocument adds a single document to the analysis queue.
func (a *App) QueueDocument(path string) error {
	return a.orchestrator.QueueDocument(path)
}

// RemoveFromQueue removes a document from the analysis queue.
func (a *App) RemoveFromQueue(path string) {
	a.orchestrator.RemoveFromQueue(path)
}

// GetAnalysisQueue returns the tracked analysis queue.
func (a *App) GetAnalysisQueue() []orchestrator.QueueEntry {
	return a.orchestrator.GetAnalysisQueue()
}

// --- Sources ---

// GetSources returns the configured sources from sources.json.
func (a *App) GetSources() ([]ingest.Source, error) {
	return ingest.LoadSources(filepath.Join(a.saveDir, "sources.json"))
}

// AddSource adds a new source to sources.json.
func (a *App) AddSource(sourceURL string, sourceType string, tags []string, name string) error {
	path := filepath.Join(a.saveDir, "sources.json")
	sources, err := ingest.LoadSources(path)
	if err != nil {
		// If file doesn't exist yet, start fresh
		sources = []ingest.Source{}
	}

	// Check for duplicate URL
	for _, s := range sources {
		if s.URL == sourceURL {
			return fmt.Errorf("source already exists: %s", sourceURL)
		}
	}

	newSource := ingest.Source{
		URL:  sourceURL,
		Type: ingest.SourceType(sourceType),
		Tags: tags,
		Name: name,
	}

	sources = append(sources, newSource)
	return ingest.SaveSources(path, sources)
}

// DeleteSource removes a source from sources.json by URL.
func (a *App) DeleteSource(sourceURL string) error {
	path := filepath.Join(a.saveDir, "sources.json")
	sources, err := ingest.LoadSources(path)
	if err != nil {
		return err
	}

	filtered := make([]ingest.Source, 0, len(sources))
	for _, s := range sources {
		if s.URL != sourceURL {
			filtered = append(filtered, s)
		}
	}

	if len(filtered) == len(sources) {
		return fmt.Errorf("source not found: %s", sourceURL)
	}

	return ingest.SaveSources(path, filtered)
}

// --- Providers ---

// ProviderInfo is a provider config for the frontend (API key masked).
type ProviderInfo struct {
	Name    string `json:"name"`
	Type    string `json:"type"`
	BaseURL string `json:"baseUrl"`
	Model   string `json:"model"`
	Active  bool   `json:"active"`
	HasKey  bool   `json:"hasKey"`
}

// GetProviders returns all configured providers with masked API keys.
func (a *App) GetProviders() []ProviderInfo {
	all := a.providers.All()
	out := make([]ProviderInfo, len(all))
	for i, p := range all {
		out[i] = ProviderInfo{
			Name:    p.Name,
			Type:    string(p.Type),
			BaseURL: p.BaseURL,
			Model:   p.Model,
			Active:  p.Active,
			HasKey:  p.APIKey != "",
		}
	}
	return out
}

// AddProvider adds a new provider.
func (a *App) AddProvider(name, provType, baseURL, apiKey, model string) error {
	return a.providers.Add(provider.Config{
		Name:    name,
		Type:    provider.Type(provType),
		BaseURL: baseURL,
		APIKey:  apiKey,
		Model:   model,
	})
}

// RemoveProvider deletes a provider by name.
func (a *App) RemoveProvider(name string) error {
	return a.providers.Remove(name)
}

// SetActiveProvider marks a provider as the active one.
func (a *App) SetActiveProvider(name string) error {
	return a.providers.SetActive(name)
}

// TestProvider tests connectivity to a provider.
func (a *App) TestProvider(name string) (string, error) {
	return a.providers.TestConnection(context.Background(), name)
}

// --- Memory ---

// MemoryEntry is a single memory item for the frontend.
type MemoryEntry struct {
	Index     int    `json:"index"`
	CreatedAt string `json:"createdAt"`
	Text      string `json:"text"`
}

// GetMemories returns all saved memories.
func (a *App) GetMemories() []MemoryEntry {
	entries := a.memory.Entries()
	out := make([]MemoryEntry, len(entries))
	for i, e := range entries {
		out[i] = MemoryEntry{Index: i + 1, CreatedAt: e.CreatedAt, Text: e.Text}
	}
	return out
}

// AddMemory saves a new memory entry.
func (a *App) AddMemory(text string) error {
	return a.memory.Add(text)
}

// RemoveMemory deletes a memory by 1-based index.
func (a *App) RemoveMemory(index int) error {
	return a.memory.Remove(index)
}

// --- Scheduler ---

// GetJobs returns all scheduled jobs.
func (a *App) GetJobs() []scheduler.JobState {
	return a.scheduler.GetAll()
}

// AddJob creates a new scheduled job.
func (a *App) AddJob(id, jobType, cronStr string, enabled bool, customCmd, deliverTo string) error {
	j := scheduler.Job{
		ID:        id,
		Type:      scheduler.JobType(jobType),
		Cron:      cronStr,
		Enabled:   enabled,
		CustomCmd: customCmd,
		DeliverTo: deliverTo,
	}
	return a.scheduler.AddJob(j)
}

// UpdateJob modifies an existing scheduled job.
func (a *App) UpdateJob(id, jobType, cronStr string, enabled bool, customCmd, deliverTo string) error {
	j := scheduler.Job{
		ID:        id,
		Type:      scheduler.JobType(jobType),
		Cron:      cronStr,
		Enabled:   enabled,
		CustomCmd: customCmd,
		DeliverTo: deliverTo,
	}
	return a.scheduler.UpdateJob(j)
}

// DeleteJob removes a scheduled job.
func (a *App) DeleteJob(id string) error {
	return a.scheduler.DeleteJob(id)
}

// RunJobNow triggers a job immediately, ignoring its schedule.
func (a *App) RunJobNow(id string) error {
	return a.scheduler.RunNow(id)
}

// --- Calendar ---

// GetCalendarEvents returns all user-authored calendar events.
func (a *App) GetCalendarEvents() []calendar.Event {
	return a.calendar.All()
}

// AddCalendarEvent creates a calendar event for a specific date.
func (a *App) AddCalendarEvent(date, title, notes string) (calendar.Event, error) {
	return a.calendar.Add(date, title, notes)
}

// UpdateCalendarEvent updates an existing calendar event.
func (a *App) UpdateCalendarEvent(id, date, title, notes string) error {
	return a.calendar.Update(id, date, title, notes)
}

// DeleteCalendarEvent removes a calendar event.
func (a *App) DeleteCalendarEvent(id string) error {
	return a.calendar.Delete(id)
}

// --- Reports ---

// GetReportManifest returns the report manifest.
func (a *App) GetReportManifest() ([]library.ReportMeta, error) {
	manifestPath := filepath.Join(a.saveDir, "Library", "reports", "manifest.json")
	rm := library.NewReportManager(filepath.Join(a.saveDir, "Library"))
	_ = rm // we'll read the manifest directly

	data, err := readManifest(manifestPath)
	if err != nil {
		return nil, err
	}
	return data, nil
}

// GetReportContent reads a report file and returns the markdown content (frontmatter stripped).
func (a *App) GetReportContent(filename string) (string, error) {
	// Search across all date dirs
	reportsDir := filepath.Join(a.saveDir, "Library", "reports")
	dateDirs, err := os.ReadDir(reportsDir)
	if err != nil {
		return "", err
	}
	for _, d := range dateDirs {
		if !d.IsDir() {
			continue
		}
		path := filepath.Join(reportsDir, d.Name(), filename)
		data, err := os.ReadFile(path)
		if err == nil {
			content := string(data)
			// Strip frontmatter
			if strings.HasPrefix(content, "---\n") {
				if end := strings.Index(content[4:], "\n---"); end != -1 {
					content = strings.TrimSpace(content[4+end+4:])
				}
			}
			return content, nil
		}
	}
	return "", fmt.Errorf("report not found: %s", filename)
}

// --- Queue ---

// DocumentInfo is a lightweight summary of an ingested document.
type DocumentInfo struct {
	Filename  string `json:"filename"`
	Path      string `json:"path"`
	Date      string `json:"date"`
	SourceURL string `json:"sourceUrl"`
	Name      string `json:"name"`
	Excerpt   string `json:"excerpt"`
}

func (a *App) validateRawDocumentPath(path string) (string, error) {
	rawDir := filepath.Join(a.saveDir, "Library", "raw")
	absPath, err := filepath.Abs(path)
	if err != nil {
		return "", fmt.Errorf("invalid path: %w", err)
	}
	absRaw, _ := filepath.Abs(rawDir)
	if !strings.HasPrefix(absPath, absRaw+string(filepath.Separator)) {
		return "", fmt.Errorf("path is not inside the library")
	}
	return absPath, nil
}

// GetDocuments returns metadata for all ingested documents in Library/raw/.
func (a *App) GetDocuments() ([]DocumentInfo, error) {
	rawDir := filepath.Join(a.saveDir, "Library", "raw")
	var docs []DocumentInfo

	dateDirs, err := os.ReadDir(rawDir)
	if err != nil {
		if os.IsNotExist(err) {
			return docs, nil
		}
		return nil, err
	}

	for _, dateEntry := range dateDirs {
		if !dateEntry.IsDir() {
			continue
		}
		datePath := filepath.Join(rawDir, dateEntry.Name())
		files, err := os.ReadDir(datePath)
		if err != nil {
			continue
		}
		for _, f := range files {
			if f.IsDir() || filepath.Ext(f.Name()) != ".md" {
				continue
			}
			doc := DocumentInfo{
				Filename: f.Name(),
				Path:     filepath.Join(datePath, f.Name()),
				Date:     dateEntry.Name(),
			}
			// Extract name and URL from frontmatter without reading full file
			content, err := os.ReadFile(doc.Path)
			if err == nil {
				url, _ := extractFrontmatterField(string(content), "url")
				name, _ := extractFrontmatterField(string(content), "name")
				doc.SourceURL = url
				doc.Name = name
				doc.Excerpt = documentExcerpt(string(content), 34)
			}
			docs = append(docs, doc)
		}
	}

	return docs, nil
}

// GetDocumentContent reads a raw document file and returns markdown content with frontmatter stripped.
func (a *App) GetDocumentContent(path string) (string, error) {
	absPath, err := a.validateRawDocumentPath(path)
	if err != nil {
		return "", err
	}
	data, err := os.ReadFile(absPath)
	if err != nil {
		return "", fmt.Errorf("read document: %w", err)
	}
	content := string(data)
	if strings.HasPrefix(content, "---\n") {
		if end := strings.Index(content[4:], "\n---"); end != -1 {
			content = strings.TrimSpace(content[4+end+4:])
		}
	}
	return content, nil
}

// DeleteDocument removes a raw document file from the library.
// Reports and queue entries referencing this document are intentionally preserved.
func (a *App) DeleteDocument(path string) error {
	absPath, err := a.validateRawDocumentPath(path)
	if err != nil {
		return err
	}

	if err := os.Remove(absPath); err != nil {
		return fmt.Errorf("delete document: %w", err)
	}

	// Clean up empty date directory if it's now empty
	dir := filepath.Dir(absPath)
	entries, err := os.ReadDir(dir)
	if err == nil && len(entries) == 0 {
		os.Remove(dir)
	}

	return nil
}

// PendingFile is a document waiting in the analysis queue.
type PendingFile struct {
	Filename string `json:"filename"`
	Path     string `json:"path"`
	Date     string `json:"date"`
}

// GetPendingFiles returns the list of unprocessed files.
func (a *App) GetPendingFiles() ([]PendingFile, error) {
	queueFile := filepath.Join(a.saveDir, "Library", "queue.json")
	qMgr, err := queue.NewManager(queueFile)
	if err != nil {
		return nil, err
	}

	rawDir := filepath.Join(a.saveDir, "Library", "raw")
	paths, err := qMgr.GetPendingFiles(rawDir)
	if err != nil {
		return nil, err
	}

	var pending []PendingFile
	for _, p := range paths {
		pending = append(pending, PendingFile{
			Filename: filepath.Base(p),
			Path:     p,
			Date:     filepath.Base(filepath.Dir(p)),
		})
	}
	return pending, nil
}

// extractFrontmatterField extracts a single field value from YAML frontmatter.
func extractFrontmatterField(content, field string) (string, bool) {
	if !strings.HasPrefix(content, "---\n") {
		return "", false
	}
	end := strings.Index(content[4:], "\n---")
	if end == -1 {
		return "", false
	}
	fm := content[4 : 4+end]
	for _, line := range strings.Split(fm, "\n") {
		line = strings.TrimSpace(line)
		if strings.HasPrefix(line, field+":") {
			val := strings.TrimSpace(strings.TrimPrefix(line, field+":"))
			val = strings.Trim(val, `"`)
			return val, true
		}
	}
	return "", false
}

func documentExcerpt(content string, maxWords int) string {
	if strings.HasPrefix(content, "---\n") {
		if end := strings.Index(content[4:], "\n---"); end != -1 {
			content = content[4+end+4:]
		}
	}

	replacer := strings.NewReplacer(
		"#", "",
		"*", "",
		"`", "",
		"[", "",
		"]", "",
		"(", "",
		")", "",
		">", "",
	)
	words := strings.Fields(replacer.Replace(content))
	if len(words) == 0 {
		return ""
	}
	if len(words) > maxWords {
		words = words[:maxWords]
		return strings.Join(words, " ") + "..."
	}
	return strings.Join(words, " ")
}

// WebhookInfo is a webhook config for the frontend with the secret masked.
type WebhookInfo struct {
	Name      string `json:"name"`
	Action    string `json:"action"`
	CustomCmd string `json:"customCmd,omitempty"`
	DeliverTo string `json:"deliverTo,omitempty"`
	Enabled   bool   `json:"enabled"`
	HasSecret bool   `json:"hasSecret"`
}

// GetWebhooks returns all configured webhooks with secrets masked.
func (a *App) GetWebhooks() []WebhookInfo {
	hooks := a.webhooks.GetAll()
	out := make([]WebhookInfo, len(hooks))
	for i, h := range hooks {
		out[i] = WebhookInfo{
			Name:      h.Name,
			Action:    string(h.Action),
			CustomCmd: h.CustomCmd,
			DeliverTo: h.DeliverTo,
			Enabled:   h.Enabled,
			HasSecret: h.Secret != "",
		}
	}
	return out
}

// AddWebhook adds a new webhook.
func (a *App) AddWebhook(name string, action string, enabled bool, customCmd, deliverTo, secret string) error {
	return a.webhooks.AddHook(webhook.Hook{
		Name:      name,
		Secret:    secret,
		Action:    webhook.Action(action),
		Enabled:   enabled,
		CustomCmd: customCmd,
		DeliverTo: deliverTo,
	})
}

// DeleteWebhook removes a webhook.
func (a *App) DeleteWebhook(name string) error {
	return a.webhooks.DeleteHook(name)
}

// ToggleWebhook enables or disables a webhook.
func (a *App) ToggleWebhook(name string, enabled bool) error {
	hooks := a.webhooks.GetAll()
	for _, h := range hooks {
		if h.Name == name {
			h.Enabled = enabled
			return a.webhooks.UpdateHook(h)
		}
	}
	return fmt.Errorf("hook %q not found", name)
}

// GetDeliveryDestinations returns all delivery destinations.
func (a *App) GetDeliveryDestinations() []delivery.Destination {
	return a.delivery.GetAll()
}

// AddDeliveryDestination adds a new delivery target.
func (a *App) AddDeliveryDestination(name, destType, url, token, chatId string, enabled bool) error {
	return a.delivery.Add(delivery.Destination{
		Name:    name,
		Type:    delivery.DestinationType(destType),
		URL:     url,
		Token:   token,
		ChatID:  chatId,
		Enabled: enabled,
	})
}

// DeleteDeliveryDestination removes a delivery target.
func (a *App) DeleteDeliveryDestination(name string) error {
	return a.delivery.Delete(name)
}

// TestDeliveryDestination sends a test message to a specific destination.
func (a *App) TestDeliveryDestination(name string) error {
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	return a.delivery.Dispatch(ctx, name, delivery.Message{
		Title: "Buster Claw Connection Test",
		Body:  "This is a test message to verify your delivery settings are correct.",
	})
}

// GetHooks returns all configured reactive hooks.
func (a *App) GetHooks() []hooks.Hook {
	return a.hooks.GetAll()
}

// AddHook adds a new reactive hook.
func (a *App) AddHook(name, event, hookType, target string, async, enabled bool) error {
	return a.hooks.Add(hooks.Hook{
		Name:    name,
		Event:   hooks.Event(event),
		Type:    hooks.HookType(hookType),
		Target:  target,
		Async:   async,
		Enabled: enabled,
	})
}

// DeleteHook removes a reactive hook.
func (a *App) DeleteHook(name string) error {
	return a.hooks.Delete(name)
}
