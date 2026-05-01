export type View =
  | "home"
  | "chat"
  | "ingestion"
  | "documents"
  | "analysis"
  | "calendar"
  | "intelligence"
  | "webhooks"
  | "advanced";

export const navigationItems: Array<{ view: View; label: string }> = [
  { view: "home", label: "Home" },
  { view: "chat", label: "Chat" },
  { view: "ingestion", label: "Sources" },
  { view: "documents", label: "Documents" },
  { view: "analysis", label: "Analysis" },
  { view: "calendar", label: "Calendar" },
  { view: "intelligence", label: "Intelligence" },
  { view: "webhooks", label: "Webhooks / Hooks" },
  { view: "advanced", label: "Advanced" },
];
