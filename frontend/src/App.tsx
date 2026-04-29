import { createSignal, onMount, onCleanup, For, Show } from "solid-js";
import { createQuery, createMutation, useQueryClient } from "@tanstack/solid-query";
import { GetModels } from "../wailsjs/go/main/App";
import { type View } from "./app/navigation";
import { Header } from "./components/Header";
import { Sidebar } from "./components/Sidebar";
import { StatusBar } from "./components/StatusBar";
import { AnalysisView } from "./features/analysis/AnalysisView";
import { ChatView } from "./features/chat/ChatView";
import { DocsView } from "./features/docs/DocsView";
import { DocumentsView } from "./features/documents/DocumentsView";
import { HomeView } from "./features/home/HomeView";
import { IngestionView } from "./features/ingestion/IngestionView";
import { ModelsView } from "./features/models/ModelsView";
import { OrchestrationView } from "./features/orchestration/OrchestrationView";
import { state, setState } from "./store";
import type { ChatMessage, OrchestratorStatus, Source, DocumentInfo, PendingFile, ReportMeta, QueueEntry, MemoryEntry, ProviderInfo, JobState, Webhook, DeliveryDestination, Hook } from "./wails.d";

function App() {
  const qc = useQueryClient();
  const [activeView, setActiveView] = createSignal<View>("home");
  const [messages, setMessages] = createSignal<ChatMessage[]>([]);
  const [input, setInput] = createSignal("");
  const [currentModel, setCurrentModel] = createSignal("");
  const [status, setStatus] = createSignal<OrchestratorStatus>({
    phase: "idle",
    queueDepth: 0,
    activeJob: "",
    activeJobs: [],
    completedJobs: 0,
    failedJobs: 0,
  });

  // Form state
  const [newSourceUrl, setNewSourceUrl] = createSignal("");
  const [newSourceName, setNewSourceName] = createSignal("");
  const [newSourceType, setNewSourceType] = createSignal("rss");
  const [newSourceTags, setNewSourceTags] = createSignal("");
  const [selectedReport, setSelectedReport] = createSignal<ReportMeta | null>(null);
  const [reportContent, setReportContent] = createSignal("");

  // --- Queries ---
  const modelsQuery = createQuery(() => ({
    queryKey: ["models"],
    queryFn: () => GetModels(),
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
  const streaming = () => state.streaming;
  const searching = () => state.searching;
  const waiting = () => state.waiting;
  const streamBuffer = () => state.streamBuffer;

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
    enabled: activeView() === "scheduler" || activeView() === "home",
    refetchInterval: activeView() === "scheduler" || activeView() === "home" ? 5000 : false, // Poll for NextRun/LastRun updates
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
      setState("searching", query);
    });
    window.runtime.EventsOn("chat:token", (chunk: string) => {
      setState("searching", "");
      setState("waiting", false);
      setState("streaming", true);
      setState("streamBuffer", (prev) => prev + chunk);
    });
    window.runtime.EventsOn("chat:done", (_response: string) => {
      const buf = state.streamBuffer;
      if (buf) setMessages((prev) => [...prev, { role: "assistant", content: buf }]);
      setState({
        streamBuffer: "",
        streaming: false,
        searching: "",
        waiting: false
      });
    });
    window.runtime.EventsOn("chat:error", (err: string) => {
      setMessages((prev) => [...prev, { role: "assistant", content: `Error: ${err}` }]);
      setState({
        streamBuffer: "",
        streaming: false,
        searching: "",
        waiting: false
      });
    });
    window.runtime.EventsOn("chat:cleared", () => {
      setMessages([]);
      setState({
        streamBuffer: "",
        streaming: false,
        searching: "",
        waiting: false
      });
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
    if (!prompt || state.streaming) return;
    setInput("");
    setMessages((prev) => [...prev, { role: "user", content: prompt }]);
    setState("waiting", true);
    try { await window.go.main.App.SendMessage(prompt); } catch (e: any) {
      setState("waiting", false);
      setMessages((prev) => [...prev, { role: "assistant", content: `Error: ${e.message || e}` }]);
    }
  };

  const switchModel = async (name: string) => {
    setCurrentModel(name);
    await window.go.main.App.SetModel(name);
  };

  const startIngest = async () => {
    setState("busy", true);
    try {
      const result = await window.go.main.App.StartIngest();
      if (result.error) {
        setMessages((prev) => [...prev, { role: "assistant", content: `Ingestion error: ${result.error}` }]);
      } else {
        setMessages((prev) => [...prev, { role: "assistant", content: `Ingestion complete. Saved ${result.savedCount} files.` }]);
      }
      qc.invalidateQueries({ queryKey: ["documents"] });
      qc.invalidateQueries({ queryKey: ["pending"] });
    } finally { setState("busy", false); }
  };

  const ingestSingle = async (url: string) => {
    setState("busy", true);
    try {
      const result = await window.go.main.App.IngestSource(url);
      if (result.error) {
        setMessages((prev) => [...prev, { role: "assistant", content: `Ingestion error: ${result.error}` }]);
      } else {
        setMessages((prev) => [...prev, { role: "assistant", content: `Ingested ${result.savedCount} files from source.` }]);
      }
      qc.invalidateQueries({ queryKey: ["documents"] });
      qc.invalidateQueries({ queryKey: ["pending"] });
    } finally { setState("busy", false); }
  };

  const runQueue = async () => {
    setState("busy", true);
    try {
      const result = await window.go.main.App.StartAnalysis();
      if (result.error) {
        setMessages((prev) => [...prev, { role: "assistant", content: `Analysis error: ${result.error}` }]);
      }
      qc.invalidateQueries({ queryKey: ["queue"] });
      qc.invalidateQueries({ queryKey: ["pending"] });
      qc.invalidateQueries({ queryKey: ["reports"] });
    } finally { setState("busy", false); }
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
    setState("streamBuffer", "");
  };

  const statusActivity = () => {
    if (state.searching) return "Searching...";
    if (state.streaming) return "Chatting...";
    if (status().phase !== "idle") return status().phase;
    if (state.busy) return "Working...";
    return "Idle";
  };

  return (
    <div class="app">
      <Header />
      <Sidebar activeView={activeView()} status={status()} onSwitchView={switchView} onClearChat={clearChat} />

      {/* Main Content */}
      <div class="main-content">
        <HomeView
          visible={activeView() === "home"}
          jobs={jobs()}
          reports={reports()}
          documents={documents()}
          analysisQueue={analysisQueue()}
          pendingFiles={pendingFiles()}
          onOpenReport={(report) => {
            openReport(report);
            switchView("analysis");
          }}
        />

        <ChatView
          visible={activeView() === "chat"}
          messages={messages()}
          input={input()}
          currentModel={currentModel()}
          searching={searching()}
          waiting={waiting()}
          streaming={streaming()}
          streamBuffer={streamBuffer()}
          onInputChange={setInput}
          onSend={sendMessage}
        />

        <IngestionView
          visible={activeView() === "ingestion"}
          busy={state.busy}
          streaming={state.streaming}
          sources={sources()}
          sourceUrl={newSourceUrl()}
          sourceName={newSourceName()}
          sourceType={newSourceType()}
          sourceTags={newSourceTags()}
          onSourceUrlChange={setNewSourceUrl}
          onSourceNameChange={setNewSourceName}
          onSourceTypeChange={setNewSourceType}
          onSourceTagsChange={setNewSourceTags}
          onStartIngest={startIngest}
          onIngestSingle={ingestSingle}
          onDeleteSource={(url) => deleteSourceMut.mutate(url)}
          onAddSource={addSource}
        />

        <DocumentsView
          visible={activeView() === "documents"}
          documents={documents()}
          onDeleteDocument={(path) => deleteDocMut.mutate(path)}
        />

        <OrchestrationView
          visible={activeView() === "orchestration"}
          busy={state.busy}
          streaming={state.streaming}
          analysisQueue={analysisQueue()}
          pendingFiles={pendingFiles()}
          onRunQueue={runQueue}
          onRemoveFromQueue={(path) => removeQueueMut.mutate(path)}
          onQueueDocument={(path) => queueDocMut.mutate(path)}
        />

        <AnalysisView
          visible={activeView() === "analysis"}
          reports={reports()}
          selectedReport={selectedReport()}
          reportContent={reportContent()}
          onOpenReport={openReport}
          onCloseReport={closeReport}
        />

        <ModelsView
          visible={activeView() === "models"}
          models={models()}
          currentModel={currentModel()}
          onRefresh={() => qc.invalidateQueries({ queryKey: ["models"] })}
          onSelectModel={switchModel}
        />

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
                          onClick={() => updateJobMut.mutate({
                            id: job.id,
                            type: job.type,
                            cron: job.cron,
                            enabled: !job.enabled,
                            customCmd: job.customCmd || "",
                            deliverTo: job.deliverTo || "",
                          })}
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
                        <Show when={dest.url}><span class="provider-item-url">{dest.url!.substring(0, 40)}...</span></Show>
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

        <DocsView visible={activeView() === "docs"} />

      </div>

      <StatusBar currentModel={currentModel()} modelCount={models().length} activity={statusActivity()} />
    </div>
  );
}

export default App;
