import { createSignal, createEffect, onMount, onCleanup, For, Show } from "solid-js";
import { marked } from "marked";
import type { ChatMessage, OrchestratorStatus, Source, DocumentInfo, PendingFile, ReportMeta, QueueEntry } from "./wails.d";

type View = "chat" | "ingestion" | "documents" | "orchestration" | "analysis" | "models";

function App() {
  const [activeView, setActiveView] = createSignal<View>("chat");
  const [messages, setMessages] = createSignal<ChatMessage[]>([]);
  const [input, setInput] = createSignal("");
  const [models, setModels] = createSignal<string[]>([]);
  const [currentModel, setCurrentModel] = createSignal("");
  const [streaming, setStreaming] = createSignal(false);
  const [streamBuffer, setStreamBuffer] = createSignal("");
  const [status, setStatus] = createSignal<OrchestratorStatus>({
    phase: "idle",
    queueDepth: 0,
    activeJob: "",
    completedJobs: 0,
    failedJobs: 0,
  });
  const [busy, setBusy] = createSignal(false);

  // Ingestion
  const [sources, setSources] = createSignal<Source[]>([]);
  const [newSourceUrl, setNewSourceUrl] = createSignal("");
  const [newSourceName, setNewSourceName] = createSignal("");
  const [newSourceType, setNewSourceType] = createSignal("rss");
  const [newSourceTags, setNewSourceTags] = createSignal("");

  // Documents
  const [documents, setDocuments] = createSignal<DocumentInfo[]>([]);

  // Orchestration
  const [pendingFiles, setPendingFiles] = createSignal<PendingFile[]>([]);
  const [analysisQueue, setAnalysisQueue] = createSignal<QueueEntry[]>([]);

  // Analysis
  const [reports, setReports] = createSignal<ReportMeta[]>([]);
  const [selectedReport, setSelectedReport] = createSignal<ReportMeta | null>(null);
  const [reportContent, setReportContent] = createSignal("");

  let messagesEnd: HTMLDivElement | undefined;

  const scrollToBottom = () => {
    messagesEnd?.scrollIntoView({ behavior: "smooth" });
  };

  createEffect(() => {
    messages();
    streamBuffer();
    scrollToBottom();
  });

  // Refresh data when switching views
  const switchView = async (view: View) => {
    setActiveView(view);
    if (view === "ingestion") {
      try { const s = await window.go.main.App.GetSources(); setSources(s || []); } catch (e) { console.error(e); }
    } else if (view === "documents") {
      try { const d = await window.go.main.App.GetDocuments(); setDocuments(d || []); } catch (e) { console.error(e); }
    } else if (view === "orchestration") {
      try { const p = await window.go.main.App.GetPendingFiles(); setPendingFiles(p || []); } catch (e) { console.error(e); }
      try { const q = await window.go.main.App.GetAnalysisQueue(); setAnalysisQueue(q || []); } catch (e) { console.error(e); }
    } else if (view === "analysis") {
      try { const r = await window.go.main.App.GetReportManifest(); setReports(r || []); } catch (e) { console.error(e); }
    } else if (view === "models") {
      try { const m = await window.go.main.App.GetModels(); setModels(m || []); } catch (e) { console.error(e); }
    }
  };

  onMount(async () => {
    try { const m = await window.go.main.App.GetModels(); setModels(m || []); } catch (e) { console.error(e); }
    try { const cur = await window.go.main.App.GetCurrentModel(); setCurrentModel(cur); } catch (e) { console.error(e); }
    try { const msgs = await window.go.main.App.GetMessages(); setMessages(msgs || []); } catch (e) { console.error(e); }
    try { const s = await window.go.main.App.GetSources(); setSources(s || []); } catch (e) { console.error(e); }

    window.runtime.EventsOn("chat:token", (chunk: string) => {
      setStreaming(true);
      setStreamBuffer((prev) => prev + chunk);
    });
    window.runtime.EventsOn("chat:done", (_response: string) => {
      const buf = streamBuffer();
      if (buf) setMessages((prev) => [...prev, { role: "assistant", content: buf }]);
      setStreamBuffer("");
      setStreaming(false);
    });
    window.runtime.EventsOn("chat:error", (err: string) => {
      setMessages((prev) => [...prev, { role: "assistant", content: `Error: ${err}` }]);
      setStreamBuffer("");
      setStreaming(false);
    });
    window.runtime.EventsOn("orchestrator:status", async (s: OrchestratorStatus) => {
      setStatus(s);
      // Refresh queue display when status changes
      if (activeView() === "orchestration") {
        try { const q = await window.go.main.App.GetAnalysisQueue(); setAnalysisQueue(q || []); } catch (_) {}
      }
    });
  });

  onCleanup(() => {
    window.runtime.EventsOff("chat:token");
    window.runtime.EventsOff("chat:done");
    window.runtime.EventsOff("chat:error");
    window.runtime.EventsOff("orchestrator:status");
  });

  // --- Actions ---

  const sendMessage = async () => {
    const prompt = input().trim();
    if (!prompt || streaming()) return;
    setInput("");
    setMessages((prev) => [...prev, { role: "user", content: prompt }]);
    try { await window.go.main.App.SendMessage(prompt); } catch (e: any) {
      setMessages((prev) => [...prev, { role: "assistant", content: `Error: ${e.message || e}` }]);
    }
  };

  const handleKeyDown = (e: KeyboardEvent) => {
    if (e.key === "Enter" && !e.shiftKey) { e.preventDefault(); sendMessage(); }
  };

  const switchModel = async (name: string) => {
    setCurrentModel(name);
    await window.go.main.App.SetModel(name);
  };

  const refreshModels = async () => {
    const m = await window.go.main.App.GetModels();
    setModels(m || []);
  };

  const startIngest = async () => {
    setBusy(true);
    try {
      const result = await window.go.main.App.StartIngest();
      if (result.error) {
        setMessages((prev) => [...prev, { role: "assistant", content: `Ingestion error: ${result.error}` }]);
      } else {
        setMessages((prev) => [...prev, { role: "assistant", content: `Ingestion complete. Saved ${result.savedCount} files.` }]);
      }
    } finally { setBusy(false); }
  };

  const ingestSingle = async (url: string) => {
    setBusy(true);
    try {
      const result = await window.go.main.App.IngestSource(url);
      if (result.error) {
        setMessages((prev) => [...prev, { role: "assistant", content: `Ingestion error: ${result.error}` }]);
      } else {
        setMessages((prev) => [...prev, { role: "assistant", content: `Ingested ${result.savedCount} files from source.` }]);
      }
    } finally { setBusy(false); }
  };

  const startAnalysis = async () => {
    setBusy(true);
    try {
      const result = await window.go.main.App.StartAnalysis();
      if (result.error) {
        setMessages((prev) => [...prev, { role: "assistant", content: `Analysis error: ${result.error}` }]);
      } else {
        setMessages((prev) => [...prev, { role: "assistant", content: `Analysis complete. Processed ${result.processedCount} files.` }]);
      }
    } finally { setBusy(false); }
  };

  const queueDocument = async (path: string) => {
    try {
      await window.go.main.App.QueueDocument(path);
      // Refresh both lists
      const p = await window.go.main.App.GetPendingFiles();
      setPendingFiles(p || []);
      const q = await window.go.main.App.GetAnalysisQueue();
      setAnalysisQueue(q || []);
    } catch (e) { console.error(e); }
  };

  const runQueue = async () => {
    setBusy(true);
    try {
      const result = await window.go.main.App.StartAnalysis();
      if (result.error) {
        setMessages((prev) => [...prev, { role: "assistant", content: `Analysis error: ${result.error}` }]);
      }
      // Refresh queue state
      const q = await window.go.main.App.GetAnalysisQueue();
      setAnalysisQueue(q || []);
      const p = await window.go.main.App.GetPendingFiles();
      setPendingFiles(p || []);
    } finally { setBusy(false); }
  };

  const openReport = async (report: ReportMeta) => {
    try {
      const content = await window.go.main.App.GetReportContent(report.filename);
      setReportContent(content);
      setSelectedReport(report);
    } catch (e) { console.error(e); }
  };

  const closeReport = () => {
    setSelectedReport(null);
    setReportContent("");
  };

  const addSource = async () => {
    const url = newSourceUrl().trim();
    if (!url) return;
    const tags = newSourceTags().trim() ? newSourceTags().split(",").map((t) => t.trim()).filter(Boolean) : [];
    try {
      await window.go.main.App.AddSource(url, newSourceType(), tags, newSourceName().trim());
      const s = await window.go.main.App.GetSources();
      setSources(s || []);
      setNewSourceUrl(""); setNewSourceName(""); setNewSourceTags("");
    } catch (e) { console.error(e); }
  };

  const deleteSource = async (url: string) => {
    try {
      await window.go.main.App.DeleteSource(url);
      const s = await window.go.main.App.GetSources();
      setSources(s || []);
    } catch (e) { console.error(e); }
  };

  const clearChat = async () => {
    await window.go.main.App.ClearMessages();
    setMessages([]);
    setStreamBuffer("");
  };

  return (
    <div class="app">
      {/* Header */}
      <div class="header">
        <h1>BUSTER CLAW</h1>
      </div>

      {/* Sidebar */}
      <div class="sidebar">
        <div class="sidebar-section">
          <h3>Navigate</h3>
          <button class="sidebar-btn" classList={{ "sidebar-btn-active": activeView() === "chat" }} onClick={() => switchView("chat")}>Chat</button>
          <button class="sidebar-btn" classList={{ "sidebar-btn-active": activeView() === "ingestion" }} onClick={() => switchView("ingestion")}>Ingestion</button>
          <button class="sidebar-btn" classList={{ "sidebar-btn-active": activeView() === "documents" }} onClick={() => switchView("documents")}>Documents</button>
          <button class="sidebar-btn" classList={{ "sidebar-btn-active": activeView() === "orchestration" }} onClick={() => switchView("orchestration")}>Orchestration</button>
          <button class="sidebar-btn" classList={{ "sidebar-btn-active": activeView() === "analysis" }} onClick={() => switchView("analysis")}>Analysis</button>
          <button class="sidebar-btn" classList={{ "sidebar-btn-active": activeView() === "models" }} onClick={() => switchView("models")}>Models</button>
        </div>

        <div class="sidebar-section">
          <h3>Status</h3>
          <div class="status-card">
            <div class="label">Phase</div>
            <div class="value" classList={{ active: status().phase !== "idle" }}>{status().phase || "idle"}</div>
          </div>
          <div class="status-card" style="margin-top: 6px">
            <div class="label">Completed / Failed</div>
            <div class="value">{status().completedJobs} / {status().failedJobs}</div>
          </div>
          <Show when={status().activeJob}>
            <div class="status-card" style="margin-top: 6px">
              <div class="label">Active</div>
              <div class="value active">{status().activeJob}</div>
            </div>
          </Show>
        </div>

        <div class="sidebar-section">
          <h3>Actions</h3>
          <button class="sidebar-btn" onClick={refreshModels}>Refresh Models</button>
          <button class="sidebar-btn" onClick={clearChat}>Clear Chat</button>
        </div>
      </div>

      {/* Main Content */}
      <div class="main-content">

        {/* Chat View */}
        <div class="chat-area" classList={{ hidden: activeView() !== "chat" }}>
          <div class="messages">
            <Show when={messages().length > 0 || streaming()} fallback={
              <div class="empty-state">
                <h2>Welcome to Buster Claw</h2>
                <p>Chat with your local model or run the pipeline.</p>
                <p style="font-size: 11px; color: var(--text-muted)">Model: {currentModel() || "none selected"}</p>
              </div>
            }>
              <For each={messages()}>{(msg) => (
                <div class={`message ${msg.role}`}>
                  <div class="message-role">{msg.role === "user" ? "You" : "Gemma"}</div>
                  <div class="message-content">{msg.content}</div>
                </div>
              )}</For>
              <Show when={streaming() && streamBuffer()}>
                <div class="message assistant">
                  <div class="message-role">Gemma</div>
                  <div class="message-content">{streamBuffer()}<span class="streaming-indicator" /></div>
                </div>
              </Show>
            </Show>
            <div ref={messagesEnd} />
          </div>
          <div class="input-area">
            <div class="input-row">
              <input type="text" placeholder={currentModel() ? "Send a message..." : "No model selected"} value={input()} onInput={(e) => setInput(e.currentTarget.value)} onKeyDown={handleKeyDown} disabled={!currentModel() || streaming()} />
              <button onClick={sendMessage} disabled={!currentModel() || streaming() || !input().trim()}>Send</button>
            </div>
          </div>
        </div>

        {/* Ingestion View */}
        <div class="view-panel" classList={{ hidden: activeView() !== "ingestion" }}>
          <div class="view-panel-content">
            <div class="view-header">
              <h2>Ingestion</h2>
              <div class="view-header-actions">
                <span class="source-count">{sources().length} sources</span>
                <button class="action-btn" onClick={startIngest} disabled={busy() || streaming() || sources().length === 0}>Ingest All</button>
              </div>
            </div>

            <div class="source-list">
              <For each={sources()} fallback={<div class="empty-list">No sources configured yet.</div>}>
                {(src) => (
                  <div class="source-item">
                    <div class="source-item-info">
                      <div class="source-item-name">{src.name || src.url}</div>
                      <div class="source-item-url">{src.url}</div>
                      <div class="source-item-meta">
                        <span class="source-item-type">{src.type}</span>
                        <For each={src.tags || []}>{(tag) => <span class="source-item-tag">{tag}</span>}</For>
                      </div>
                    </div>
                    <div class="source-item-actions">
                      <button class="source-ingest-btn" onClick={() => ingestSingle(src.url)} disabled={busy() || streaming()}>Ingest</button>
                      <button class="source-delete-btn" onClick={() => deleteSource(src.url)}>Remove</button>
                    </div>
                  </div>
                )}
              </For>
            </div>

            <div class="source-add">
              <h4>Add Source</h4>
              <div class="source-add-fields">
                <input type="text" placeholder="URL" value={newSourceUrl()} onInput={(e) => setNewSourceUrl(e.currentTarget.value)} />
                <input type="text" placeholder="Name (optional)" value={newSourceName()} onInput={(e) => setNewSourceName(e.currentTarget.value)} />
                <div class="source-add-row">
                  <select value={newSourceType()} onChange={(e) => setNewSourceType(e.currentTarget.value)}>
                    <option value="rss">RSS</option>
                    <option value="article">Article</option>
                    <option value="documentation">Documentation</option>
                  </select>
                  <input type="text" placeholder="Tags (comma separated)" value={newSourceTags()} onInput={(e) => setNewSourceTags(e.currentTarget.value)} />
                </div>
                <button class="action-btn" onClick={addSource} disabled={!newSourceUrl().trim()}>Add to Roster</button>
              </div>
            </div>
          </div>
        </div>

        {/* Documents View */}
        <div class="view-panel" classList={{ hidden: activeView() !== "documents" }}>
          <div class="view-panel-content">
            <div class="view-header">
              <h2>Documents</h2>
              <span class="source-count">{documents().length} ingested</span>
            </div>

            <div class="doc-list">
              <For each={documents()} fallback={<div class="empty-list">No documents ingested yet. Go to Ingestion to fetch sources.</div>}>
                {(doc) => (
                  <div class="doc-item">
                    <div class="doc-item-title">{doc.name || doc.filename}</div>
                    <div class="doc-item-meta">
                      <span class="doc-item-date">{doc.date}</span>
                      <Show when={doc.sourceUrl}>
                        <span class="doc-item-url">{doc.sourceUrl}</span>
                      </Show>
                    </div>
                  </div>
                )}
              </For>
            </div>
          </div>
        </div>

        {/* Orchestration View */}
        <div class="view-panel" classList={{ hidden: activeView() !== "orchestration" }}>
          <div class="view-panel-content">
            <div class="view-header">
              <h2>Orchestration</h2>
              <div class="view-header-actions">
                <button class="action-btn" onClick={runQueue} disabled={busy() || streaming() || analysisQueue().filter(q => q.status === "queued").length === 0}>
                  Run Queue
                </button>
              </div>
            </div>

            {/* Analysis Queue */}
            <div class="orch-section">
              <h3>Analysis Queue</h3>
              <div class="orch-queue">
                <For each={analysisQueue()} fallback={<div class="empty-list">No documents queued. Select documents below to add them.</div>}>
                  {(entry) => (
                    <div
                      class="orch-queue-item"
                      classList={{
                        "orch-analyzing": entry.status === "analyzing",
                        "orch-done": entry.status === "done",
                        "orch-failed": entry.status === "failed",
                      }}
                    >
                      <div class="orch-queue-item-fill" />
                      <div class="orch-queue-item-content">
                        <div class="orch-queue-item-name">{entry.filename}</div>
                        <div class="orch-queue-item-status">{entry.status}</div>
                      </div>
                    </div>
                  )}
                </For>
              </div>
            </div>

            {/* Unanalyzed Documents */}
            <div class="orch-section">
              <h3>Unanalyzed Documents <span class="source-count">({pendingFiles().length})</span></h3>
              <div class="orch-pending">
                <For each={pendingFiles()} fallback={<div class="empty-list">All documents have been analyzed or queued.</div>}>
                  {(file) => (
                    <div class="orch-pending-item">
                      <div class="orch-pending-info">
                        <div class="orch-pending-name">{file.filename}</div>
                        <div class="orch-pending-date">{file.date}</div>
                      </div>
                      <button class="source-ingest-btn" onClick={() => queueDocument(file.path)}>Queue</button>
                    </div>
                  )}
                </For>
              </div>
            </div>
          </div>
        </div>

        {/* Analysis View */}
        <div class="view-panel" classList={{ hidden: activeView() !== "analysis" }}>
          <Show when={!selectedReport()}>
            <div class="view-panel-content">
              <div class="view-header">
                <h2>Analysis</h2>
                <span class="source-count">{reports().length} reports</span>
              </div>

              <div class="report-list">
                <For each={reports()} fallback={<div class="empty-list">No analysis reports yet. Run the orchestration queue to generate reports.</div>}>
                  {(report) => (
                    <div class="report-item" onClick={() => openReport(report)}>
                      <div class="report-item-title">{report.filename}</div>
                      <div class="report-item-meta">
                        <span class="report-item-date">{report.generated_at?.split("T")[0]}</span>
                        <span class="report-item-model">{report.model}</span>
                        <Show when={report.source_url}>
                          <span class="report-item-source">{report.source_url}</span>
                        </Show>
                      </div>
                      <Show when={report.tags && report.tags.length > 0}>
                        <div class="report-item-tags">
                          <For each={report.tags!}>{(tag) => <span class="source-item-tag">{tag}</span>}</For>
                        </div>
                      </Show>
                    </div>
                  )}
                </For>
              </div>
            </div>
          </Show>

          <Show when={selectedReport()}>
            <div class="report-reader">
              <div class="report-reader-header">
                <button class="report-back-btn" onClick={closeReport}>Back to Reports</button>
                <div class="report-reader-meta">
                  <span>{selectedReport()!.generated_at?.split("T")[0]}</span>
                  <span class="report-reader-model">{selectedReport()!.model}</span>
                </div>
              </div>
              <article class="report-article" innerHTML={marked(reportContent()) as string} />
            </div>
          </Show>
        </div>

        {/* Models View */}
        <div class="view-panel" classList={{ hidden: activeView() !== "models" }}>
          <div class="view-panel-content">
            <div class="view-header">
              <h2>Models</h2>
              <div class="view-header-actions">
                <span class="source-count">{models().length} installed</span>
                <button class="action-btn" onClick={refreshModels}>Refresh</button>
              </div>
            </div>

            <div class="model-list">
              <For each={models()} fallback={<div class="empty-list">No models found. Make sure Ollama is running.</div>}>
                {(m) => (
                  <div class="model-item" classList={{ "model-item-active": m === currentModel() }}>
                    <div class="model-item-info">
                      <div class="model-item-name">{m}</div>
                      <Show when={m === currentModel()}>
                        <span class="model-item-badge">active</span>
                      </Show>
                    </div>
                    <Show when={m !== currentModel()}>
                      <button class="source-ingest-btn" onClick={() => switchModel(m)}>Select</button>
                    </Show>
                  </div>
                )}
              </For>
            </div>
          </div>
        </div>

      </div>

      {/* Status Bar */}
      <div class="status-bar">
        <span>{currentModel() ? `Model: ${currentModel()}` : "No model"} | {models().length} installed</span>
        <span>Buster Claw v1.0</span>
      </div>
    </div>
  );
}

export default App;
