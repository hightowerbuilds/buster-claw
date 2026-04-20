package tui

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"github.com/charmbracelet/bubbles/textinput"
	"github.com/charmbracelet/bubbles/viewport"
	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"

	"buster-claw/internal/ingest"
	"buster-claw/internal/intentions"
	"buster-claw/internal/library"
	"buster-claw/internal/ollama"
	"buster-claw/internal/orchestrator"
	"buster-claw/internal/queue"
)

var (
	docStyle    = lipgloss.NewStyle().Padding(1, 2)
	headerStyle = lipgloss.NewStyle().
			Bold(true).
			Foreground(lipgloss.Color("63"))
	statusStyle = lipgloss.NewStyle().
			Foreground(lipgloss.Color("241"))
	userStyle = lipgloss.NewStyle().
			Bold(true).
			Foreground(lipgloss.Color("212"))
	assistantStyle = lipgloss.NewStyle().
			Bold(true).
			Foreground(lipgloss.Color("81"))
	errorStyle = lipgloss.NewStyle().
			Bold(true).
			Foreground(lipgloss.Color("204"))
	helpStyle = lipgloss.NewStyle().
			Foreground(lipgloss.Color("244"))
)

type tokenMsg struct {
	text string
}

type streamDoneMsg struct{}

type streamErrMsg struct {
	err error
}

type modelsMsg struct {
	models []string
}

type modelsErrMsg struct {
	err error
}

type ingestDoneMsg struct {
	savedCount int
	err        error
}

type analysisDoneMsg struct {
	processedCount int
	err            error
}

type fullDoneMsg struct {
	ingested int
	analyzed int
	err      error
}

type messageView struct {
	Role    string
	Content string
}

type Model struct {
	client       *ollama.Client
	model        string
	messages     []ollama.Message
	models       []string
	memories     []memoryEntry
	saveDir      string
	orchestrator *orchestrator.Orchestrator

	input    textinput.Model
	viewport viewport.Model

	width  int
	height int

	streaming bool
	status    string
	errText   string

	streamCh chan tea.Msg

	mu sync.Mutex
}

func NewModel(client *ollama.Client, defaultModel, saveDir string) Model {
	input := textinput.New()
	input.Placeholder = "Starting up..."
	input.Focus()
	input.CharLimit = 0
	input.Prompt = "› "
	input.Width = 80

	vp := viewport.New(0, 0)
	vp.SetContent("")

	memories, _ := loadMemory(saveDir)
	orch := orchestrator.New(client, defaultModel, saveDir)

	return Model{
		client:       client,
		model:        defaultModel,
		memories:     memories,
		saveDir:      saveDir,
		orchestrator: orch,
		input:        input,
		viewport:     vp,
		status:       initialStatus(defaultModel),
		streamCh:     make(chan tea.Msg),
	}
}

func (m Model) Init() tea.Cmd {
	return tea.Batch(
		m.waitForStream(),
		m.fetchModelsCmd(),
	)
}

