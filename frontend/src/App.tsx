import { createSignal, createEffect, onMount, onCleanup, For, Show } from "solid-js";
import { createQuery, createMutation, useQueryClient } from "@tanstack/solid-query";
import { marked } from "marked";
import type { ChatMessage, OrchestratorStatus, Source, DocumentInfo, PendingFile, ReportMeta, QueueEntry, MemoryEntry, ProviderInfo, JobState, Webhook, DeliveryDestination, Hook } from "./wails.d";

type View = "home" | "chat" | "ingestion" | "documents" | "orchestration" | "analysis" | "models" | "providers" | "memory" | "scheduler" | "webhooks" | "delivery" | "hooks" | "docs";

function AnalogClock() {
  const [time, setTime] = createSignal(new Date());

  createEffect(() => {
    const timer = setInterval(() => setTime(new Date()), 1000);
    onCleanup(() => clearInterval(timer));
  });

  const secondsDegrees = () => (time().getSeconds() / 60) * 360;
  const minsDegrees = () => ((time().getMinutes() + time().getSeconds() / 60) / 60) * 360;
  const hourDegrees = () => ((time().getHours() % 12 + time().getMinutes() / 60) / 12) * 360;

  return (
    <div class="analog-clock-wrapper">
      <div class="analog-clock">
        <div class="clock-center"></div>
        <div class="clock-hand hour-hand" style={{ transform: `rotate(${hourDegrees()}deg)` }}></div>
        <div class="clock-hand minute-hand" style={{ transform: `rotate(${minsDegrees()}deg)` }}></div>
        <div class="clock-hand second-hand" style={{ transform: `rotate(${secondsDegrees()}deg)` }}></div>
      </div>
    </div>
  );
}

