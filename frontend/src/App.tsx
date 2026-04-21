import { createSignal, createEffect, onMount, onCleanup, For, Show } from "solid-js";
import { createQuery, createMutation, useQueryClient } from "@tanstack/solid-query";
import { marked } from "marked";
import type { ChatMessage, OrchestratorStatus, Source, DocumentInfo, PendingFile, ReportMeta, QueueEntry, MemoryEntry, ProviderInfo } from "./wails.d";

type View = "chat" | "ingestion" | "documents" | "orchestration" | "analysis" | "models" | "providers" | "memory" | "docs";

function App() {
  const qc = useQueryClient();
  const [activeView, setActiveView] = createSignal<View>("chat");
  const [messages, setMessages] = createSignal<ChatMessage[]>([]);
  const [input, setInput] = createSignal("");
  const [currentModel, setCurrentModel] = createSignal("");
  const [streaming, setStreaming] = createSignal(false);
  const [searching, setSearching] = createSignal("");
  const [waiting, setWaiting] = createSignal(false);
  const [streamBuffer, setStreamBuffer] = createSignal("");
  const [status, setStatus] = createSignal<OrchestratorStatus>({
    phase: "idle",
    queueDepth: 0,
    activeJob: "",
    completedJobs: 0,
    failedJobs: 0,
  });
  const [busy, setBusy] = createSignal(false);

  // Form state
  const [newSourceUrl, setNewSourceUrl] = createSignal("");
  const [newSourceName, setNewSourceName] = createSignal("");
  const [newSourceType, setNewSourceType] = createSignal("rss");
  const [newSourceTags, setNewSourceTags] = createSignal("");
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

  // --- Queries ---

  const modelsQuery = createQuery(() => ({
    queryKey: ["models"],
    queryFn: () => window.go.main.App.GetModels(),
  }));

  const sourcesQuery = createQuery(() => ({
    queryKey: ["sources"],
    queryFn: () => window.go.main.App.GetSources(),
    enabled: activeView() === "ingestion" || activeView() === "chat",
  }));

  const documentsQuery = createQuery(() => ({
    queryKey: ["documents"],
    queryFn: () => window.go.main.App.GetDocuments(),
    enabled: activeView() === "documents",
  }));

  const pendingQuery = createQuery(() => ({
    queryKey: ["pending"],
    queryFn: () => window.go.main.App.GetPendingFiles(),
    enabled: activeView() === "orchestration",
  }));

  const queueQuery = createQuery(() => ({
    queryKey: ["queue"],
    queryFn: () => window.go.main.App.GetAnalysisQueue(),
    enabled: activeView() === "orchestration",
  }));

  const reportsQuery = createQuery(() => ({
    queryKey: ["reports"],
    queryFn: () => window.go.main.App.GetReportManifest(),
    enabled: activeView() === "analysis",
  }));

  // Helper accessors
  const models = () => modelsQuery.data || [];
  const sources = () => sourcesQuery.data || [];
  const documents = () => documentsQuery.data || [];
  const pendingFiles = () => pendingQuery.data || [];
  const analysisQueue = () => queueQuery.data || [];
  const reports = () => reportsQuery.data || [];

  const memoriesQuery = createQuery(() => ({
    queryKey: ["memories"],
    queryFn: () => window.go.main.App.GetMemories(),
    enabled: activeView() === "memory",
  }));

  const memories = () => memoriesQuery.data || [];

  const providersQuery = createQuery(() => ({
    queryKey: ["providers"],
    queryFn: () => window.go.main.App.GetProviders(),
    enabled: activeView() === "providers",
  }));

  const providers = () => providersQuery.data || [];

  // Form state
  const [newMemory, setNewMemory] = createSignal("");
  const [provName, setProvName] = createSignal("");
  const [provType, setProvType] = createSignal("openrouter");
  const [provUrl, setProvUrl] = createSignal("");
  const [provKey, setProvKey] = createSignal("");
  const [provModel, setProvModel] = createSignal("");
  const [testResult, setTestResult] = createSignal("");

  // --- Mutations ---

  const addSourceMut = createMutation(() => ({
    mutationFn: (args: { url: string; type: string; tags: string[]; name: string }) =>
      window.go.main.App.AddSource(args.url, args.type, args.tags, args.name),
    onSuccess: () => qc.invalidateQueries({ queryKey: ["sources"] }),
  }));

  const deleteSourceMut = createMutation(() => ({
    mutationFn: (url: string) => window.go.main.App.DeleteSource(url),
    onSuccess: () => qc.invalidateQueries({ queryKey: ["sources"] }),
  }));

  const deleteDocMut = createMutation(() => ({
    mutationFn: (path: string) => window.go.main.App.DeleteDocument(path),
    onSuccess: () => qc.invalidateQueries({ queryKey: ["documents"] }),
  }));

  const queueDocMut = createMutation(() => ({
    mutationFn: (path: string) => window.go.main.App.QueueDocument(path),
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: ["pending"] });
      qc.invalidateQueries({ queryKey: ["queue"] });
    },
  }));

  const removeQueueMut = createMutation(() => ({
    mutationFn: (path: string) => window.go.main.App.RemoveFromQueue(path),
    onSuccess: () => qc.invalidateQueries({ queryKey: ["queue"] }),
  }));

  const addMemoryMut = createMutation(() => ({
    mutationFn: (text: string) => window.go.main.App.AddMemory(text),
    onSuccess: () => qc.invalidateQueries({ queryKey: ["memories"] }),
  }));

  const removeMemoryMut = createMutation(() => ({
    mutationFn: (index: number) => window.go.main.App.RemoveMemory(index),
    onSuccess: () => qc.invalidateQueries({ queryKey: ["memories"] }),
  }));

  const addProviderMut = createMutation(() => ({
    mutationFn: (args: { name: string; type: string; baseUrl: string; apiKey: string; model: string }) =>
      window.go.main.App.AddProvider(args.name, args.type, args.baseUrl, args.apiKey, args.model),
    onSuccess: () => qc.invalidateQueries({ queryKey: ["providers"] }),
  }));

  const removeProviderMut = createMutation(() => ({
    mutationFn: (name: string) => window.go.main.App.RemoveProvider(name),
    onSuccess: () => qc.invalidateQueries({ queryKey: ["providers"] }),
  }));

  const setActiveMut = createMutation(() => ({
    mutationFn: (name: string) => window.go.main.App.SetActiveProvider(name),
    onSuccess: () => qc.invalidateQueries({ queryKey: ["providers"] }),
  }));

  // --- View switching ---

  const switchView = (view: View) => {
    setActiveView(view);
  };

  // --- Event listeners ---

  onMount(async () => {
    try { const cur = await window.go.main.App.GetCurrentModel(); setCurrentModel(cur); } catch (e) { console.error(e); }
    try { const msgs = await window.go.main.App.GetMessages(); setMessages(msgs || []); } catch (e) { console.error(e); }

    window.runtime.EventsOn("chat:searching", (query: string) => {
      setSearching(query);
    });
    window.runtime.EventsOn("chat:token", (chunk: string) => {
      setSearching("");
      setWaiting(false);
      setStreaming(true);
      setStreamBuffer((prev) => prev + chunk);
    });
    window.runtime.EventsOn("chat:done", (_response: string) => {
      const buf = streamBuffer();
      if (buf) setMessages((prev) => [...prev, { role: "assistant", content: buf }]);
      setStreamBuffer("");
      setStreaming(false);
      setSearching("");
      setWaiting(false);
    });
    window.runtime.EventsOn("chat:error", (err: string) => {
      setMessages((prev) => [...prev, { role: "assistant", content: `Error: ${err}` }]);
      setStreamBuffer("");
      setStreaming(false);
      setSearching("");
      setWaiting(false);
    });
    window.runtime.EventsOn("chat:cleared", () => {
      setMessages([]);
      setStreamBuffer("");
      setStreaming(false);
      setSearching("");
      setWaiting(false);
    });
    window.runtime.EventsOn("orchestrator:status", async (s: OrchestratorStatus) => {
      setStatus(s);
      qc.invalidateQueries({ queryKey: ["queue"] });
    });
  });

  onCleanup(() => {
    window.runtime.EventsOff("chat:searching");
    window.runtime.EventsOff("chat:token");
    window.runtime.EventsOff("chat:done");
    window.runtime.EventsOff("chat:error");
    window.runtime.EventsOff("chat:cleared");
    window.runtime.EventsOff("orchestrator:status");
  });

  // --- Actions ---

  const sendMessage = async () => {
    const prompt = input().trim();
    if (!prompt || streaming()) return;
    setInput("");
    setMessages((prev) => [...prev, { role: "user", content: prompt }]);
    setWaiting(true);
    try { await window.go.main.App.SendMessage(prompt); } catch (e: any) {
      setWaiting(false);
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

  const startIngest = async () => {
    setBusy(true);
    try {
      const result = await window.go.main.App.StartIngest();
      if (result.error) {
        setMessages((prev) => [...prev, { role: "assistant", content: `Ingestion error: ${result.error}` }]);
      } else {
        setMessages((prev) => [...prev, { role: "assistant", content: `Ingestion complete. Saved ${result.savedCount} files.` }]);
      }
      qc.invalidateQueries({ queryKey: ["documents"] });
      qc.invalidateQueries({ queryKey: ["pending"] });
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
      qc.invalidateQueries({ queryKey: ["documents"] });
      qc.invalidateQueries({ queryKey: ["pending"] });
    } finally { setBusy(false); }
  };

  const runQueue = async () => {
    setBusy(true);
    try {
      const result = await window.go.main.App.StartAnalysis();
      if (result.error) {
        setMessages((prev) => [...prev, { role: "assistant", content: `Analysis error: ${result.error}` }]);
      }
      qc.invalidateQueries({ queryKey: ["queue"] });
      qc.invalidateQueries({ queryKey: ["pending"] });
      qc.invalidateQueries({ queryKey: ["reports"] });
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
    addSourceMut.mutate({ url, type: newSourceType(), tags, name: newSourceName().trim() });
    setNewSourceUrl(""); setNewSourceName(""); setNewSourceTags("");
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
          <button class="sidebar-btn" classList={{ "sidebar-btn-active": activeView() === "providers" }} onClick={() => switchView("providers")}>Providers</button>
          <button class="sidebar-btn" classList={{ "sidebar-btn-active": activeView() === "memory" }} onClick={() => switchView("memory")}>Memory</button>
          <button class="sidebar-btn" classList={{ "sidebar-btn-active": activeView() === "docs" }} onClick={() => switchView("docs")}>Docs</button>
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
              <Show when={searching()}>
                <div class="message assistant searching">
                  <div class="message-role">Gemma</div>
                  <div class="message-content">Searching the web for "{searching()}"<span class="streaming-indicator" /></div>
                </div>
              </Show>
              <Show when={waiting() && !searching()}>
                <div class="message assistant">
                  <div class="message-role">Gemma</div>
                  <div class="message-content thinking-dots"><span /><span /><span /></div>
                </div>
              </Show>
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
                      <button class="source-delete-btn" onClick={() => deleteSourceMut.mutate(src.url)}>Remove</button>
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
                    <div class="doc-item-info">
                      <div class="doc-item-title">{doc.name || doc.filename}</div>
                      <div class="doc-item-meta">
                        <span class="doc-item-date">{doc.date}</span>
                        <Show when={doc.sourceUrl}>
                          <span class="doc-item-url">{doc.sourceUrl}</span>
                        </Show>
                      </div>
                    </div>
                    <button class="doc-delete-btn" onClick={() => deleteDocMut.mutate(doc.path)} title="Delete document">Delete</button>
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
                      <Show when={entry.status === "failed" || entry.status === "queued"}>
                        <button class="queue-remove-btn" onClick={() => removeQueueMut.mutate(entry.path)}>Remove</button>
                      </Show>
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
                      <button class="source-ingest-btn" onClick={() => queueDocMut.mutate(file.path)}>Queue</button>
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
                <button class="action-btn" onClick={() => qc.invalidateQueries({ queryKey: ["models"] })}>Refresh</button>
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

        {/* Providers View */}
        <div class="view-panel" classList={{ hidden: activeView() !== "providers" }}>
          <div class="view-panel-content">
            <div class="view-header">
              <h2>Providers</h2>
              <span class="source-count">{providers().length} configured</span>
            </div>

            <div class="provider-list">
              <For each={providers()} fallback={<div class="empty-list">No providers configured. Add one below to enable API-backed agentic work.</div>}>
                {(prov) => (
                  <div class="provider-item" classList={{ "provider-active": prov.active }}>
                    <div class="provider-item-info">
                      <div class="provider-item-name">
                        {prov.name}
                        <Show when={prov.active}><span class="model-item-badge">active</span></Show>
                      </div>
                      <div class="provider-item-meta">
                        <span class="source-item-type">{prov.type}</span>
                        <span>{prov.model}</span>
                        <Show when={prov.hasKey}><span class="provider-key-badge">key set</span></Show>
                      </div>
                      <Show when={prov.baseUrl}>
                        <div class="provider-item-url">{prov.baseUrl}</div>
                      </Show>
                    </div>
                    <div class="provider-item-actions">
                      <Show when={!prov.active}>
                        <button class="source-ingest-btn" onClick={() => setActiveMut.mutate(prov.name)}>Activate</button>
                      </Show>
                      <button class="source-ingest-btn" onClick={async () => {
                        setTestResult("Testing...");
                        try {
                          const r = await window.go.main.App.TestProvider(prov.name);
                          setTestResult(`${prov.name}: ${r}`);
                        } catch (e: any) {
                          setTestResult(`${prov.name}: Error — ${e.message || e}`);
                        }
                      }}>Test</button>
                      <button class="source-delete-btn" onClick={() => removeProviderMut.mutate(prov.name)}>Remove</button>
                    </div>
                  </div>
                )}
              </For>
            </div>

            <Show when={testResult()}>
              <div class="provider-test-result">{testResult()}</div>
            </Show>

            <div class="provider-add">
              <h4>Add Provider</h4>
              <div class="provider-add-fields">
                <div class="provider-add-row">
                  <input type="text" placeholder="Name (e.g. openrouter-main)" value={provName()} onInput={(e) => setProvName(e.currentTarget.value)} />
                  <select value={provType()} onChange={(e) => setProvType(e.currentTarget.value)}>
                    <option value="openrouter">OpenRouter</option>
                    <option value="openai">OpenAI</option>
                    <option value="anthropic">Anthropic</option>
                    <option value="custom">Custom (OpenAI-compatible)</option>
                  </select>
                </div>
                <input type="text" placeholder="Model (e.g. anthropic/claude-sonnet-4, gpt-4o)" value={provModel()} onInput={(e) => setProvModel(e.currentTarget.value)} />
                <input type="password" placeholder="API Key" value={provKey()} onInput={(e) => setProvKey(e.currentTarget.value)} />
                <input type="text" placeholder="Base URL (optional — defaults per type)" value={provUrl()} onInput={(e) => setProvUrl(e.currentTarget.value)} />
                <button class="action-btn" onClick={() => {
                  if (!provName().trim() || !provModel().trim()) return;
                  addProviderMut.mutate({
                    name: provName().trim(),
                    type: provType(),
                    baseUrl: provUrl().trim(),
                    apiKey: provKey().trim(),
                    model: provModel().trim(),
                  });
                  setProvName(""); setProvUrl(""); setProvKey(""); setProvModel("");
                }} disabled={!provName().trim() || !provModel().trim()}>Add Provider</button>
              </div>
            </div>
          </div>
        </div>

        {/* Memory View */}
        <div class="view-panel" classList={{ hidden: activeView() !== "memory" }}>
          <div class="view-panel-content">
            <div class="view-header">
              <h2>Memory</h2>
              <span class="source-count">{memories().length} saved</span>
            </div>

            <div class="memory-add">
              <input
                type="text"
                placeholder="Remember something..."
                value={newMemory()}
                onInput={(e) => setNewMemory(e.currentTarget.value)}
                onKeyDown={(e) => {
                  if (e.key === "Enter" && newMemory().trim()) {
                    addMemoryMut.mutate(newMemory().trim());
                    setNewMemory("");
                  }
                }}
              />
              <button class="action-btn" onClick={() => { addMemoryMut.mutate(newMemory().trim()); setNewMemory(""); }} disabled={!newMemory().trim()}>Save</button>
            </div>

            <div class="memory-list">
              <For each={memories()} fallback={<div class="empty-list">No memories saved yet. Use the input above or `/remember` in chat.</div>}>
                {(entry) => (
                  <div class="memory-item">
                    <div class="memory-item-info">
                      <div class="memory-item-text">{entry.text}</div>
                      <div class="memory-item-date">{entry.createdAt.split("T")[0]}</div>
                    </div>
                    <button class="doc-delete-btn" onClick={() => removeMemoryMut.mutate(entry.index)}>Forget</button>
                  </div>
                )}
              </For>
            </div>
          </div>
        </div>

        {/* Docs View */}
        <div class="view-panel" classList={{ hidden: activeView() !== "docs" }}>
          <div class="view-panel-content">
            <div class="view-header">
              <h2>Commands</h2>
            </div>

            <div class="docs-content">
              <p class="docs-intro">Type these in the chat input.</p>

              <div class="docs-command">
                <code>/search &lt;query&gt;</code>
                <span>Search the web and get an AI summary</span>
              </div>
              <div class="docs-command">
                <code>/ingest &lt;url&gt;</code>
                <span>Fetch a URL into the library</span>
              </div>
              <div class="docs-command">
                <code>/status</code>
                <span>Show pipeline status</span>
              </div>
              <div class="docs-command">
                <code>/remember &lt;text&gt;</code>
                <span>Save a fact to persistent memory</span>
              </div>
              <div class="docs-command">
                <code>/forget &lt;number&gt;</code>
                <span>Remove a memory by number</span>
              </div>
              <div class="docs-command">
                <code>/memories</code>
                <span>List all saved memories</span>
              </div>
              <div class="docs-command">
                <code>/mcp</code>
                <span>List connected MCP servers and tools</span>
              </div>
              <div class="docs-command">
                <code>/clear</code>
                <span>Clear chat history</span>
              </div>
              <div class="docs-command">
                <code>/help</code>
                <span>List all commands</span>
              </div>

              <p class="docs-note">You can also ask to search in plain language, e.g. "search for golang tutorials"</p>
            </div>
          </div>
        </div>

      </div>

      {/* Status Bar */}
      <div class="status-bar">
        <span>{currentModel() ? `Model: ${currentModel()}` : "No model"} | {models().length} installed</span>
        <span class="status-activity">
          {searching() ? "Searching..." :
           streaming() ? "Chatting..." :
           status().phase !== "idle" ? status().phase :
           busy() ? "Working..." :
           "Idle"}
        </span>
        <span>Buster Claw</span>
      </div>
    </div>
  );
}

export default App;