func (m Model) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.WindowSizeMsg:
		m.width = msg.Width
		m.height = msg.Height
		m.resize()
		m.viewport.GotoBottom()
		return m, nil

	case tea.KeyMsg:
		switch msg.String() {
		case "ctrl+c", "q":
			return m, tea.Quit
		case "up", "k":
			m.viewport.LineUp(1)
			return m, nil
		case "down", "j":
			m.viewport.LineDown(1)
			return m, nil
		case "home":
			m.viewport.GotoTop()
			return m, nil
		case "end":
			m.viewport.GotoBottom()
			return m, nil
		case "pgup":
			m.viewport.HalfViewUp()
			return m, nil
		case "pgdown":
			m.viewport.HalfViewDown()
			return m, nil
		case "enter":
			if m.streaming {
				return m, nil
			}
			if !m.canChat() {
				m.errText = noModelError()
				m.refreshViewport()
				return m, nil
			}
			prompt := strings.TrimSpace(m.input.Value())
			if prompt == "" {
				return m, nil
			}
			m.input.SetValue("")
			if handled, cmd := m.handleCommand(prompt); handled {
				return m, cmd
			}
			return m.sendPrompt(prompt)
		}

		var cmd tea.Cmd
		m.input, cmd = m.input.Update(msg)
		return m, cmd

	case tea.MouseMsg:
		var cmd tea.Cmd
		m.viewport, cmd = m.viewport.Update(msg)
		return m, cmd

	case tokenMsg:
		m.mu.Lock()
		if len(m.messages) == 0 || m.messages[len(m.messages)-1].Role != "assistant" {
			m.messages = append(m.messages, ollama.Message{Role: "assistant"})
		}
		m.messages[len(m.messages)-1].Content += msg.text
		m.mu.Unlock()
		m.status = fmt.Sprintf("streaming · model %s", m.model)
		m.errText = ""
		m.refreshViewport()
		return m, m.waitForStream()

	case streamDoneMsg:
		m.streaming = false
		m.finalizeAssistantOutput()
		m.refreshViewport()
		return m, m.waitForStream()

	case streamErrMsg:
		m.streaming = false
		m.errText = humanizeStreamError(msg.err)
		m.status = "error"
		m.refreshViewport()
		return m, m.waitForStream()

	case modelsMsg:
		m.models = msg.models
		switch {
		case len(msg.models) == 0:
			m.model = ""
			m.status = "no models installed"
		case m.model == "":
			m.model = msg.models[0]
			m.status = fmt.Sprintf("ready · model %s · %d installed", m.model, len(msg.models))
		case contains(msg.models, m.model):
			m.status = fmt.Sprintf("ready · model %s · %d installed", m.model, len(msg.models))
		default:
			m.model = msg.models[0]
			m.status = fmt.Sprintf("selected model unavailable · switched to %s", m.model)
		}
		m.syncInputState()
		m.refreshViewport()
		return m, nil

	case modelsErrMsg:
		m.errText = msg.err.Error()
		m.status = "ollama unavailable"
		m.syncInputState()
		m.refreshViewport()
		return m, nil

	case ingestDoneMsg:
		if msg.err != nil {
			m.messages = append(m.messages, ollama.Message{Role: "assistant", Content: fmt.Sprintf("Ingestion failed: %v", msg.err)})
			m.errText = msg.err.Error()
			m.status = "ingestion error"
		} else {
			m.messages = append(m.messages, ollama.Message{Role: "assistant", Content: fmt.Sprintf("Ingestion complete. Saved %d files to Library.", msg.savedCount)})
			m.status = fmt.Sprintf("ingested %d files", msg.savedCount)
			m.errText = ""
		}
		m.refreshViewport()
		return m, nil

	case analysisDoneMsg:
		if msg.err != nil {
			m.messages = append(m.messages, ollama.Message{Role: "assistant", Content: fmt.Sprintf("Analysis failed: %v", msg.err)})
			m.errText = msg.err.Error()
			m.status = "analysis error"
		} else {
			m.messages = append(m.messages, ollama.Message{Role: "assistant", Content: fmt.Sprintf("Analysis loop finished. Processed %d pending files.", msg.processedCount)})
			m.status = fmt.Sprintf("analyzed %d files", msg.processedCount)
			m.errText = ""
		}
		m.refreshViewport()
		return m, nil

	case fullDoneMsg:
		if msg.err != nil {
			m.messages = append(m.messages, ollama.Message{Role: "assistant", Content: fmt.Sprintf("Full pipeline error: %v", msg.err)})
			m.errText = msg.err.Error()
			m.status = "pipeline error"
		} else {
			m.messages = append(m.messages, ollama.Message{Role: "assistant", Content: fmt.Sprintf("Full pipeline complete. Ingested %d files, analyzed %d reports.", msg.ingested, msg.analyzed)})
			m.status = fmt.Sprintf("done: %d ingested, %d analyzed", msg.ingested, msg.analyzed)
			m.errText = ""
		}
		m.refreshViewport()
		return m, nil
	}

	return m, nil
}

func (m Model) View() string {
	if m.width == 0 || m.height == 0 {
		return "loading..."
	}

	header := headerStyle.Render("Buster Claw")
	modelLabel := m.model
	if modelLabel == "" {
		modelLabel = "<none>"
	}
	subtitle := statusStyle.Render(fmt.Sprintf("model: %s", modelLabel))
	body := m.viewport.View()
	input := m.input.View()

	status := statusStyle.Render(m.status)
	help := helpStyle.Render("enter send • /start-full pipeline • /start-ingest fetch • /start-analysis analyze • /status orchestrator • /remember save • /memories list • /forget <n> delete • /models list • /model <name> switch • /clear reset • q quit")

	content := lipgloss.JoinVertical(
		lipgloss.Left,
		header,
		subtitle,
		"",
		body,
		"",
		input,
		"",
		status,
		help,
	)

	return docStyle.Width(m.width).Height(m.height).Render(content)
}

