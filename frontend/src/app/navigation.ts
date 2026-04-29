export type View =
  | "home"
  | "chat"
  | "ingestion"
  | "documents"
  | "orchestration"
  | "analysis"
  | "models"
  | "providers"
  | "memory"
  | "scheduler"
  | "webhooks"
  | "delivery"
  | "hooks"
  | "docs";

export const navigationItems: Array<{ view: View; label: string }> = [
  { view: "home", label: "Home" },
  { view: "chat", label: "Chat" },
  { view: "ingestion", label: "Ingestion" },
  { view: "documents", label: "Documents" },
  { view: "orchestration", label: "Orchestration" },
  { view: "analysis", label: "Analysis" },
  { view: "scheduler", label: "Scheduler" },
  { view: "webhooks", label: "Webhooks" },
  { view: "delivery", label: "Delivery" },
  { view: "hooks", label: "Hooks" },
  { view: "models", label: "Models" },
  { view: "providers", label: "Providers" },
  { view: "memory", label: "Memory" },
  { view: "docs", label: "Docs" },
];
