package orchestrator

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"buster-claw/internal/agent"
	"buster-claw/internal/delivery"
	"buster-claw/internal/hooks"
	"buster-claw/internal/ingest"
	"buster-claw/internal/intentions"
	"buster-claw/internal/library"
	"buster-claw/internal/ollama"
	"buster-claw/internal/provider"
	"buster-claw/internal/queue"
)

// JobType identifies the kind of work.
type JobType int

const (
	JobIngest JobType = iota
	JobAnalyze
)

// Job represents a single unit of work flowing through the pipeline.
type Job struct {
	Type       JobType
	SourceFile string        // for analysis: path to raw doc
	Source     ingest.Source // for ingestion: the source to fetch
}

// Status exposes the orchestrator's current state to the TUI.
type Status struct {
	Phase           string
	QueueDepth      int
	ActiveJob       string   // Legacy for single-worker mode
	ActiveJobs      []string // For parallel mode
	CompletedJobs   int
	FailedJobs      int
	IngestRunning   bool
	AnalysisRunning bool
}

// QueueEntry tracks a document's state in the analysis queue.
type QueueEntry struct {
	Filename string `json:"filename"`
	Path     string `json:"path"`
	Status   string `json:"status"` // "queued", "analyzing", "done", "failed"
}

// Orchestrator coordinates the full pipeline: ingest → queue → analyze → report.
// Ingestion runs concurrently. Analysis is gated — one document at a time.
type Orchestrator struct {
	client         *ollama.Client
	providers      *provider.Manager
	delivery       *delivery.Manager
	hooks          *hooks.Manager
	model          string
	saveDir        string
	libraryDir     string
	intentionsFile string
	sourcesFile    string

	WorkerCount    int

	statusMu sync.RWMutex
	status   Status

	queue   []QueueEntry
	queueMu sync.RWMutex

	// OnStatusChange is called whenever the status changes. Optional.
	OnStatusChange func(Status)
}

// New creates an Orchestrator.
func New(client *ollama.Client, providers *provider.Manager, delivery *delivery.Manager, h *hooks.Manager, model, saveDir string) *Orchestrator {
	return &Orchestrator{
		client:         client,
		providers:      providers,
		delivery:       delivery,
		hooks:          h,
		model:          model,
		saveDir:        saveDir,
		libraryDir:     filepath.Join(saveDir, "Library"),
		intentionsFile: filepath.Join(saveDir, "Intentions.md"),
		sourcesFile:    filepath.Join(saveDir, "sources.json"),
		WorkerCount:    1,
	}
}

// GetStatus returns the current orchestrator status.
func (o *Orchestrator) GetStatus() Status {
	o.statusMu.RLock()
	defer o.statusMu.RUnlock()
	return o.status
}

func (o *Orchestrator) updateStatus(fn func(*Status)) {
	o.statusMu.Lock()
	fn(&o.status)
	s := o.status
	o.statusMu.Unlock()

	if o.OnStatusChange != nil {
		o.OnStatusChange(s)
	}
}

// QueueDocument adds a single document to the analysis queue.
func (o *Orchestrator) QueueDocument(path string) {
	o.enqueueAnalysis(path)
}

// GetAnalysisQueue returns the current tracked queue entries.
func (o *Orchestrator) GetAnalysisQueue() []QueueEntry {
	o.queueMu.RLock()
	defer o.queueMu.RUnlock()
	out := make([]QueueEntry, len(o.queue))
	copy(out, o.queue)
	return out
}

// ClearCompletedQueue removes done/failed entries from the tracked queue.
func (o *Orchestrator) ClearCompletedQueue() {
	o.queueMu.Lock()
	defer o.queueMu.Unlock()
	var active []QueueEntry
	for _, e := range o.queue {
		if e.Status == "queued" || e.Status == "analyzing" {
			active = append(active, e)
		}
	}
	o.queue = active
}

