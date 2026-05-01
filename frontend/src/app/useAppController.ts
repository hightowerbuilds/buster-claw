import { createSignal, onCleanup, onMount } from "solid-js";
import { createMutation, createQuery, useQueryClient } from "@tanstack/solid-query";
import { GetModels } from "../../wailsjs/go/main/App";
import type { View } from "./navigation";
import { state, setState } from "../store";
import type { ChatMessage, DocumentInfo, OrchestratorStatus, ReportMeta } from "../wails.d";

export function useAppController() {
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

  const [newSourceUrl, setNewSourceUrl] = createSignal("");
  const [newSourceName, setNewSourceName] = createSignal("");
  const [newSourceType, setNewSourceType] = createSignal("rss");
  const [newSourceTags, setNewSourceTags] = createSignal("");
  const [selectedReport, setSelectedReport] = createSignal<ReportMeta | null>(null);
  const [reportContent, setReportContent] = createSignal("");
  const [selectedDocument, setSelectedDocument] = createSignal<DocumentInfo | null>(null);
  const [documentContent, setDocumentContent] = createSignal("");

  const [newMemory, setNewMemory] = createSignal("");
  const [provName, setProvName] = createSignal("");
  const [provType, setProvType] = createSignal("openrouter");
  const [provUrl, setProvUrl] = createSignal("");
  const [provKey, setProvKey] = createSignal("");
  const [provModel, setProvModel] = createSignal("");
  const [testResult, setTestResult] = createSignal("");

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
    enabled: activeView() === "documents" || activeView() === "home",
  }));
  const queueQuery = createQuery(() => ({
    queryKey: ["queue"],
    queryFn: () => window.go.main.App.GetAnalysisQueue(),
    enabled: activeView() === "documents" || activeView() === "home",
  }));
  const reportsQuery = createQuery(() => ({
    queryKey: ["reports"],
    queryFn: () => window.go.main.App.GetReportManifest(),
    enabled: activeView() === "analysis" || activeView() === "home",
  }));
  const memoriesQuery = createQuery(() => ({
    queryKey: ["memories"],
    queryFn: () => window.go.main.App.GetMemories(),
    enabled: activeView() === "advanced",
  }));
  const providersQuery = createQuery(() => ({
    queryKey: ["providers"],
    queryFn: () => window.go.main.App.GetProviders(),
    enabled: activeView() === "intelligence",
  }));
  const schedulerQuery = createQuery(() => ({
    queryKey: ["scheduler"],
    queryFn: () => window.go.main.App.GetJobs(),
    enabled: activeView() === "calendar" || activeView() === "home",
    refetchInterval: activeView() === "calendar" || activeView() === "home" ? 5000 : false,
  }));
  const calendarQuery = createQuery(() => ({
    queryKey: ["calendar-events"],
    queryFn: () => window.go.main.App.GetCalendarEvents(),
    enabled: activeView() === "calendar" || activeView() === "home",
  }));
  const webhooksQuery = createQuery(() => ({
    queryKey: ["webhooks"],
    queryFn: () => window.go.main.App.GetWebhooks(),
    enabled: activeView() === "webhooks",
  }));
  const deliveryQuery = createQuery(() => ({
    queryKey: ["delivery"],
    queryFn: () => window.go.main.App.GetDeliveryDestinations(),
    enabled: activeView() === "advanced",
  }));
  const hooksQuery = createQuery(() => ({
    queryKey: ["hooks"],
    queryFn: () => window.go.main.App.GetHooks(),
    enabled: activeView() === "webhooks",
  }));

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

  const switchView = (view: View) => setActiveView(view);

  onMount(async () => {
    try { setCurrentModel(await window.go.main.App.GetCurrentModel()); } catch (error) { console.error(error); }
    try { setMessages(await window.go.main.App.GetMessages() || []); } catch (error) { console.error(error); }
    window.runtime.EventsOn("chat:searching", (query: string) => setState("searching", query));
    window.runtime.EventsOn("chat:token", (chunk: string) => {
      setState("searching", "");
      setState("waiting", false);
      setState("streaming", true);
      setState("streamBuffer", (prev) => prev + chunk);
    });
    window.runtime.EventsOn("chat:done", () => {
      const buf = state.streamBuffer;
      if (buf) setMessages((prev) => [...prev, { role: "assistant", content: buf }]);
      setState({ streamBuffer: "", streaming: false, searching: "", waiting: false });
    });
    window.runtime.EventsOn("chat:error", (err: string) => {
      setMessages((prev) => [...prev, { role: "assistant", content: `Error: ${err}` }]);
      setState({ streamBuffer: "", streaming: false, searching: "", waiting: false });
    });
    window.runtime.EventsOn("chat:cleared", () => {
      setMessages([]);
      setState({ streamBuffer: "", streaming: false, searching: "", waiting: false });
    });
    window.runtime.EventsOn("orchestrator:status", (s: OrchestratorStatus) => {
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

  const sendMessage = async () => {
    const prompt = input().trim();
    if (!prompt || state.streaming) return;
    setInput("");
    setMessages((prev) => [...prev, { role: "user", content: prompt }]);
    setState("waiting", true);
    try {
      await window.go.main.App.SendMessage(prompt);
    } catch (error: any) {
      setState("waiting", false);
      setMessages((prev) => [...prev, { role: "assistant", content: `Error: ${error.message || error}` }]);
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
      setMessages((prev) => [...prev, { role: "assistant", content: result.error ? `Ingestion error: ${result.error}` : `Ingestion complete. Saved ${result.savedCount} files.` }]);
      qc.invalidateQueries({ queryKey: ["documents"] });
      qc.invalidateQueries({ queryKey: ["pending"] });
    } finally {
      setState("busy", false);
    }
  };

  const ingestSingle = async (url: string) => {
    setState("busy", true);
    try {
      const result = await window.go.main.App.IngestSource(url);
      setMessages((prev) => [...prev, { role: "assistant", content: result.error ? `Ingestion error: ${result.error}` : `Ingested ${result.savedCount} files from source.` }]);
      qc.invalidateQueries({ queryKey: ["documents"] });
      qc.invalidateQueries({ queryKey: ["pending"] });
    } finally {
      setState("busy", false);
    }
  };

  const runQueue = async () => {
    setState("busy", true);
    try {
      const result = await window.go.main.App.StartAnalysis();
      if (result.error) setMessages((prev) => [...prev, { role: "assistant", content: `Analysis error: ${result.error}` }]);
      qc.invalidateQueries({ queryKey: ["queue"] });
      qc.invalidateQueries({ queryKey: ["pending"] });
      qc.invalidateQueries({ queryKey: ["reports"] });
    } finally {
      setState("busy", false);
    }
  };

  const openReport = async (report: ReportMeta) => {
    try {
      setReportContent(await window.go.main.App.GetReportContent(report.filename));
      setSelectedReport(report);
    } catch (error) {
      console.error(error);
    }
  };

  const closeReport = () => {
    setSelectedReport(null);
    setReportContent("");
  };

  const openDocument = async (doc: DocumentInfo) => {
    try {
      setDocumentContent(await window.go.main.App.GetDocumentContent(doc.path));
      setSelectedDocument(doc);
    } catch (error) {
      console.error(error);
    }
  };

  const closeDocument = () => {
    setSelectedDocument(null);
    setDocumentContent("");
  };

  const addSource = () => {
    const url = newSourceUrl().trim();
    if (!url) return;
    const tags = newSourceTags().trim() ? newSourceTags().split(",").map((tag) => tag.trim()).filter(Boolean) : [];
    addSourceMut.mutate({ url, type: newSourceType(), tags, name: newSourceName().trim() });
    setNewSourceUrl("");
    setNewSourceName("");
    setNewSourceTags("");
  };

  const clearChat = async () => {
    await window.go.main.App.ClearMessages();
    setMessages([]);
    setState("streamBuffer", "");
  };

  const testProvider = async (name: string) => {
    setTestResult("Testing...");
    try {
      setTestResult(`${name}: ${await window.go.main.App.TestProvider(name)}`);
    } catch (error: any) {
      setTestResult(`${name}: Error - ${error.message || error}`);
    }
  };

  const addProvider = (provider: { name: string; type: string; baseUrl: string; apiKey: string; model: string }) => {
    addProviderMut.mutate(provider);
    setProvName(""); setProvUrl(""); setProvKey(""); setProvModel("");
  };

  const addWebhook = (webhook: { name: string; action: string; customCmd: string; deliverTo: string }) => {
    addWebhookMut.mutate({ ...webhook, enabled: true });
    setWhName(""); setWhCmd("");
  };

  const addDestination = (destination: { name: string; type: string; url: string; token: string; chatId: string }) => {
    addDeliveryMut.mutate({ name: destination.name, destType: destination.type, url: destination.url, token: destination.token, chatId: destination.chatId, enabled: true });
    setDestName(""); setDestUrl(""); setDestToken(""); setDestChatId("");
  };

  const addHook = (hook: { name: string; event: string; type: string; target: string; async: boolean }) => {
    addHookMut.mutate({ ...hook, enabled: true });
    setHkName(""); setHkTarget("");
  };

  return {
    get activeView() { return activeView(); },
    get messages() { return messages(); },
    get input() { return input(); },
    get currentModel() { return currentModel(); },
    get status() { return status(); },
    get models() { return modelsQuery.data || []; },
    get sources() { return sourcesQuery.data || []; },
    get documents() { return documentsQuery.data || []; },
    get pendingFiles() { return pendingQuery.data || []; },
    get analysisQueue() { return queueQuery.data || []; },
    get reports() { return reportsQuery.data || []; },
    get memories() { return memoriesQuery.data || []; },
    get providers() { return providersQuery.data || []; },
    get jobs() { return schedulerQuery.data || []; },
    get calendarEvents() { return calendarQuery.data || []; },
    get webhooks() { return webhooksQuery.data || []; },
    get destinations() { return deliveryQuery.data || []; },
    get pipelineHooks() { return hooksQuery.data || []; },
    get busy() { return state.busy; },
    get streaming() { return state.streaming; },
    get searching() { return state.searching; },
    get waiting() { return state.waiting; },
    get streamBuffer() { return state.streamBuffer; },
    get sourceForm() { return { url: newSourceUrl(), name: newSourceName(), type: newSourceType(), tags: newSourceTags() }; },
    get selectedReport() { return selectedReport(); },
    get reportContent() { return reportContent(); },
    get selectedDocument() { return selectedDocument(); },
    get documentContent() { return documentContent(); },
    get newMemory() { return newMemory(); },
    get providerForm() { return { name: provName(), type: provType(), baseUrl: provUrl(), apiKey: provKey(), model: provModel() }; },
    get testResult() { return testResult(); },
    get webhookForm() { return { name: whName(), action: whAction(), customCmd: whCmd(), deliverTo: whDeliver() }; },
    get deliveryForm() { return { name: destName(), type: destType(), url: destUrl(), token: destToken(), chatId: destChatId() }; },
    get hookForm() { return { name: hkName(), event: hkEvent(), type: hkType(), target: hkTarget(), async: hkAsync() }; },
    get statusActivity() {
      if (state.searching) return "Searching...";
      if (state.streaming) return "Chatting...";
      if (status().phase !== "idle") return status().phase;
      if (state.busy) return "Working...";
      return "Idle";
    },
    switchView,
    clearChat,
    setInput,
    sendMessage,
    setNewSourceUrl,
    setNewSourceName,
    setNewSourceType,
    setNewSourceTags,
    startIngest,
    ingestSingle,
    deleteSource: (url: string) => deleteSourceMut.mutate(url),
    addSource,
    deleteDocument: (path: string) => deleteDocMut.mutate(path),
    runQueue,
    removeFromQueue: (path: string) => removeQueueMut.mutate(path),
    queueDocument: (path: string) => queueDocMut.mutate(path),
    openDocument,
    closeDocument,
    openReport,
    closeReport,
    refreshModels: () => qc.invalidateQueries({ queryKey: ["models"] }),
    switchModel,
    setNewMemory,
    addMemory: (text: string) => addMemoryMut.mutate(text),
    removeMemory: (index: number) => removeMemoryMut.mutate(index),
    updateProviderForm: (field: "name" | "type" | "baseUrl" | "apiKey" | "model", value: string) => {
      if (field === "name") setProvName(value);
      if (field === "type") setProvType(value);
      if (field === "baseUrl") setProvUrl(value);
      if (field === "apiKey") setProvKey(value);
      if (field === "model") setProvModel(value);
    },
    addProvider,
    activateProvider: (name: string) => setActiveMut.mutate(name),
    removeProvider: (name: string) => removeProviderMut.mutate(name),
    testProvider,
    updateWebhookForm: (field: "name" | "action" | "customCmd" | "deliverTo", value: string) => {
      if (field === "name") setWhName(value);
      if (field === "action") setWhAction(value);
      if (field === "customCmd") setWhCmd(value);
      if (field === "deliverTo") setWhDeliver(value);
    },
    addWebhook,
    toggleWebhook: (name: string, enabled: boolean) => toggleWebhookMut.mutate({ name, enabled }),
    deleteWebhook: (name: string) => deleteWebhookMut.mutate(name),
    updateDeliveryForm: (field: "name" | "type" | "url" | "token" | "chatId", value: string) => {
      if (field === "name") setDestName(value);
      if (field === "type") setDestType(value);
      if (field === "url") setDestUrl(value);
      if (field === "token") setDestToken(value);
      if (field === "chatId") setDestChatId(value);
    },
    addDestination,
    testDestination: (name: string) => testDeliveryMut.mutate(name),
    deleteDestination: (name: string) => deleteDeliveryMut.mutate(name),
    updateHookForm: (field: "name" | "event" | "type" | "target" | "async", value: string | boolean) => {
      if (field === "name" && typeof value === "string") setHkName(value);
      if (field === "event" && typeof value === "string") setHkEvent(value);
      if (field === "type" && typeof value === "string") setHkType(value);
      if (field === "target" && typeof value === "string") setHkTarget(value);
      if (field === "async" && typeof value === "boolean") setHkAsync(value);
    },
    addHook,
    deleteHook: (name: string) => deleteHookMut.mutate(name),
  };
}