function App() {
  const qc = useQueryClient();
  const [activeView, setActiveView] = createSignal<View>("home");
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
    activeJobs: [],
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
    enabled: activeView() === "documents" || activeView() === "home",
  }));

  const pendingQuery = createQuery(() => ({
    queryKey: ["pending"],
    queryFn: () => window.go.main.App.GetPendingFiles(),
    enabled: activeView() === "orchestration" || activeView() === "home",
  }));

  const queueQuery = createQuery(() => ({
    queryKey: ["queue"],
    queryFn: () => window.go.main.App.GetAnalysisQueue(),
    enabled: activeView() === "orchestration" || activeView() === "home",
  }));

  const reportsQuery = createQuery(() => ({
    queryKey: ["reports"],
    queryFn: () => window.go.main.App.GetReportManifest(),
    enabled: activeView() === "analysis" || activeView() === "home",
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

  const schedulerQuery = createQuery(() => ({
    queryKey: ["scheduler"],
    queryFn: () => window.go.main.App.GetJobs(),
    enabled: activeView() === "scheduler",
    refetchInterval: activeView() === "scheduler" ? 5000 : false, // Poll every 5s for NextRun/LastRun updates
  }));

  const jobs = () => schedulerQuery.data || [];

  const webhooksQuery = createQuery(() => ({
    queryKey: ["webhooks"],
    queryFn: () => window.go.main.App.GetWebhooks(),
    enabled: activeView() === "webhooks",
  }));

  const webhooks = () => webhooksQuery.data || [];

  const deliveryQuery = createQuery(() => ({
    queryKey: ["delivery"],
    queryFn: () => window.go.main.App.GetDeliveryDestinations(),
    enabled: activeView() === "delivery",
  }));

  const destinations = () => deliveryQuery.data || [];

  const hooksQuery = createQuery(() => ({
    queryKey: ["hooks"],
    queryFn: () => window.go.main.App.GetHooks(),
    enabled: activeView() === "hooks",
  }));

  const pipelineHooks = () => hooksQuery.data || [];

  // Form state
  const [newMemory, setNewMemory] = createSignal("");
  const [provName, setProvName] = createSignal("");
  const [provType, setProvType] = createSignal("openrouter");
  const [provUrl, setProvUrl] = createSignal("");
  const [provKey, setProvKey] = createSignal("");
  const [provModel, setProvModel] = createSignal("");
  const [testResult, setTestResult] = createSignal("");

  const [jobId, setJobId] = createSignal("");
  const [jobType, setJobType] = createSignal("ingest");
  const [jobCron, setJobCron] = createSignal("0 7 * * *");
  const [jobEnabled, setJobEnabled] = createSignal(true);
  const [jobCustomCmd, setJobCustomCmd] = createSignal("");
  const [jobDeliverTo, setJobDeliverTo] = createSignal("");

  const [whName, setWhName] = createSignal("");
  const [whAction, setWhAction] = createSignal("ingest");
  const [whCmd, setWhCmd] = createSignal("");
  const [whDeliver, setWhDeliver] = createSignal("");

  const [destName, setDestName] = createSignal("");
  const [destType, setDestType] = createSignal("slack");
  const [destUrl, setDestUrl] = createSignal("");
  const [destToken, setDestToken] = createSignal("");
  const [destChatId, setDestChatId] = createSignal("");

  const [hkName, setHkName] = createSignal("");
  const [hkEvent, setHkEvent] = createSignal("post_ingest");
  const [hkType, setHkType] = createSignal("shell");
  const [hkTarget, setHkTarget] = createSignal("");
  const [hkAsync, setHkAsync] = createSignal(true);

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

  const addJobMut = createMutation(() => ({
    mutationFn: (args: { id: string; type: string; cron: string; enabled: boolean; customCmd: string; deliverTo: string }) =>
      window.go.main.App.AddJob(args.id, args.type, args.cron, args.enabled, args.customCmd, args.deliverTo),
    onSuccess: () => qc.invalidateQueries({ queryKey: ["scheduler"] }),
  }));

  const updateJobMut = createMutation(() => ({
    mutationFn: (args: { id: string; type: string; cron: string; enabled: boolean; customCmd: string; deliverTo: string }) =>
      window.go.main.App.UpdateJob(args.id, args.type, args.cron, args.enabled, args.customCmd, args.deliverTo),
    onSuccess: () => qc.invalidateQueries({ queryKey: ["scheduler"] }),
  }));

  const deleteJobMut = createMutation(() => ({
    mutationFn: (id: string) => window.go.main.App.DeleteJob(id),
    onSuccess: () => qc.invalidateQueries({ queryKey: ["scheduler"] }),
  }));

  const runJobNowMut = createMutation(() => ({
    mutationFn: (id: string) => window.go.main.App.RunJobNow(id),
    onSuccess: () => qc.invalidateQueries({ queryKey: ["scheduler"] }),
  }));

  const addWebhookMut = createMutation(() => ({
    mutationFn: (args: { name: string; action: string; enabled: boolean; customCmd: string; deliverTo: string }) =>
      window.go.main.App.AddWebhook(args.name, args.action, args.enabled, args.customCmd, args.deliverTo),
    onSuccess: () => qc.invalidateQueries({ queryKey: ["webhooks"] }),
  }));

  const deleteWebhookMut = createMutation(() => ({
    mutationFn: (name: string) => window.go.main.App.DeleteWebhook(name),
    onSuccess: () => qc.invalidateQueries({ queryKey: ["webhooks"] }),
  }));

  const toggleWebhookMut = createMutation(() => ({
    mutationFn: (args: { name: string; enabled: boolean }) => window.go.main.App.ToggleWebhook(args.name, args.enabled),
    onSuccess: () => qc.invalidateQueries({ queryKey: ["webhooks"] }),
  }));

  const addDeliveryMut = createMutation(() => ({
    mutationFn: (args: { name: string; destType: string; url: string; token: string; chatId: string; enabled: boolean }) =>
      window.go.main.App.AddDeliveryDestination(args.name, args.destType, args.url, args.token, args.chatId, args.enabled),
    onSuccess: () => qc.invalidateQueries({ queryKey: ["delivery"] }),
  }));

  const deleteDeliveryMut = createMutation(() => ({
    mutationFn: (name: string) => window.go.main.App.DeleteDeliveryDestination(name),
    onSuccess: () => qc.invalidateQueries({ queryKey: ["delivery"] }),
  }));

  const testDeliveryMut = createMutation(() => ({
    mutationFn: (name: string) => window.go.main.App.TestDeliveryDestination(name),
  }));

  const addHookMut = createMutation(() => ({
    mutationFn: (args: { name: string; event: string; type: string; target: string; async: boolean; enabled: boolean }) =>
      window.go.main.App.AddHook(args.name, args.event, args.type, args.target, args.async, args.enabled),
    onSuccess: () => qc.invalidateQueries({ queryKey: ["hooks"] }),
  }));

  const deleteHookMut = createMutation(() => ({
    mutationFn: (name: string) => window.go.main.App.DeleteHook(name),
    onSuccess: () => qc.invalidateQueries({ queryKey: ["hooks"] }),
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
          <button class="sidebar-btn" classList={{ "sidebar-btn-active": activeView() === "home" }} onClick={() => switchView("home")}>Home</button>
          <button class="sidebar-btn" classList={{ "sidebar-btn-active": activeView() === "chat" }} onClick={() => switchView("chat")}>Chat</button>
          <button class="sidebar-btn" classList={{ "sidebar-btn-active": activeView() === "ingestion" }} onClick={() => switchView("ingestion")}>Ingestion</button>
          <button class="sidebar-btn" classList={{ "sidebar-btn-active": activeView() === "documents" }} onClick={() => switchView("documents")}>Documents</button>
          <button class="sidebar-btn" classList={{ "sidebar-btn-active": activeView() === "orchestration" }} onClick={() => switchView("orchestration")}>Orchestration</button>
          <button class="sidebar-btn" classList={{ "sidebar-btn-active": activeView() === "analysis" }} onClick={() => switchView("analysis")}>Analysis</button>
          <button class="sidebar-btn" classList={{ "sidebar-btn-active": activeView() === "scheduler" }} onClick={() => switchView("scheduler")}>Scheduler</button>
          <button class="sidebar-btn" classList={{ "sidebar-btn-active": activeView() === "webhooks" }} onClick={() => switchView("webhooks")}>Webhooks</button>
          <button class="sidebar-btn" classList={{ "sidebar-btn-active": activeView() === "delivery" }} onClick={() => switchView("delivery")}>Delivery</button>
          <button class="sidebar-btn" classList={{ "sidebar-btn-active": activeView() === "hooks" }} onClick={() => switchView("hooks")}>Hooks</button>
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
          <div class="status-card" style="margin-top: 6px">
            <div class="label">Parallel Workers</div>
            <div class="value">{status().activeJobs.length > 1 ? status().activeJobs.length : (status().activeJob ? 1 : 0)} active</div>
          </div>
          <For each={status().activeJobs}>
            {(job) => (
              <div class="status-card" style="margin-top: 6px">
                <div class="label">Active</div>
                <div class="value active">{job}</div>
              </div>
            )}
          </For>
        </div>

        <div class="sidebar-section">
          <h3>Actions</h3>
          <button class="sidebar-btn" onClick={clearChat}>Clear Chat</button>
        </div>
      </div>

      {/* Main Content */}
      <div class="main-content">

        {/* Home View */}
        <div class="view-panel home-view" classList={{ hidden: activeView() !== "home" }}>
          <div class="newspaper-container">
            <main class="newspaper-grid">
              <div class="main-column">
                <h2 class="section-title">Latest Analysis</h2>
                <Show when={reports().length > 0} fallback={<p class="empty-story">No recent analysis available. The newsroom is quiet.</p>}>
                  <div class="featured-story">
                    <div class="story-list">
                      <For each={reports().slice().reverse().slice(0, 5)}>
                        {(r) => (
                          <div class="story-item" onClick={() => { openReport(r); switchView("analysis"); }}>
                            <h4>{r.filename.replace("report-", "").replace(".md", "").replace(/-/g, " ")}</h4>
                            <div class="story-meta">
                              <span>{r.source_url ? new URL(r.source_url).hostname : r.source_file}</span>
                              <span>{new Date(r.generated_at).toLocaleDateString()}</span>
                            </div>
                          </div>
                        )}
                      </For>
                    </div>
                  </div>
                </Show>
              </div>

              <div class="side-column">
                <div class="sidebar-module">
                  <AnalogClock />
                  <h2 class="section-title">Recent Ingestions</h2>
                  <ul class="brief-list">
                    <Show when={documents().length > 0} fallback={<li class="empty-story">No recent ingestions.</li>}>
                      <For each={documents().slice().reverse().slice(0, 6)}>
                        {(doc) => (
                          <li>
                            <div class="doc-title">{doc.name || doc.filename.replace(".md", "")}</div>
                            <div class="story-meta">{doc.sourceUrl ? new URL(doc.sourceUrl).hostname : "Local"}</div>
                          </li>
                        )}
                      </For>
                    </Show>
                  </ul>
                </div>

                <div class="sidebar-module" style="margin-top: 24px;">
                  <h2 class="section-title">Up Next</h2>
                  <ul class="brief-list">
                    <Show when={analysisQueue().length > 0 || pendingFiles().length > 0} fallback={<li class="empty-story">The queue is empty.</li>}>
                      <For each={analysisQueue().slice(0, 4)}>
                        {(q) => (
                          <li>
                            <div class="doc-title">{q.filename.replace(".md", "")}</div>
                            <div class="queue-status" classList={{ "active": q.status === "analyzing" }}>{q.status}</div>
                          </li>
                        )}
                      </For>
                      <Show when={pendingFiles().length > 0}>
                        <li class="queue-more text-muted" style="margin-top: 8px; font-size: 0.85em; font-style: italic;">
                          ...and {pendingFiles().length} pending items.
                        </li>
                      </Show>
                    </Show>
                  </ul>
                </div>
              </div>
            </main>
          </div>
        </div>

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

        {/* Scheduler View */}
        <div class="view-panel" classList={{ hidden: activeView() !== "scheduler" }}>
          <div class="view-panel-content">
            <div class="view-header">
              <h2>Scheduler</h2>
              <p>Configure autonomous background jobs.</p>
            </div>
            
            <div class="action-bar">
              <input type="text" class="search-input" placeholder="Job ID" value={jobId()} onInput={(e) => setJobId(e.currentTarget.value)} />
              <select class="search-input" value={jobType()} onChange={(e) => setJobType(e.currentTarget.value)}>
                <option value="ingest">Ingest</option>
                <option value="analyze">Analyze</option>
                <option value="full">Full Pipeline</option>
                <option value="custom">Custom Command</option>
              </select>
              <input type="text" class="search-input" placeholder="Cron (e.g. 0 7 * * *)" value={jobCron()} onInput={(e) => setJobCron(e.currentTarget.value)} />
              
              <Show when={jobType() === "custom"}>
                <input type="text" class="search-input" placeholder="/search AI news" value={jobCustomCmd()} onInput={(e) => setJobCustomCmd(e.currentTarget.value)} />
              </Show>

              <button class="btn btn-primary" onClick={() => {
                if (!jobId() || !jobCron()) return;
                addJobMut.mutate({ id: jobId(), type: jobType(), cron: jobCron(), enabled: true, customCmd: jobCustomCmd(), deliverTo: jobDeliverTo() });
                setJobId(""); setJobCustomCmd("");
              }}>Add Job</button>
            </div>

            <table class="data-table">
              <thead>
                <tr>
                  <th>ID</th>
                  <th>Type</th>
                  <th>Schedule</th>
                  <th>Status</th>
                  <th>Last Run</th>
                  <th>Next Run</th>
                  <th>Actions</th>
                </tr>
              </thead>
              <tbody>
                <Show when={jobs().length === 0}>
                  <tr><td colspan="7" class="empty-state">No scheduled jobs.</td></tr>
                </Show>
                <For each={jobs()}>
                  {(job) => (
                    <tr>
                      <td class="primary-col">{job.id}</td>
                      <td>{job.type}{job.customCmd ? ` (${job.customCmd})` : ""}</td>
                      <td class="mono">{job.cron}</td>
                      <td>
                        <button 
                          class="status-badge" 
                          classList={{ "success": job.enabled, "failed": !job.enabled }}
                          onClick={() => updateJobMut.mutate({ ...job, enabled: !job.enabled })}
                        >
                          {job.enabled ? "Active" : "Paused"}
                        </button>
                      </td>
                      <td class="mono" style="font-size: 0.85em;">
                        {job.lastRun ? new Date(job.lastRun).toLocaleString() : "Never"}
                        <Show when={job.lastError}>
                          <div class="text-error" style="margin-top: 4px">{job.lastError}</div>
                        </Show>
                      </td>
                      <td class="mono" style="font-size: 0.85em;">
                        {job.nextRun ? new Date(job.nextRun).toLocaleString() : "-"}
                      </td>
                      <td class="actions-col">
                        <button class="icon-btn" title="Run Now" onClick={() => runJobNowMut.mutate(job.id)}>▶️</button>
                        <button class="icon-btn text-error" title="Delete" onClick={() => deleteJobMut.mutate(job.id)}>🗑️</button>
                      </td>
                    </tr>
                  )}
                </For>
              </tbody>
            </table>
          </div>
        </div>

        {/* Webhooks View */}
        <div class="view-panel" classList={{ hidden: activeView() !== "webhooks" }}>
          <div class="view-panel-content">
            <div class="view-header">
              <h2>Webhooks</h2>
              <p>External events can trigger research tasks. Base URL: <code>http://localhost:9090/hooks/</code></p>
            </div>

            <div class="action-bar">
              <input type="text" class="search-input" placeholder="Hook Name" value={whName()} onInput={(e) => setWhName(e.currentTarget.value)} />
              <select class="search-input" value={whAction()} onChange={(e) => setWhAction(e.currentTarget.value)}>
                <option value="ingest">Ingest All</option>
                <option value="analyze">Analyze Queue</option>
                <option value="full">Full Pipeline</option>
                <option value="command">Custom Command</option>
              </select>
              <Show when={whAction() === "command"}>
                <input type="text" class="search-input" placeholder="/search AI news" value={whCmd()} onInput={(e) => setWhCmd(e.currentTarget.value)} />
              </Show>
              <button class="btn btn-primary" onClick={() => {
                if (!whName()) return;
                addWebhookMut.mutate({ name: whName(), action: whAction(), enabled: true, customCmd: whCmd(), deliverTo: whDeliver() });
                setWhName(""); setWhCmd("");
              }}>Add Hook</button>
            </div>

            <table class="data-table">
              <thead>
                <tr>
                  <th>Name</th>
                  <th>Action</th>
                  <th>Endpoint</th>
                  <th>Status</th>
                  <th>Actions</th>
                </tr>
              </thead>
              <tbody>
                <Show when={webhooks().length === 0}>
                  <tr><td colspan="5" class="empty-state">No webhooks configured.</td></tr>
                </Show>
                <For each={webhooks()}>
                  {(hook) => (
                    <tr>
                      <td class="primary-col">{hook.name}</td>
                      <td>{hook.action}{hook.customCmd ? ` (${hook.customCmd})` : ""}</td>
                      <td class="mono" style="font-size: 0.85em;">/hooks/{hook.name}</td>
                      <td>
                        <button 
                          class="status-badge" 
                          classList={{ "success": hook.enabled, "failed": !hook.enabled }}
                          onClick={() => toggleWebhookMut.mutate({ name: hook.name, enabled: !hook.enabled })}
                        >
                          {hook.enabled ? "Active" : "Paused"}
                        </button>
                      </td>
                      <td class="actions-col">
                        <button class="icon-btn" title="Copy URL" onClick={() => {
                          navigator.clipboard.writeText(`http://localhost:9090/hooks/${hook.name}`);
                        }}>📋</button>
                        <button class="icon-btn text-error" title="Delete" onClick={() => deleteWebhookMut.mutate(hook.name)}>🗑️</button>
                      </td>
                    </tr>
                  )}
                </For>
              </tbody>
            </table>
          </div>
        </div>

          </div>
        </div>

        {/* Delivery View */}
        <div class="view-panel" classList={{ hidden: activeView() !== "delivery" }}>
          <div class="view-panel-content">
            <div class="view-header">
              <h2>Delivery</h2>
              <p>Configure where reports are sent after analysis.</p>
            </div>

            <div class="provider-add">
              <h4>Add Destination</h4>
              <div class="provider-add-fields">
                <div class="provider-add-row">
                  <input type="text" placeholder="Name (e.g. My Slack)" value={destName()} onInput={(e) => setDestName(e.currentTarget.value)} />
                  <select value={destType()} onChange={(e) => setDestType(e.currentTarget.value)}>
                    <option value="slack">Slack (Webhook)</option>
                    <option value="discord">Discord (Webhook)</option>
                    <option value="telegram">Telegram (Bot)</option>
                  </select>
                </div>
                <Show when={destType() === "slack" || destType() === "discord"}>
                  <input type="text" placeholder="Webhook URL" value={destUrl()} onInput={(e) => setDestUrl(e.currentTarget.value)} />
                </Show>
                <Show when={destType() === "telegram"}>
                  <div class="provider-add-row">
                    <input type="text" placeholder="Bot Token" value={destToken()} onInput={(e) => setDestToken(e.currentTarget.value)} />
                    <input type="text" placeholder="Chat ID" value={destChatId()} onInput={(e) => setDestChatId(e.currentTarget.value)} />
                  </div>
                </Show>
                <button class="action-btn" onClick={() => {
                  if (!destName()) return;
                  addDeliveryMut.mutate({
                    name: destName(),
                    destType: destType(),
                    url: destUrl(),
                    token: destToken(),
                    chatId: destChatId(),
                    enabled: true
                  });
                  setDestName(""); setDestUrl(""); setDestToken(""); setDestChatId("");
                }}>Add Destination</button>
              </div>
            </div>

            <div class="provider-list" style="margin-top: 24px;">
              <For each={destinations()} fallback={<div class="empty-list">No delivery destinations configured.</div>}>
                {(dest) => (
                  <div class="provider-item" classList={{ "provider-active": dest.enabled }}>
                    <div class="provider-item-info">
                      <div class="provider-item-name">{dest.name}</div>
                      <div class="provider-item-meta">
                        <span class="source-item-type">{dest.type}</span>
                        <Show when={dest.url}><span class="provider-item-url">{dest.url.substring(0, 40)}...</span></Show>
                        <Show when={dest.chatId}><span>Chat: {dest.chatId}</span></Show>
                      </div>
                    </div>
                    <div class="provider-item-actions">
                      <button class="source-ingest-btn" onClick={() => testDeliveryMut.mutate(dest.name)}>Test</button>
                      <button class="source-delete-btn" onClick={() => deleteDeliveryMut.mutate(dest.name)}>Remove</button>
                    </div>
                  </div>
                )}
              </For>
            </div>
          </div>
        </div>

        {/* Hooks View */}
        <div class="view-panel" classList={{ hidden: activeView() !== "hooks" }}>
          <div class="view-panel-content">
            <div class="view-header">
              <h2>Reactive Hooks</h2>
              <p>Execute shell commands or webhooks at specific points in the pipeline.</p>
            </div>

            <div class="provider-add">
              <h4>Add Hook</h4>
              <div class="provider-add-fields">
                <div class="provider-add-row">
                  <input type="text" placeholder="Hook Name" value={hkName()} onInput={(e) => setHkName(e.currentTarget.value)} />
                  <select value={hkEvent()} onChange={(e) => setHkEvent(e.currentTarget.value)}>
                    <option value="pre_ingest">Pre Ingest</option>
                    <option value="post_ingest">Post Ingest</option>
                    <option value="pre_analysis">Pre Analysis</option>
                    <option value="post_analysis">Post Analysis</option>
                    <option value="pre_report">Pre Report</option>
                    <option value="post_report">Post Report</option>
                    <option value="on_error">On Error</option>
                  </select>
                </div>
                <div class="provider-add-row">
                  <select value={hkType()} onChange={(e) => setHkType(e.currentTarget.value)}>
                    <option value="shell">Shell Command</option>
                    <option value="webhook">Webhook (POST)</option>
                  </select>
                  <label style="display: flex; align-items: center; gap: 8px; font-size: 0.9em;">
                    <input type="checkbox" checked={hkAsync()} onChange={(e) => setHkAsync(e.currentTarget.checked)} />
                    Async
                  </label>
                </div>
                <input type="text" placeholder={hkType() === "shell" ? "bash command (e.g. echo 'done' >> log.txt)" : "Webhook URL"} value={hkTarget()} onInput={(e) => setHkTarget(e.currentTarget.value)} />
                <button class="action-btn" onClick={() => {
                  if (!hkName() || !hkTarget()) return;
                  addHookMut.mutate({
                    name: hkName(),
                    event: hkEvent(),
                    type: hkType(),
                    target: hkTarget(),
                    async: hkAsync(),
                    enabled: true
                  });
                  setHkName(""); setHkTarget("");
                }}>Add Hook</button>
              </div>
            </div>

            <div class="provider-list" style="margin-top: 24px;">
              <For each={pipelineHooks()} fallback={<div class="empty-list">No reactive hooks configured.</div>}>
                {(hook) => (
                  <div class="provider-item" classList={{ "provider-active": hook.enabled }}>
                    <div class="provider-item-info">
                      <div class="provider-item-name">{hook.name} <span class="text-muted" style="font-size: 0.7em;">({hook.event})</span></div>
                      <div class="provider-item-meta">
                        <span class="source-item-type">{hook.type}</span>
                        <span class="provider-item-url">{hook.target.substring(0, 50)}{hook.target.length > 50 ? "..." : ""}</span>
                        <Show when={hook.async}><span>(async)</span></Show>
                      </div>
                    </div>
                    <div class="provider-item-actions">
                      <button class="source-delete-btn" onClick={() => deleteHookMut.mutate(hook.name)}>Remove</button>
                    </div>
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