// RemoveFromQueue removes a single non-running entry from the analysis queue by path.
func (o *Orchestrator) RemoveFromQueue(path string) {
	o.queueMu.Lock()
	filtered := make([]QueueEntry, 0, len(o.queue))
	for _, e := range o.queue {
		if e.Path != path || e.Status == "analyzing" {
			filtered = append(filtered, e)
		}
	}
	o.queue = filtered
	depth := countQueued(o.queue)
	o.queueMu.Unlock()

	o.updateStatus(func(s *Status) {
		s.QueueDepth = depth
	})
}

func (o *Orchestrator) enqueueAnalysis(path string) bool {
	o.queueMu.Lock()
	for _, e := range o.queue {
		if e.Path == path {
			o.queueMu.Unlock()
			return false
		}
	}
	o.queue = append(o.queue, QueueEntry{
		Filename: filepath.Base(path),
		Path:     path,
		Status:   "queued",
	})
	depth := countQueued(o.queue)
	o.queueMu.Unlock()

	o.updateStatus(func(s *Status) {
		s.QueueDepth = depth
	})
	return true
}

func (o *Orchestrator) takeNextQueued() (Job, bool) {
	o.queueMu.Lock()
	defer o.queueMu.Unlock()
	for i := range o.queue {
		if o.queue[i].Status == "queued" {
			o.queue[i].Status = "analyzing"
			return Job{Type: JobAnalyze, SourceFile: o.queue[i].Path}, true
		}
	}
	return Job{}, false
}

func (o *Orchestrator) setQueueStatus(path, status string) {
	o.queueMu.Lock()
	defer o.queueMu.Unlock()
	for i := range o.queue {
		if o.queue[i].Path == path {
			o.queue[i].Status = status
			return
		}
	}
}

func (o *Orchestrator) queuedDepth() int {
	o.queueMu.RLock()
	defer o.queueMu.RUnlock()
	return countQueued(o.queue)
}

func countQueued(entries []QueueEntry) int {
	count := 0
	for _, e := range entries {
		if e.Status == "queued" {
			count++
		}
	}
	return count
}

// RunIngest fetches all configured sources (including RSS expansion),
// saves them to the Library, then queues each new file for analysis.
// Returns the number of files saved.
func (o *Orchestrator) RunIngest(ctx context.Context) (int, error) {
	o.hooks.Trigger(hooks.PreIngest, nil)
	o.updateStatus(func(s *Status) {
		s.Phase = "ingesting"
		s.IngestRunning = true
	})
	defer o.updateStatus(func(s *Status) {
		s.IngestRunning = false
		if !s.AnalysisRunning {
			s.Phase = "idle"
		}
	})

	sources, err := ingest.LoadSources(o.sourcesFile)
	if err != nil {
		return 0, fmt.Errorf("load sources: %w", err)
	}
	if len(sources) == 0 {
		return 0, fmt.Errorf("no sources configured")
	}

	// Expand RSS
	var fetchable []ingest.Source
	for _, src := range sources {
		if src.Type == ingest.RSSType {
			entries, err := ingest.FetchRSSEntries(ctx, src)
			if err != nil {
				continue
			}
			fetchable = append(fetchable, entries...)
		} else {
			fetchable = append(fetchable, src)
		}
	}

	if len(fetchable) == 0 {
		return 0, fmt.Errorf("no fetchable sources after RSS expansion")
	}

	o.updateStatus(func(s *Status) {
		s.Phase = fmt.Sprintf("fetching %d sources", len(fetchable))
	})

	fetcher := ingest.NewFetcher(5)
	results := fetcher.FetchAll(ctx, fetchable)

	libMgr := library.NewManager(o.libraryDir)
	saved := 0
	var lastErr error

	for _, r := range results {
		if r.Error != nil {
			lastErr = r.Error
			o.updateStatus(func(s *Status) { s.FailedJobs++ })
			continue
		}
		path, err := libMgr.SaveResult(r)
		if err != nil {
			lastErr = err
			o.updateStatus(func(s *Status) { s.FailedJobs++ })
			continue
		}

		o.enqueueAnalysis(path)
		saved++
		o.updateStatus(func(s *Status) {
			s.CompletedJobs++
			s.QueueDepth = o.queuedDepth()
		})
	}

	if saved == 0 && lastErr != nil {
		o.hooks.Trigger(hooks.OnError, map[string]string{"error": lastErr.Error(), "phase": "ingest"})
		return 0, fmt.Errorf("all fetches failed, last: %w", lastErr)
	}

	o.hooks.Trigger(hooks.PostIngest, map[string]int{"saved": saved})
	return saved, nil
}