func (m *Model) resize() {
	horizontal, vertical := docStyle.GetFrameSize()
	contentWidth := m.width - horizontal
	contentHeight := m.height - vertical
	if contentWidth < 20 {
		contentWidth = 20
	}
	if contentHeight < 8 {
		contentHeight = 8
	}

	m.input.Width = contentWidth
	m.viewport.Width = contentWidth
	m.viewport.Height = contentHeight - 7
	if m.viewport.Height < 3 {
		m.viewport.Height = 3
	}
	m.refreshViewport()
}

func (m *Model) refreshViewport() {
	var sections []string

	if len(m.models) > 0 {
		sections = append(sections, helpStyle.Render("Installed models: "+strings.Join(m.models, ", ")))
	} else {
		sections = append(sections,
			errorStyle.Render("No Models Installed"),
			helpStyle.Render("Pull a model into Ollama before chatting."),
			helpStyle.Render("Example: `ollama pull gemma4:latest`"),
			helpStyle.Render("Then use `/models` to refresh this screen."),
		)
	}

	for _, message := range m.messages {
		switch message.Role {
		case "user":
			sections = append(sections, userStyle.Render("You"))
		case "assistant":
			sections = append(sections, assistantStyle.Render("Gemma"))
		case "system":
			continue
		default:
			sections = append(sections, headerStyle.Render(strings.Title(message.Role)))
		}
		sections = append(sections, wrapText(message.Content, m.viewport.Width))
	}

	if m.errText != "" {
		sections = append(sections, errorStyle.Render("Error"))
		sections = append(sections, wrapText(m.errText, m.viewport.Width))
	}

	if len(sections) == 0 {
		sections = append(sections,
			helpStyle.Render("Start typing to chat with your local model."),
			helpStyle.Render("The app streams responses from Ollama in place."),
		)
	}

	m.viewport.SetContent(strings.Join(sections, "\n\n"))
	m.viewport.GotoBottom()
}

func wrapText(s string, width int) string {
	if width <= 0 || s == "" {
		return s
	}
	return lipgloss.NewStyle().Width(width).Render(s)
}

func (m *Model) handleCommand(input string) (bool, tea.Cmd) {
	switch {
	case input == "/quit":
		return true, tea.Quit
	case input == "/clear":
		m.messages = nil
		m.errText = ""
		m.status = readyStatus(m.model)
		m.refreshViewport()
		return true, nil
	case input == "/models":
		m.status = "refreshing models"
		return true, m.fetchModelsCmd()
	case input == "/start-ingest":
		m.status = "ingesting data..."
		m.messages = append(m.messages, ollama.Message{Role: "user", Content: input})
		m.refreshViewport()
		return true, m.startIngestCmd()
	case input == "/start-analysis":
		m.status = "analyzing queue..."
		m.messages = append(m.messages, ollama.Message{Role: "user", Content: input})
		m.refreshViewport()
		return true, m.startAnalysisCmd()
	case input == "/start-full":
		m.status = "running full pipeline..."
		m.messages = append(m.messages, ollama.Message{Role: "user", Content: input})
		m.refreshViewport()
		return true, m.startFullCmd()
	case input == "/status":
		s := m.orchestrator.GetStatus()
		statusMsg := fmt.Sprintf("Phase: %s\nQueue depth: %d\nActive job: %s\nCompleted: %d\nFailed: %d",
			s.Phase, s.QueueDepth, s.ActiveJob, s.CompletedJobs, s.FailedJobs)
		if s.Phase == "" {
			statusMsg = "Orchestrator idle. Use /start-full to run the full pipeline."
		}
		m.messages = append(m.messages, ollama.Message{Role: "assistant", Content: statusMsg})
		m.refreshViewport()
		return true, nil
	case input == "/memories":
		m.messages = append(m.messages, ollama.Message{Role: "assistant", Content: formatMemories(m.memories)})
		m.status = fmt.Sprintf("ready · model %s", m.model)
		m.errText = ""
		m.refreshViewport()
		return true, nil
	case strings.HasPrefix(input, "/remember "):
		text := strings.TrimSpace(strings.TrimPrefix(input, "/remember "))
		if text == "" {
			m.errText = "usage: /remember <text>"
			m.refreshViewport()
			return true, nil
		}
		m.memories = addMemory(m.memories, text, time.Now())
		if err := saveMemory(m.saveDir, m.memories); err != nil {
			m.errText = "Could not save memory: " + err.Error()
			m.status = "memory save failed"
			m.refreshViewport()
			return true, nil
		}
		m.messages = append(m.messages, ollama.Message{Role: "assistant", Content: fmt.Sprintf("Saved memory %d.", len(m.memories))})
		m.status = fmt.Sprintf("saved memory %d", len(m.memories))
		m.errText = ""
		m.refreshViewport()
		return true, nil
	case strings.HasPrefix(input, "/forget "):
		index, err := parseForgetIndex(input)
		if err != nil {
			m.errText = err.Error()
			m.refreshViewport()
			return true, nil
		}
		m.memories, err = removeMemory(m.memories, index)
		if err != nil {
			m.errText = err.Error()
			m.refreshViewport()
			return true, nil
		}
		if err := saveMemory(m.saveDir, m.memories); err != nil {
			m.errText = "Could not update memory file: " + err.Error()
			m.status = "memory save failed"
			m.refreshViewport()
			return true, nil
		}
		m.messages = append(m.messages, ollama.Message{Role: "assistant", Content: fmt.Sprintf("Forgot memory %d.", index)})
		m.status = fmt.Sprintf("forgot memory %d", index)
		m.errText = ""
		m.refreshViewport()
		return true, nil
	case strings.HasPrefix(input, "/model "):
		next := strings.TrimSpace(strings.TrimPrefix(input, "/model "))
		if next == "" {
			m.errText = "usage: /model <name>"
			m.refreshViewport()
			return true, nil
		}
		m.model = next
		m.status = fmt.Sprintf("ready · model %s", m.model)
		m.errText = ""
		m.refreshViewport()
		return true, nil
	default:
		return false, nil
	}
}

