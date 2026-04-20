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
          StartAnalysis(): Promise<AnalysisResult>;
          StartFullPipeline(): Promise<FullPipelineResult>;
          GetOrchestratorStatus(): Promise<OrchestratorStatus>;
          GetSources(): Promise<Source[]>;
          GetIntentions(): Promise<string>;
          GetReportManifest(): Promise<ReportMeta[]>;
          GetPendingCount(): Promise<number>;
        };
      };
    };
    runtime: {
      EventsOn(event: string, callback: (...args: any[]) => void): () => void;
      EventsOff(event: string): void;
    };
  }
}