// IngestSingle fetches a single source (with RSS expansion if needed),
// saves results to the Library, and queues them for analysis.
func (o *Orchestrator) IngestSingle(ctx context.Context, source ingest.Source) (int, error) {
	o.hooks.Trigger(hooks.PreIngest, source)
	o.updateStatus(func(s *Status) {
		s.Phase = fmt.Sprintf("ingesting: %s", source.Name)
		s.IngestRunning = true
	})
	defer o.updateStatus(func(s *Status) {
		s.IngestRunning = false
		if !s.AnalysisRunning {
			s.Phase = "idle"
		}
	})

	var fetchable []ingest.Source
	if source.Type == ingest.RSSType {
		entries, err := ingest.FetchRSSEntries(ctx, source)
		if err != nil {
			return 0, fmt.Errorf("expand rss %s: %w", source.URL, err)
		}
		fetchable = entries
	} else {
		fetchable = []ingest.Source{source}
	}

	if len(fetchable) == 0 {
		return 0, fmt.Errorf("no fetchable content from %s", source.URL)
	}

	o.updateStatus(func(s *Status) {
		s.Phase = fmt.Sprintf("fetching %d from %s", len(fetchable), source.Name)
	})

	fetcher := ingest.NewFetcher(5)
	results := fetcher.FetchAll(ctx, fetchable)

	libMgr := library.NewManager(o.libraryDir)
	saved := 0
	var lastErr error

	for _, r := range results {
		if r.Error != nil {
			lastErr = r.Error
			o.updateStatus(func(s *Status) { s.FailedJobs++ })
			continue
		}
		path, err := libMgr.SaveResult(r)
		if err != nil {
			lastErr = err
			o.updateStatus(func(s *Status) { s.FailedJobs++ })
			continue
		}

		o.enqueueAnalysis(path)
		saved++
		o.updateStatus(func(s *Status) {
			s.CompletedJobs++
			s.QueueDepth = o.queuedDepth()
		})
	}

	if saved == 0 && lastErr != nil {
		o.hooks.Trigger(hooks.OnError, map[string]string{"error": lastErr.Error(), "phase": "ingest_single", "url": source.URL})
		return 0, fmt.Errorf("all fetches failed for %s: %w", source.URL, lastErr)
	}

	o.hooks.Trigger(hooks.PostIngest, map[string]any{"saved": saved, "source": source})
	return saved, nil
}

