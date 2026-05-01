import type { CalendarEvent, JobState } from "../../wails.d";

export type CalendarForm = {
  date: string;
  title: string;
  notes: string;
  editingId: string;
};

export type JobForm = {
  id: string;
  type: string;
  cron: string;
  customCmd: string;
  deliverTo: string;
};

export type MonthDay = {
  date: Date;
  key: string;
  inMonth: boolean;
};

export type CalendarEventMap = Map<string, CalendarEvent[]>;

export type CalendarJobMap = Map<string, JobState[]>;
