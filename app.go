package main

import (
	"context"
	"fmt"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"buster-claw/internal/config"
	"buster-claw/internal/ingest"
	"buster-claw/internal/intentions"
	"buster-claw/internal/library"
	"buster-claw/internal/ollama"
	"buster-claw/internal/orchestrator"
	"buster-claw/internal/queue"

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
	Phase         string `json:"phase"`
	QueueDepth    int    `json:"queueDepth"`
	ActiveJob     string `json:"activeJob"`
	CompletedJobs int    `json:"completedJobs"`
	FailedJobs    int    `json:"failedJobs"`
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

// FullPipelineResult is returned after a full pipeline run.
type FullPipelineResult struct {
	Ingested int    `json:"ingested"`
	Analyzed int    `json:"analyzed"`
	Error    string `json:"error,omitempty"`
}

// NewApp creates a new App instance.
func NewApp(saveDir string) *App {
	cfg := config.Load()
	client := ollama.NewClient(cfg.Host)
	orch := orchestrator.New(client, cfg.Model, saveDir)

	return &App{
		client:       client,
		model:        cfg.Model,
		saveDir:      saveDir,
		orchestrator: orch,
	}
}

// startup is called when the Wails app starts.
func (a *App) startup(ctx context.Context) {
	a.ctx = ctx

	// Wire orchestrator status changes to frontend events.
	a.orchestrator.OnStatusChange = func(s orchestrator.Status) {
		runtime.EventsEmit(a.ctx, "orchestrator:status", OrchestratorStatus{
			Phase:         s.Phase,
			QueueDepth:    s.QueueDepth,
			ActiveJob:     s.ActiveJob,
			CompletedJobs: s.CompletedJobs,
			FailedJobs:    s.FailedJobs,
		})
	}
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
// Emits "chat:token" events as chunks arrive, and "chat:done" when complete.
func (a *App) SendMessage(prompt string) error {
	if a.model == "" {
		return fmt.Errorf("no model selected")
	}

	a.mu.Lock()
	a.messages = append(a.messages, ChatMessage{Role: "user", Content: prompt})
	a.mu.Unlock()

	runtime.EventsEmit(a.ctx, "chat:message", ChatMessage{Role: "user", Content: prompt})

	// Build message history for Ollama
	a.mu.Lock()
	history := make([]ollama.Message, len(a.messages))
	for i, m := range a.messages {
		history[i] = ollama.Message{Role: m.Role, Content: m.Content}
	}
	a.mu.Unlock()

	go func() {
		var builder strings.Builder

		ctx, cancel := context.WithTimeout(context.Background(), 3*time.Minute)
		defer cancel()

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

// --- Analysis ---

// StartAnalysis runs the analysis pipeline on pending documents.
func (a *App) StartAnalysis() AnalysisResult {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Minute)
	defer cancel()

	processed, err := a.orchestrator.DrainQueue(ctx)
	if err != nil {
		return AnalysisResult{Error: err.Error()}
	}
	return AnalysisResult{ProcessedCount: processed}
}

// --- Full Pipeline ---

// StartFullPipeline runs ingestion then analysis sequentially.
func (a *App) StartFullPipeline() FullPipelineResult {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Minute)
	defer cancel()

	ingested, analyzed, err := a.orchestrator.RunFull(ctx)
	if err != nil {
		return FullPipelineResult{Ingested: ingested, Analyzed: analyzed, Error: err.Error()}
	}
	return FullPipelineResult{Ingested: ingested, Analyzed: analyzed}
}

// --- Status ---

// GetOrchestratorStatus returns the current orchestrator state.
func (a *App) GetOrchestratorStatus() OrchestratorStatus {
	s := a.orchestrator.GetStatus()
	return OrchestratorStatus{
		Phase:         s.Phase,
		QueueDepth:    s.QueueDepth,
		ActiveJob:     s.ActiveJob,
		CompletedJobs: s.CompletedJobs,
		FailedJobs:    s.FailedJobs,
	}
}

// --- Sources ---

// GetSources returns the configured sources from sources.json.
func (a *App) GetSources() ([]ingest.Source, error) {
	return ingest.LoadSources(filepath.Join(a.saveDir, "sources.json"))
}

// --- Intentions ---

// GetIntentions returns the current Intentions.md content.
func (a *App) GetIntentions() (string, error) {
	ints, err := intentions.Load(filepath.Join(a.saveDir, "Intentions.md"))
	if err != nil {
		return "", err
	}
	return ints.Raw, nil
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

// --- Queue ---

// GetPendingCount returns the number of unprocessed files.
func (a *App) GetPendingCount() (int, error) {
	queueFile := filepath.Join(a.saveDir, "Library", "queue.json")
	qMgr, err := queue.NewManager(queueFile)
	if err != nil {
		return 0, err
	}

	rawDir := filepath.Join(a.saveDir, "Library", "raw")
	pending, err := qMgr.GetPendingFiles(rawDir)
	if err != nil {
		return 0, err
	}
	return len(pending), nil
}
