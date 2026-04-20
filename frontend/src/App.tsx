import { createSignal, createEffect, onMount, onCleanup, For, Show } from "solid-js";
import type { ChatMessage, OrchestratorStatus } from "./wails.d";

function App() {
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
  const [pendingCount, setPendingCount] = createSignal(0);
  const [busy, setBusy] = createSignal(false);

  let messagesEnd: HTMLDivElement | undefined;

  const scrollToBottom = () => {
    messagesEnd?.scrollIntoView({ behavior: "smooth" });
  };

  createEffect(() => {
    messages();
    streamBuffer();
    scrollToBottom();
  });

  onMount(async () => {
    // Load initial state
    try {
      const m = await window.go.main.App.GetModels();
      setModels(m || []);
      const cur = await window.go.main.App.GetCurrentModel();
      setCurrentModel(cur);
      const msgs = await window.go.main.App.GetMessages();
      setMessages(msgs || []);
      const pending = await window.go.main.App.GetPendingCount();
      setPendingCount(pending);
    } catch (e) {
      console.error("init error:", e);
    }

    // Listen for chat streaming events
    window.runtime.EventsOn("chat:token", (chunk: string) => {
      setStreaming(true);
      setStreamBuffer((prev) => prev + chunk);
    });

    window.runtime.EventsOn("chat:done", (_response: string) => {
      // Commit stream buffer to messages
      const buf = streamBuffer();
      if (buf) {
        setMessages((prev) => [...prev, { role: "assistant", content: buf }]);
      }
      setStreamBuffer("");
      setStreaming(false);
    });

    window.runtime.EventsOn("chat:error", (err: string) => {
      setMessages((prev) => [
        ...prev,
        { role: "assistant", content: `Error: ${err}` },
      ]);
      setStreamBuffer("");
      setStreaming(false);
    });

    window.runtime.EventsOn(
      "orchestrator:status",
      (s: OrchestratorStatus) => {
        setStatus(s);
      }
    );
  });

  onCleanup(() => {
    window.runtime.EventsOff("chat:token");
    window.runtime.EventsOff("chat:done");
    window.runtime.EventsOff("chat:error");
    window.runtime.EventsOff("orchestrator:status");
  });

  const sendMessage = async () => {
    const prompt = input().trim();
    if (!prompt || streaming()) return;

    setInput("");
    setMessages((prev) => [...prev, { role: "user", content: prompt }]);

    try {
      await window.go.main.App.SendMessage(prompt);
    } catch (e: any) {
      setMessages((prev) => [
        ...prev,
        { role: "assistant", content: `Error: ${e.message || e}` },
      ]);
    }
  };

  const handleKeyDown = (e: KeyboardEvent) => {
    if (e.key === "Enter" && !e.shiftKey) {
      e.preventDefault();
      sendMessage();
    }
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
        setMessages((prev) => [
          ...prev,
          { role: "assistant", content: `Ingestion error: ${result.error}` },
        ]);
      } else {
        setMessages((prev) => [
          ...prev,
          {
            role: "assistant",
            content: `Ingestion complete. Saved ${result.savedCount} files.`,
          },
        ]);
      }
      const pending = await window.go.main.App.GetPendingCount();
      setPendingCount(pending);
    } finally {
      setBusy(false);
    }
  };

  const startAnalysis = async () => {
    setBusy(true);
    try {
      const result = await window.go.main.App.StartAnalysis();
      if (result.error) {
        setMessages((prev) => [
          ...prev,
          { role: "assistant", content: `Analysis error: ${result.error}` },
        ]);
      } else {
        setMessages((prev) => [
          ...prev,
          {
            role: "assistant",
            content: `Analysis complete. Processed ${result.processedCount} files.`,
          },
        ]);
      }
      const pending = await window.go.main.App.GetPendingCount();
      setPendingCount(pending);
    } finally {
      setBusy(false);
    }
  };

  const startFull = async () => {
    setBusy(true);
    try {
      const result = await window.go.main.App.StartFullPipeline();
      if (result.error) {
        setMessages((prev) => [
          ...prev,
          { role: "assistant", content: `Pipeline error: ${result.error}` },
        ]);
      } else {
        setMessages((prev) => [
          ...prev,
          {
            role: "assistant",
            content: `Full pipeline complete. Ingested ${result.ingested}, analyzed ${result.analyzed}.`,
          },
        ]);
      }
      const pending = await window.go.main.App.GetPendingCount();
      setPendingCount(pending);
    } finally {
      setBusy(false);
    }
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
        <div class="header-status">
          <select
            class="model-select"
            value={currentModel()}
            onChange={(e) => switchModel(e.currentTarget.value)}
          >
            <Show
              when={models().length > 0}
              fallback={<option>No models</option>}
            >
              <For each={models()}>
                {(m) => <option value={m}>{m}</option>}
              </For>
            </Show>
          </select>
        </div>
      </div>

      {/* Sidebar */}
      <div class="sidebar">
        <div class="sidebar-section">
          <h3>Pipeline</h3>
          <button
            class="sidebar-btn"
            onClick={startFull}
            disabled={busy() || streaming()}
          >
            Run Full Pipeline
          </button>
          <button
            class="sidebar-btn"
            onClick={startIngest}
            disabled={busy() || streaming()}
          >
            Ingest Sources
          </button>
          <button
            class="sidebar-btn"
            onClick={startAnalysis}
            disabled={busy() || streaming()}
          >
            Analyze Queue
          </button>
        </div>

        <div class="sidebar-section">
          <h3>Status</h3>
          <div class="status-card">
            <div class="label">Phase</div>
            <div
              class="value"
              classList={{ active: status().phase !== "idle" }}
            >
              {status().phase || "idle"}
            </div>
          </div>
          <div class="status-card" style="margin-top: 6px">
            <div class="label">Queue</div>
            <div class="value">{pendingCount()} pending</div>
          </div>
          <div class="status-card" style="margin-top: 6px">
            <div class="label">Completed / Failed</div>
            <div class="value">
              {status().completedJobs} / {status().failedJobs}
            </div>
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
          <button class="sidebar-btn" onClick={refreshModels}>
            Refresh Models
          </button>
          <button class="sidebar-btn" onClick={clearChat}>
            Clear Chat
          </button>
        </div>
      </div>

      {/* Chat Area */}
      <div class="chat-area">
        <div class="messages">
          <Show
            when={messages().length > 0 || streaming()}
            fallback={
              <div class="empty-state">
                <h2>Welcome to Buster Claw</h2>
                <p>Chat with your local model or run the pipeline.</p>
                <p style="font-size: 11px; color: var(--text-muted)">
                  Model: {currentModel() || "none selected"}
                </p>
              </div>
            }
          >
            <For each={messages()}>
              {(msg) => (
                <div class={`message ${msg.role}`}>
                  <div class="message-role">
                    {msg.role === "user" ? "You" : "Gemma"}
                  </div>
                  <div class="message-content">{msg.content}</div>
                </div>
              )}
            </For>
            <Show when={streaming() && streamBuffer()}>
              <div class="message assistant">
                <div class="message-role">Gemma</div>
                <div class="message-content">
                  {streamBuffer()}
                  <span class="streaming-indicator" />
                </div>
              </div>
            </Show>
          </Show>
          <div ref={messagesEnd} />
        </div>

        <div class="input-area">
          <div class="input-row">
            <input
              type="text"
              placeholder={
                currentModel()
                  ? "Send a message..."
                  : "No model selected — choose one above"
              }
              value={input()}
              onInput={(e) => setInput(e.currentTarget.value)}
              onKeyDown={handleKeyDown}
              disabled={!currentModel() || streaming()}
            />
            <button
              onClick={sendMessage}
              disabled={!currentModel() || streaming() || !input().trim()}
            >
              Send
            </button>
          </div>
        </div>
      </div>

      {/* Status Bar */}
      <div class="status-bar">
        <span>
          {currentModel() ? `Model: ${currentModel()}` : "No model"} |{" "}
          {models().length} installed
        </span>
        <span>Buster Claw v1.0</span>
      </div>
    </div>
  );
}

export default App;
