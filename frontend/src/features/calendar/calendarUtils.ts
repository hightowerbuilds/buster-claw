import { dateKey } from "../../lib/dates";
import type { JobState } from "../../wails.d";
import type { MonthDay } from "./types";

export function startOfMonth(date: Date) {
  const next = new Date(date);
  next.setDate(1);
  next.setHours(0, 0, 0, 0);
  return next;
}

export function buildMonthDays(visibleMonth: Date): MonthDay[] {
  const start = new Date(visibleMonth);
  start.setDate(visibleMonth.getDate() - visibleMonth.getDay());

  return Array.from({ length: 42 }, (_, index) => {
    const date = new Date(start);
    date.setDate(start.getDate() + index);
    return {
      date,
      key: dateKey(date),
      inMonth: date.getMonth() === visibleMonth.getMonth(),
    };
  });
}

export function formatSelectedDate(value: string) {
  const [year, month, day] = value.split("-").map(Number);
  if (!year || !month || !day) return "Selected Date";
  return new Date(year, month - 1, day).toLocaleDateString(undefined, {
    weekday: "long",
    month: "long",
    day: "numeric",
  });
}

export function jobLabel(job: JobState) {
  if (job.customCmd) return job.customCmd;
  if (job.type === "full") return "Full research pipeline";
  if (job.type === "ingest") return "Ingest sources";
  if (job.type === "analyze") return "Analyze queue";
  if (job.type === "digest") return "Digest delivery";
  return job.id;
}