func (m *Model) sendPrompt(prompt string) (tea.Model, tea.Cmd) {
	if !m.canChat() {
		m.errText = noModelError()
		m.status = "no model selected"
		m.refreshViewport()
		return m, nil
	}

	m.messages = append(m.messages, ollama.Message{Role: "user", Content: prompt})
	m.messages = append(m.messages, ollama.Message{Role: "assistant", Content: ""})
	m.streaming = true
	m.status = fmt.Sprintf("streaming · model %s", m.model)
	m.errText = ""
	m.refreshViewport()

	history := m.chatHistoryForPrompt(prompt)
	go m.stream(history)

	return m, m.waitForStream()
}

func (m *Model) stream(messages []ollama.Message) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	err := m.client.ChatStream(ctx, m.model, messages, func(chunk string) error {
		m.streamCh <- tokenMsg{text: chunk}
		return nil
	})
	if err != nil {
		m.mu.Lock()
		if len(m.messages) > 0 && m.messages[len(m.messages)-1].Role == "assistant" && m.messages[len(m.messages)-1].Content == "" {
			m.messages = m.messages[:len(m.messages)-1]
		}
		m.mu.Unlock()
		m.streamCh <- streamErrMsg{err: err}
		return
	}
	m.streamCh <- streamDoneMsg{}
}

func (m *Model) chatHistoryForPrompt(prompt string) []ollama.Message {
	history := make([]messageView, 0, len(m.messages))
	for _, message := range m.messages[:len(m.messages)-1] {
		history = append(history, messageView{
			Role:    message.Role,
			Content: message.Content,
		})
	}

	built := buildPromptMessages(history[:len(history)-1], prompt, m.memories)
	chat := make([]ollama.Message, 0, len(built))
	for _, message := range built {
		chat = append(chat, ollama.Message{
			Role:    message.Role,
			Content: message.Content,
		})
	}
	return chat
}

func (m *Model) finalizeAssistantOutput() {
	m.status = fmt.Sprintf("ready · model %s", m.model)
	m.errText = ""

	if len(m.messages) == 0 {
		return
	}
	last := &m.messages[len(m.messages)-1]
	if last.Role != "assistant" {
		return
	}

	spec, found, err := extractMarkdownFile(last.Content)
	if err != nil {
		m.status = "save failed"
		m.errText = "Markdown generation failed: " + err.Error()
		return
	}
	if !found {
		return
	}

	path, err := writeMarkdownFile(m.saveDir, spec)
	if err != nil {
		m.status = "save failed"
		m.errText = "Could not write markdown file: " + err.Error()
		return
	}

	last.Content = fmt.Sprintf("Saved Markdown file `%s`.\n\n%s", filepath.Base(path), spec.content)
	m.status = fmt.Sprintf("saved %s", filepath.Base(path))
}