// RunAnalysis processes the analysis queue sequentially — one document at a time.
// It blocks until the queue is drained or the context is cancelled.
func (o *Orchestrator) RunAnalysis(ctx context.Context) (int, error) {
	o.hooks.Trigger(hooks.PreAnalysis, nil)
	o.updateStatus(func(s *Status) {
		s.Phase = "analyzing"
		s.AnalysisRunning = true
	})
	defer o.updateStatus(func(s *Status) {
		s.AnalysisRunning = false
		if !s.IngestRunning {
			s.Phase = "idle"
		}
	})

	ints, err := intentions.Load(o.intentionsFile)
	if err != nil {
		return 0, fmt.Errorf("load intentions: %w", err)
	}

	queueFile := filepath.Join(o.libraryDir, "queue.json")
	qMgr, err := queue.NewManager(queueFile)
	if err != nil {
		return 0, fmt.Errorf("init queue manager: %w", err)
	}

	reportMgr := library.NewReportManager(o.libraryDir)
	reportsDir, err := reportMgr.DateDir()
	if err != nil {
		return 0, err
	}

	processed := 0
	var lastErr error
	var processedMu sync.Mutex

	workerCount := o.WorkerCount
	if workerCount <= 0 {
		workerCount = 1
	}

	// We only parallelize if an external provider is active.
	// Local Ollama usually handles one request at a time efficiently.
	hasProvider := false
	for _, p := range o.providers.All() {
		if p.Active && p.Type != provider.TypeOllama {
			hasProvider = true
			break
		}
	}
	if !hasProvider {
		workerCount = 1
	}

	pool := agent.NewAgentPool(workerCount)
	defer pool.Close()

	var wg sync.WaitGroup
	errCh := make(chan error, workerCount)

	for _, worker := range pool.Workers {
		wg.Add(1)
		go func(w *agent.Agent) {
			defer wg.Done()
			for {
				select {
				case <-pool.Ctx.Done():
					return
				default:
					job, ok := o.takeNextQueued()
					if !ok {
						o.statusMu.RLock()
						ingesting := o.status.IngestRunning
						o.statusMu.RUnlock()
						if !ingesting {
							return
						}
						time.Sleep(200 * time.Millisecond)
						continue
					}

					w.Mu.Lock()
					w.IsWorking = true
					w.Mu.Unlock()

					jobName := filepath.Base(job.SourceFile)
					o.updateStatus(func(s *Status) {
						s.QueueDepth = o.queuedDepth()
						s.ActiveJobs = append(s.ActiveJobs, jobName)
						if workerCount == 1 {
							s.ActiveJob = jobName
							s.Phase = fmt.Sprintf("analyzing: %s", jobName)
						} else {
							s.Phase = fmt.Sprintf("analyzing %d in parallel", len(s.ActiveJobs))
						}
					})

					err := o.analyzeOne(ctx, job, ints, qMgr, reportMgr, reportsDir)
					
					o.updateStatus(func(s *Status) {
						var filtered []string
						for _, aj := range s.ActiveJobs {
							if aj != jobName {
								filtered = append(filtered, aj)
							}
						}
						s.ActiveJobs = filtered

						if err != nil {
							s.FailedJobs++
						} else {
							s.CompletedJobs++
						}
						
						if workerCount == 1 {
							s.ActiveJob = ""
						}
						s.QueueDepth = o.queuedDepth()
					})

					w.Mu.Lock()
					w.IsWorking = false
					w.Mu.Unlock()

					if err != nil {
						o.setQueueStatus(job.SourceFile, "failed")
						errCh <- err
						continue
					}

					processedMu.Lock()
					processed++
					processedMu.Unlock()

					o.setQueueStatus(job.SourceFile, "done")
				}
			}
		}(worker)
	}

	wg.Wait()
	close(errCh)

	for err := range errCh {
		lastErr = err
	}

	if lastErr != nil {
		o.hooks.Trigger(hooks.OnError, map[string]string{"error": lastErr.Error(), "phase": "analysis"})
	}

	o.hooks.Trigger(hooks.PostAnalysis, map[string]int{"processed": processed})
	return processed, lastErr
}

// RunFull executes ingestion and analysis as a coordinated pipeline.
// Ingestion runs first, queuing files. Then analysis processes them sequentially.
func (o *Orchestrator) RunFull(ctx context.Context) (ingested int, analyzed int, err error) {
	ingested, err = o.RunIngest(ctx)
	if err != nil {
		return ingested, 0, err
	}

	analyzed, err = o.RunAnalysis(ctx)
	return ingested, analyzed, err
}

