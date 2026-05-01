// Type definitions for Wails runtime bindings.
// These map to the exported methods on the Go App struct.

export interface ChatMessage {
  role: string;
  content: string;
}

export interface OrchestratorStatus {
  phase: string;
  queueDepth: number;
  activeJob: string;
  activeJobs: string[];
  completedJobs: number;
  failedJobs: number;
}

export interface IngestResult {
  savedCount: number;
  error?: string;
}

export interface AnalysisResult {
  processedCount: number;
  error?: string;
}

export interface Source {
  url: string;
  type: string;
  tags: string[];
  name?: string;
}

export interface ReportMeta {
  filename: string;
  source_file: string;
  source_url: string;
  generated_at: string;
  model: string;
  intentions_used: boolean;
  tags?: string[];
}

export interface DocumentInfo {
  filename: string;
  path: string;
  date: string;
  sourceUrl: string;
  name: string;
  excerpt: string;
}

export interface PendingFile {
  filename: string;
  path: string;
  date: string;
}

export interface QueueEntry {
  filename: string;
  path: string;
  status: string; // "queued" | "analyzing" | "done" | "failed"
}

export interface MemoryEntry {
  index: number;
  createdAt: string;
  text: string;
}

export interface ProviderInfo {
  name: string;
  type: string;
  baseUrl: string;
  model: string;
  active: boolean;
  hasKey: boolean;
}

export interface JobState {
  id: string;
  type: string;
  cron: string;
  enabled: boolean;
  customCmd?: string;
  deliverTo?: string;
  nextRun: string;
  lastRun: string;
  lastError: string;
}

export interface CalendarEvent {
  id: string;
  date: string;
  title: string;
  notes?: string;
}

export interface Webhook {
  name: string;
  secret?: string;
  action: string;
  customCmd?: string;
  deliverTo?: string;
  enabled: boolean;
}

export interface DeliveryDestination {
  name: string;
  type: string;
  url?: string;
  token?: string;
  chatId?: string;
  enabled: boolean;
}

export interface Hook {
  name: string;
  event: string;
  type: string;
  target: string;
  async: boolean;
  enabled: boolean;
}

declare global {
  interface Window {
    go: {
      main: {
        App: {
          GetModels(): Promise<string[]>;
          GetCurrentModel(): Promise<string>;
          SetModel(name: string): Promise<void>;
          GetMessages(): Promise<ChatMessage[]>;
          SendMessage(prompt: string): Promise<void>;
          ClearMessages(): Promise<void>;
          StartIngest(): Promise<IngestResult>;
          IngestSource(url: string): Promise<IngestResult>;
          StartAnalysis(): Promise<AnalysisResult>;
          GetSources(): Promise<Source[]>;
          AddSource(url: string, type: string, tags: string[], name: string): Promise<void>;
          DeleteSource(url: string): Promise<void>;
          GetReportManifest(): Promise<ReportMeta[]>;
          GetDocuments(): Promise<DocumentInfo[]>;
          GetDocumentContent(path: string): Promise<string>;
          DeleteDocument(path: string): Promise<void>;
          GetPendingFiles(): Promise<PendingFile[]>;
          QueueDocument(path: string): Promise<void>;
          RemoveFromQueue(path: string): Promise<void>;
          GetAnalysisQueue(): Promise<QueueEntry[]>;
          GetReportContent(filename: string): Promise<string>;
          GetMemories(): Promise<MemoryEntry[]>;
          AddMemory(text: string): Promise<void>;
          RemoveMemory(index: number): Promise<void>;
          GetProviders(): Promise<ProviderInfo[]>;
          AddProvider(name: string, type: string, baseUrl: string, apiKey: string, model: string): Promise<void>;
          RemoveProvider(name: string): Promise<void>;
          SetActiveProvider(name: string): Promise<void>;
          TestProvider(name: string): Promise<string>;
          GetJobs(): Promise<JobState[]>;
          AddJob(id: string, jobType: string, cronStr: string, enabled: boolean, customCmd: string, deliverTo: string): Promise<void>;
          UpdateJob(id: string, jobType: string, cronStr: string, enabled: boolean, customCmd: string, deliverTo: string): Promise<void>;
          DeleteJob(id: string): Promise<void>;
          RunJobNow(id: string): Promise<void>;
          GetCalendarEvents(): Promise<CalendarEvent[]>;
          AddCalendarEvent(date: string, title: string, notes: string): Promise<CalendarEvent>;
          UpdateCalendarEvent(id: string, date: string, title: string, notes: string): Promise<void>;
          DeleteCalendarEvent(id: string): Promise<void>;
          GetWebhooks(): Promise<Webhook[]>;
          AddWebhook(name: string, action: string, enabled: boolean, customCmd: string, deliverTo: string): Promise<void>;
          DeleteWebhook(name: string): Promise<void>;
          ToggleWebhook(name: string, enabled: boolean): Promise<void>;
          GetDeliveryDestinations(): Promise<DeliveryDestination[]>;
          AddDeliveryDestination(name: string, destType: string, url: string, token: string, chatId: string, enabled: boolean): Promise<void>;
          DeleteDeliveryDestination(name: string): Promise<void>;
          TestDeliveryDestination(name: string): Promise<void>;
          GetHooks(): Promise<Hook[]>;
          AddHook(name: string, event: string, hookType: string, target: string, async: boolean, enabled: boolean): Promise<void>;
          DeleteHook(name: string): Promise<void>;
        };
      };
    };
    runtime: {
      EventsOn(event: string, callback: (...args: any[]) => void): () => void;
      EventsOff(event: string): void;
    };
  }
}