func (m Model) waitForStream() tea.Cmd {
	return func() tea.Msg {
		return <-m.streamCh
	}
}

func (m Model) fetchModelsCmd() tea.Cmd {
	return func() tea.Msg {
		ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
		defer cancel()

		models, err := m.client.ListModels(ctx)
		if err != nil {
			return modelsErrMsg{err: err}
		}
		return modelsMsg{models: models}
	}
}

func (m Model) startIngestCmd() tea.Cmd {
	return func() tea.Msg {
		sourcesFile := filepath.Join(m.saveDir, "sources.json")
		sources, err := ingest.LoadSources(sourcesFile)
		if err != nil {
			return ingestDoneMsg{err: fmt.Errorf("failed to load sources: %w", err)}
		}

		if len(sources) == 0 {
			return ingestDoneMsg{err: fmt.Errorf("no sources found in %s", sourcesFile)}
		}

		ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
		defer cancel()

		// Expand RSS feeds into individual article sources.
		var fetchable []ingest.Source
		for _, src := range sources {
			if src.Type == ingest.RSSType {
				entries, err := ingest.FetchRSSEntries(ctx, src)
				if err != nil {
					// Log the error but keep going with other sources.
					continue
				}
				fetchable = append(fetchable, entries...)
			} else {
				fetchable = append(fetchable, src)
			}
		}

		if len(fetchable) == 0 {
			return ingestDoneMsg{err: fmt.Errorf("no fetchable sources after expanding RSS feeds")}
		}

		fetcher := ingest.NewFetcher(5)
		results := fetcher.FetchAll(ctx, fetchable)

		libManager := library.NewManager(filepath.Join(m.saveDir, "Library"))

		savedCount := 0
		var lastErr error
		for _, result := range results {
			if result.Error != nil {
				lastErr = result.Error
				continue
			}
			_, err := libManager.SaveResult(result)
			if err != nil {
				lastErr = err
				continue
			}
			savedCount++
		}

		if savedCount == 0 && lastErr != nil {
			return ingestDoneMsg{err: fmt.Errorf("all fetch/save attempts failed. Last error: %w", lastErr)}
		}

		return ingestDoneMsg{savedCount: savedCount}
	}
}