// DrainQueue processes any pending files in Library/raw that haven't been analyzed yet.
func (o *Orchestrator) DrainQueue(ctx context.Context) (int, error) {
	queueFile := filepath.Join(o.libraryDir, "queue.json")
	qMgr, err := queue.NewManager(queueFile)
	if err != nil {
		return 0, fmt.Errorf("init queue manager: %w", err)
	}

	rawDir := filepath.Join(o.libraryDir, "raw")
	pending, err := qMgr.GetPendingFiles(rawDir)
	if err != nil {
		return 0, fmt.Errorf("get pending files: %w", err)
	}

	for _, f := range pending {
		o.enqueueAnalysis(f)
	}

	if len(pending) == 0 {
		return 0, nil
	}

	return o.RunAnalysis(ctx)
}

const (
	fileOpenMarker  = "<<FILE:"
	fileCloseMarker = "<<END FILE>>"
)

func (o *Orchestrator) analyzeOne(
	ctx context.Context,
	job Job,
	ints *intentions.Intentions,
	qMgr *queue.Manager,
	reportMgr *library.ReportManager,
	reportsDir string,
) error {
	o.hooks.Trigger(hooks.PreReport, job)
	content, err := os.ReadFile(job.SourceFile)
	if err != nil {
		return fmt.Errorf("read %s: %w", filepath.Base(job.SourceFile), err)
	}

	docContent := string(content)
	sourceURL, sourceTags := extractFrontmatterMeta(docContent)
	docBody := stripFrontmatter(docContent)

	systemPrompt := ints.AnalysisPrompt() + "\n\n" + strings.Join([]string{
		"You are analyzing a single document. Focus entirely on this document.",
		"You MUST return exactly ONE file block using this format:",
		fileOpenMarker + "report-<topic>.md>>",
		"# Report Title",
		"report content here",
		fileCloseMarker,
		"",
		"Rules:",
		"- The filename must end in .md and be prefixed with 'report-'.",
		"- Follow the Output Format defined in the Intentions above.",
		"- Include an Executive Summary, Key Takeaways, and Action Items.",
		"- Be specific and concrete — reference actual tools, frameworks, or steps from the source.",
		"- Do not wrap the file block in triple backticks.",
		"- Do not add any text before or after the file block.",
	}, "\n")

	var userPrompt strings.Builder
	if sourceURL != "" {
		userPrompt.WriteString(fmt.Sprintf("Source: %s\n", sourceURL))
	}
	if len(sourceTags) > 0 {
		userPrompt.WriteString(fmt.Sprintf("Tags: %s\n", strings.Join(sourceTags, ", ")))
	}
	userPrompt.WriteString(fmt.Sprintf("File: %s\n\n", filepath.Base(job.SourceFile)))
	userPrompt.WriteString("Analyze this document:\n\n")
	userPrompt.WriteString(docBody)

	var builder strings.Builder
	ctxChat, cancelChat := context.WithTimeout(ctx, 3*time.Minute)
	defer cancelChat()

	var chatErr error

	// Check if any external provider is active
	var activeProv *provider.Config
	for _, p := range o.providers.All() {
		if p.Active {
			cp := p
			activeProv = &cp
			break
		}
	}

	if activeProv != nil && activeProv.Type != provider.TypeOllama {
		provMsgs := []provider.Message{
			{Role: "system", Content: systemPrompt},
			{Role: "user", Content: userPrompt.String()},
		}
		chatErr = o.providers.ChatWithActive(ctxChat, provMsgs, func(chunk string) error {
			builder.WriteString(chunk)
			return nil
		})
	} else {
		ollamaMsgs := []ollama.Message{
			{Role: "system", Content: systemPrompt},
			{Role: "user", Content: userPrompt.String()},
		}
		chatErr = o.client.ChatStream(ctxChat, o.model, ollamaMsgs, func(chunk string) error {
			builder.WriteString(chunk)
			return nil
		})
	}

	if chatErr != nil {
		return fmt.Errorf("analysis failed for %s: %w", filepath.Base(job.SourceFile), chatErr)
	}

	rawResponse := builder.String()
	spec, found, parseErr := extractMarkdownBlock(rawResponse)
	if parseErr != nil {
		return fmt.Errorf("extract report for %s: %w", filepath.Base(job.SourceFile), parseErr)
	}
	if !found {
		return fmt.Errorf("no valid markdown block for %s", filepath.Base(job.SourceFile))
	}

	now := time.Now().Format(time.RFC3339)
	meta := library.ReportMeta{
		Filename:       spec.name,
		SourceFile:     filepath.Base(job.SourceFile),
		SourceURL:      sourceURL,
		GeneratedAt:    now,
		Model:          o.model,
		IntentionsUsed: true,
		Tags:           sourceTags,
	}

	fullContent := library.BuildReportFrontmatter(meta) + spec.content + "\n"
	outPath := filepath.Join(reportsDir, filepath.Base(spec.name))
	if err := os.WriteFile(outPath, []byte(fullContent), 0644); err != nil {
		return fmt.Errorf("write report: %w", err)
	}

	if err := reportMgr.AppendManifest(meta); err != nil {
		// Non-fatal — report was saved
	}

	o.hooks.Trigger(hooks.PostReport, meta)

	// Dispatch to delivery destinations
	go func() {
		dispatchCtx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
		defer cancel()
		o.delivery.Dispatch(dispatchCtx, "", delivery.Message{
			Title: fmt.Sprintf("Buster Claw Report: %s", spec.name),
			Body:  spec.content,
		})
	}()

	return qMgr.MarkProcessed(job.SourceFile)
}

