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

export interface FullPipelineResult {
  ingested: number;
  analyzed: number;
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
          StartFullPipeline(): Promise<FullPipelineResult>;
          GetOrchestratorStatus(): Promise<OrchestratorStatus>;
          GetSources(): Promise<Source[]>;
          AddSource(url: string, type: string, tags: string[], name: string): Promise<void>;
          DeleteSource(url: string): Promise<void>;
          GetIntentions(): Promise<string>;
          GetReportManifest(): Promise<ReportMeta[]>;
          GetPendingCount(): Promise<number>;
          GetDocuments(): Promise<DocumentInfo[]>;
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
        };
      };
    };
    runtime: {
      EventsOn(event: string, callback: (...args: any[]) => void): () => void;
      EventsOff(event: string): void;
    };
  }
}