func (m Model) startAnalysisCmd() tea.Cmd {
	return func() tea.Msg {
		// 1. Load Intentions
		intentionsFile := filepath.Join(m.saveDir, "Intentions.md")
		ints, err := intentions.Load(intentionsFile)
		if err != nil {
			return analysisDoneMsg{err: fmt.Errorf("failed to load Intentions.md: %w", err)}
		}

		// 2. Initialize Queue Manager
		queueFile := filepath.Join(m.saveDir, "Library", "queue.json")
		qManager, err := queue.NewManager(queueFile)
		if err != nil {
			return analysisDoneMsg{err: fmt.Errorf("failed to initialize queue manager: %w", err)}
		}

		// 3. Get pending files from Library/raw
		rawDir := filepath.Join(m.saveDir, "Library", "raw")
		pendingFiles, err := qManager.GetPendingFiles(rawDir)
		if err != nil {
			return analysisDoneMsg{err: fmt.Errorf("failed to get pending files: %w", err)}
		}

		if len(pendingFiles) == 0 {
			return analysisDoneMsg{processedCount: 0}
		}

		// 4. Initialize report manager
		libraryDir := filepath.Join(m.saveDir, "Library")
		reportMgr := library.NewReportManager(libraryDir)
		reportsDir, err := reportMgr.DateDir()
		if err != nil {
			return analysisDoneMsg{err: err}
		}

		// 5. Process each file sequentially — one at a time, full focus
		processedCount := 0
		var lastErr error

		for _, file := range pendingFiles {
			content, err := os.ReadFile(file)
			if err != nil {
				lastErr = fmt.Errorf("failed to read %s: %w", filepath.Base(file), err)
				continue
			}

			// Extract source metadata from frontmatter if present
			docContent := string(content)
			sourceURL, sourceTags := extractFrontmatterMeta(docContent)
			docBody := stripFrontmatter(docContent)

			// Build structured system prompt from parsed intentions
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

			// Build user message with source context
			var userPrompt strings.Builder
			if sourceURL != "" {
				userPrompt.WriteString(fmt.Sprintf("Source: %s\n", sourceURL))
			}
			if len(sourceTags) > 0 {
				userPrompt.WriteString(fmt.Sprintf("Tags: %s\n", strings.Join(sourceTags, ", ")))
			}
			userPrompt.WriteString(fmt.Sprintf("File: %s\n\n", filepath.Base(file)))
			userPrompt.WriteString("Analyze this document:\n\n")
			userPrompt.WriteString(docBody)

			messages := []ollama.Message{
				{Role: "system", Content: systemPrompt},
				{Role: "user", Content: userPrompt.String()},
			}

			// Call LLM — one document at a time
			var builder strings.Builder
			ctxChat, cancelChat := context.WithTimeout(context.Background(), 3*time.Minute)
			err = m.client.ChatStream(ctxChat, m.model, messages, func(chunk string) error {
				builder.WriteString(chunk)
				return nil
			})
			cancelChat()

			if err != nil {
				lastErr = fmt.Errorf("analysis failed for %s: %w", filepath.Base(file), err)
				continue
			}

			// Extract markdown block from LLM response
			rawResponse := builder.String()
			spec, found, err := extractMarkdownFile(rawResponse)
			if err != nil {
				lastErr = fmt.Errorf("failed to extract report for %s: %w", filepath.Base(file), err)
				continue
			}
			if !found {
				lastErr = fmt.Errorf("no valid markdown block found for %s", filepath.Base(file))
				continue
			}

			// Prepend report frontmatter
			now := time.Now().Format(time.RFC3339)
			meta := library.ReportMeta{
				Filename:       spec.name,
				SourceFile:     filepath.Base(file),
				SourceURL:      sourceURL,
				GeneratedAt:    now,
				Model:          m.model,
				IntentionsUsed: true,
				Tags:           sourceTags,
			}
			spec.content = library.BuildReportFrontmatter(meta) + spec.content

			_, err = writeMarkdownFile(reportsDir, spec)
			if err != nil {
				lastErr = fmt.Errorf("failed to write report for %s: %w", filepath.Base(file), err)
				continue
			}

			// Track in manifest
			if err := reportMgr.AppendManifest(meta); err != nil {
				lastErr = fmt.Errorf("failed to update manifest for %s: %w", filepath.Base(file), err)
				// Don't skip — the report was already saved
			}

			if err := qManager.MarkProcessed(file); err != nil {
				lastErr = fmt.Errorf("failed to mark %s as processed: %w", filepath.Base(file), err)
				continue
			}
			processedCount++
		}

		if processedCount == 0 && lastErr != nil {
			return analysisDoneMsg{err: fmt.Errorf("all analysis attempts failed. Last error: %w", lastErr)}
		}

		return analysisDoneMsg{processedCount: processedCount}
	}
}

func (m Model) startFullCmd() tea.Cmd {
	return func() tea.Msg {
		ctx, cancel := context.WithTimeout(context.Background(), 10*time.Minute)
		defer cancel()

		ingested, analyzed, err := m.orchestrator.RunFull(ctx)
		return fullDoneMsg{ingested: ingested, analyzed: analyzed, err: err}
	}
}

// extractFrontmatterMeta pulls url and tags from YAML frontmatter in an ingested doc.
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

// stripFrontmatter removes YAML frontmatter from document content.
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

func initialStatus(model string) string {
	if model == "" {
		return "starting"
	}
	return readyStatus(model)
}

func readyStatus(model string) string {
	if model == "" {
		return "ready"
	}
	return fmt.Sprintf("ready · model %s", model)
}

func contains(values []string, target string) bool {
	for _, value := range values {
		if value == target {
			return true
		}
	}
	return false
}

func humanizeStreamError(err error) string {
	if err == nil {
		return ""
	}
	message := err.Error()
	if strings.Contains(message, "not found") {
		return message + "\n\nInstall a model with `ollama pull <model>`, then run `/models`."
	}
	return message
}

func (m *Model) canChat() bool {
	return m.model != "" && len(m.models) > 0 && contains(m.models, m.model)
}

func (m *Model) syncInputState() {
	if m.canChat() {
		m.input.Placeholder = "Send a prompt or use /models, /model <name>, /clear, /quit"
		m.input.Focus()
		return
	}

	m.input.SetValue("")
	m.input.Blur()
	if len(m.models) == 0 {
		m.input.Placeholder = "Install a model first: ollama pull gemma4:latest"
		return
	}
	m.input.Placeholder = "Select an installed model with /model <name>"
}

func noModelError() string {
	return "No usable model is selected.\n\nInstall one with `ollama pull <model>`, then run `/models` and choose it with `/model <name>` if needed."
}