// --- frontmatter helpers (duplicated from tui to avoid circular import) ---

func extractFrontmatterMeta(content string) (string, []string) {
	if !strings.HasPrefix(content, "---\n") {
		return "", nil
	}
	end := strings.Index(content[4:], "\n---")
	if end == -1 {
		return "", nil
	}
	fm := content[4 : 4+end]

	var url string
	var tags []string
	for _, line := range strings.Split(fm, "\n") {
		line = strings.TrimSpace(line)
		if strings.HasPrefix(line, "url:") {
			url = strings.Trim(strings.TrimSpace(strings.TrimPrefix(line, "url:")), `"`)
		}
		if strings.HasPrefix(line, "tags:") {
			raw := strings.TrimSpace(strings.TrimPrefix(line, "tags:"))
			raw = strings.Trim(raw, "[]")
			for _, t := range strings.Split(raw, ",") {
				t = strings.Trim(strings.TrimSpace(t), `"`)
				if t != "" {
					tags = append(tags, t)
				}
			}
		}
	}
	return url, tags
}

func stripFrontmatter(content string) string {
	if !strings.HasPrefix(content, "---\n") {
		return content
	}
	end := strings.Index(content[4:], "\n---")
	if end == -1 {
		return content
	}
	return strings.TrimSpace(content[4+end+4:])
}

type markdownSpec struct {
	name    string
	content string
}

func extractMarkdownBlock(raw string) (markdownSpec, bool, error) {
	start := strings.Index(raw, fileOpenMarker)
	if start == -1 {
		return markdownSpec{}, false, nil
	}

	nameStart := start + len(fileOpenMarker)
	nameEnd := strings.Index(raw[nameStart:], ">>")
	if nameEnd == -1 {
		return markdownSpec{}, true, fmt.Errorf("missing file header terminator")
	}
	nameEnd += nameStart

	contentStart := nameEnd + 2
	end := strings.Index(raw[contentStart:], fileCloseMarker)
	if end == -1 {
		return markdownSpec{}, true, fmt.Errorf("missing %s marker", fileCloseMarker)
	}
	end += contentStart

	name := strings.TrimSpace(raw[nameStart:nameEnd])
	content := strings.TrimSpace(raw[contentStart:end])
	if name == "" {
		return markdownSpec{}, true, fmt.Errorf("missing markdown filename")
	}
	if content == "" {
		return markdownSpec{}, true, fmt.Errorf("generated markdown file is empty")
	}

	return markdownSpec{name: name, content: content}, true, nil
}
