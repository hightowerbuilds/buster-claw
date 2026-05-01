import { createSignal } from "solid-js";
import { createMutation, useQueryClient } from "@tanstack/solid-query";
import { dateKey } from "../../lib/dates";
import type { CalendarEvent, JobState } from "../../wails.d";
import type { CalendarForm, JobForm } from "./types";

export function useCalendarController() {
  const qc = useQueryClient();
  const [jobId, setJobId] = createSignal("");
  const [jobType, setJobType] = createSignal("ingest");
  const [jobCron, setJobCron] = createSignal("0 7 * * *");
  const [jobCustomCmd, setJobCustomCmd] = createSignal("");
  const [jobDeliverTo, setJobDeliverTo] = createSignal("");
  const [calendarDate, setCalendarDate] = createSignal(dateKey(new Date()));
  const [calendarTitle, setCalendarTitle] = createSignal("");
  const [calendarNotes, setCalendarNotes] = createSignal("");
  const [editingCalendarEvent, setEditingCalendarEvent] = createSignal<CalendarEvent | null>(null);

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
  const addCalendarEventMut = createMutation(() => ({
    mutationFn: (args: { date: string; title: string; notes: string }) =>
      window.go.main.App.AddCalendarEvent(args.date, args.title, args.notes),
    onSuccess: () => qc.invalidateQueries({ queryKey: ["calendar-events"] }),
  }));
  const updateCalendarEventMut = createMutation(() => ({
    mutationFn: (args: { id: string; date: string; title: string; notes: string }) =>
      window.go.main.App.UpdateCalendarEvent(args.id, args.date, args.title, args.notes),
    onSuccess: () => qc.invalidateQueries({ queryKey: ["calendar-events"] }),
  }));
  const deleteCalendarEventMut = createMutation(() => ({
    mutationFn: (id: string) => window.go.main.App.DeleteCalendarEvent(id),
    onSuccess: () => qc.invalidateQueries({ queryKey: ["calendar-events"] }),
  }));

  const resetCalendarForm = () => {
    setCalendarTitle("");
    setCalendarNotes("");
    setEditingCalendarEvent(null);
  };

  const selectCalendarDate = (date: string) => {
    setCalendarDate(date);
    resetCalendarForm();
  };

  const editCalendarEvent = (event: CalendarEvent) => {
    setEditingCalendarEvent(event);
    setCalendarDate(event.date);
    setCalendarTitle(event.title);
    setCalendarNotes(event.notes || "");
  };

  const saveCalendarEvent = () => {
    const title = calendarTitle().trim();
    if (!calendarDate() || !title) return;

    const existing = editingCalendarEvent();
    if (existing) {
      updateCalendarEventMut.mutate({ id: existing.id, date: calendarDate(), title, notes: calendarNotes().trim() });
    } else {
      addCalendarEventMut.mutate({ date: calendarDate(), title, notes: calendarNotes().trim() });
    }
    resetCalendarForm();
  };

  return {
    get calendarForm(): CalendarForm {
      return { date: calendarDate(), title: calendarTitle(), notes: calendarNotes(), editingId: editingCalendarEvent()?.id || "" };
    },
    get jobForm(): JobForm {
      return { id: jobId(), type: jobType(), cron: jobCron(), customCmd: jobCustomCmd(), deliverTo: jobDeliverTo() };
    },
    updateCalendarForm: (field: "date" | "title" | "notes", value: string) => {
      if (field === "date") setCalendarDate(value);
      if (field === "title") setCalendarTitle(value);
      if (field === "notes") setCalendarNotes(value);
    },
    selectCalendarDate,
    editCalendarEvent,
    saveCalendarEvent,
    deleteCalendarEvent: (id: string) => deleteCalendarEventMut.mutate(id),
    updateJobForm: (field: keyof JobForm, value: string) => {
      if (field === "id") setJobId(value);
      if (field === "type") setJobType(value);
      if (field === "cron") setJobCron(value);
      if (field === "customCmd") setJobCustomCmd(value);
      if (field === "deliverTo") setJobDeliverTo(value);
    },
    addJob: (job: JobForm) => {
      addJobMut.mutate({ ...job, enabled: true });
      setJobId("");
      setJobCustomCmd("");
    },
    toggleJob: (job: JobState) => {
      updateJobMut.mutate({
        id: job.id,
        type: job.type,
        cron: job.cron,
        enabled: !job.enabled,
        customCmd: job.customCmd || "",
        deliverTo: job.deliverTo || "",
      });
    },
    runJobNow: (id: string) => runJobNowMut.mutate(id),
    deleteJob: (id: string) => deleteJobMut.mutate(id),
  };
}
