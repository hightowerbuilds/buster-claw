package orchestrator

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"buster-claw/internal/ingest"
	"buster-claw/internal/intentions"
	"buster-claw/internal/library"
	"buster-claw/internal/ollama"
	"buster-claw/internal/queue"
)

// JobType identifies the kind of work.
type JobType int

const (
	JobIngest  JobType = iota
	JobAnalyze
)

// Job represents a single unit of work flowing through the pipeline.
type Job struct {
	Type       JobType
	SourceFile string // for analysis: path to raw doc
	Source     ingest.Source // for ingestion: the source to fetch
}

// Status exposes the orchestrator's current state to the TUI.
type Status struct {
	Phase           string
	QueueDepth      int
	ActiveJob       string
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
	model          string
	saveDir        string
	libraryDir     string
	intentionsFile string
	sourcesFile    string

	analysisQueue chan Job
	statusMu      sync.RWMutex
	status         Status

	// Tracked queue for UI visibility
	trackedQueue []QueueEntry
	trackedMu    sync.RWMutex

	// OnStatusChange is called whenever the status changes. Optional.
	OnStatusChange func(Status)
}

// New creates an Orchestrator.
func New(client *ollama.Client, model, saveDir string) *Orchestrator {
	return &Orchestrator{
		client:         client,
		model:          model,
		saveDir:        saveDir,
		libraryDir:     filepath.Join(saveDir, "Library"),
		intentionsFile: filepath.Join(saveDir, "Intentions.md"),
		sourcesFile:    filepath.Join(saveDir, "sources.json"),
		analysisQueue:  make(chan Job, 100),
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
	o.trackedMu.Lock()
	// Don't add duplicates
	for _, e := range o.trackedQueue {
		if e.Path == path {
			o.trackedMu.Unlock()
			return
		}
	}
	o.trackedQueue = append(o.trackedQueue, QueueEntry{
		Filename: filepath.Base(path),
		Path:     path,
		Status:   "queued",
	})
	o.trackedMu.Unlock()

	o.analysisQueue <- Job{Type: JobAnalyze, SourceFile: path}
	o.updateStatus(func(s *Status) {
		s.QueueDepth = len(o.analysisQueue)
	})
}

// GetAnalysisQueue returns the current tracked queue entries.
func (o *Orchestrator) GetAnalysisQueue() []QueueEntry {
	o.trackedMu.RLock()
	defer o.trackedMu.RUnlock()
	out := make([]QueueEntry, len(o.trackedQueue))
	copy(out, o.trackedQueue)
	return out
}

// ClearCompletedQueue removes done/failed entries from the tracked queue.
func (o *Orchestrator) ClearCompletedQueue() {
	o.trackedMu.Lock()
	defer o.trackedMu.Unlock()
	var active []QueueEntry
	for _, e := range o.trackedQueue {
		if e.Status == "queued" || e.Status == "analyzing" {
			active = append(active, e)
		}
	}
	o.trackedQueue = active
}

func (o *Orchestrator) setTrackedStatus(path, status string) {
	o.trackedMu.Lock()
	defer o.trackedMu.Unlock()
	for i := range o.trackedQueue {
		if o.trackedQueue[i].Path == path {
			o.trackedQueue[i].Status = status
			break
		}
	}
}

// RunIngest fetches all configured sources (including RSS expansion),
// saves them to the Library, then queues each new file for analysis.
// Returns the number of files saved.
func (o *Orchestrator) RunIngest(ctx context.Context) (int, error) {
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

		// Queue for analysis
		o.analysisQueue <- Job{
			Type:       JobAnalyze,
			SourceFile: path,
		}
		saved++
		o.updateStatus(func(s *Status) {
			s.CompletedJobs++
			s.QueueDepth = len(o.analysisQueue)
		})
	}

	if saved == 0 && lastErr != nil {
		return 0, fmt.Errorf("all fetches failed, last: %w", lastErr)
	}

	return saved, nil
}

// IngestSingle fetches a single source (with RSS expansion if needed),
// saves results to the Library, and queues them for analysis.
func (o *Orchestrator) IngestSingle(ctx context.Context, source ingest.Source) (int, error) {
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

		o.analysisQueue <- Job{
			Type:       JobAnalyze,
			SourceFile: path,
		}
		saved++
		o.updateStatus(func(s *Status) {
			s.CompletedJobs++
			s.QueueDepth = len(o.analysisQueue)
		})
	}

	if saved == 0 && lastErr != nil {
		return 0, fmt.Errorf("all fetches failed for %s: %w", source.URL, lastErr)
	}

	return saved, nil
}

// RunAnalysis processes the analysis queue sequentially — one document at a time.
// It blocks until the queue is drained or the context is cancelled.
func (o *Orchestrator) RunAnalysis(ctx context.Context) (int, error) {
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

	for {
		select {
		case <-ctx.Done():
			return processed, ctx.Err()
		case job, ok := <-o.analysisQueue:
			if !ok {
				return processed, lastErr
			}

			o.setTrackedStatus(job.SourceFile, "analyzing")
			o.updateStatus(func(s *Status) {
				s.ActiveJob = filepath.Base(job.SourceFile)
				s.QueueDepth = len(o.analysisQueue)
				s.Phase = fmt.Sprintf("analyzing: %s", filepath.Base(job.SourceFile))
			})

			err := o.analyzeOne(ctx, job, ints, qMgr, reportMgr, reportsDir)
			if err != nil {
				lastErr = err
				o.setTrackedStatus(job.SourceFile, "failed")
				o.updateStatus(func(s *Status) { s.FailedJobs++ })
				continue
			}

			o.setTrackedStatus(job.SourceFile, "done")
			processed++
			o.updateStatus(func(s *Status) {
				s.CompletedJobs++
				s.ActiveJob = ""
				s.QueueDepth = len(o.analysisQueue)
			})

			// If queue is empty and ingestion isn't running, we're done
			if len(o.analysisQueue) == 0 {
				o.statusMu.RLock()
				ingesting := o.status.IngestRunning
				o.statusMu.RUnlock()
				if !ingesting {
					return processed, lastErr
				}
			}
		}
	}
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
		o.analysisQueue <- Job{Type: JobAnalyze, SourceFile: f}
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

	messages := []ollama.Message{
		{Role: "system", Content: systemPrompt},
		{Role: "user", Content: userPrompt.String()},
	}

	var builder strings.Builder
	ctxChat, cancelChat := context.WithTimeout(ctx, 3*time.Minute)
	err = o.client.ChatStream(ctxChat, o.model, messages, func(chunk string) error {
		builder.WriteString(chunk)
		return nil
	})
	cancelChat()

	if err != nil {
		return fmt.Errorf("analysis failed for %s: %w", filepath.Base(job.SourceFile), err)
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
