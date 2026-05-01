import { createMemo, createSignal } from "solid-js";
import { dateKey, startOfDay } from "../../lib/dates";
import type { CalendarEvent, JobState } from "../../wails.d";
import { CalendarControls } from "./CalendarControls";
import { CalendarInspector } from "./CalendarInspector";
import { CalendarMonthGrid } from "./CalendarMonthGrid";
import { CalendarSchedulerPanel } from "./CalendarSchedulerPanel";
import { buildMonthDays, startOfMonth } from "./calendarUtils";
import { useCalendarController } from "./useCalendarController";
import "./CalendarView.css";

type CalendarViewProps = {
  visible: boolean;
  events: CalendarEvent[];
  jobs: JobState[];
};

export function CalendarView(props: CalendarViewProps) {
  const calendar = useCalendarController();
  const [visibleMonth, setVisibleMonth] = createSignal(startOfMonth(new Date()));
  const [shadeActive, setShadeActive] = createSignal(false);

  const monthDays = createMemo(() => buildMonthDays(visibleMonth()));

  const eventsByDate = createMemo(() => {
    const grouped = new Map<string, CalendarEvent[]>();
    for (const event of props.events) {
      const list = grouped.get(event.date) || [];
      list.push(event);
      grouped.set(event.date, list);
    }
    return grouped;
  });

  const jobsByDate = createMemo(() => {
    const grouped = new Map<string, JobState[]>();
    for (const job of props.jobs) {
      if (!job.enabled || !job.nextRun) continue;
      const nextRun = new Date(job.nextRun);
      if (Number.isNaN(nextRun.getTime())) continue;
      const key = dateKey(nextRun);
      const list = grouped.get(key) || [];
      list.push(job);
      grouped.set(key, list);
    }
    return grouped;
  });

  const selectedEvents = () => eventsByDate().get(calendar.calendarForm.date) || [];
  const selectedJobs = () => jobsByDate().get(calendar.calendarForm.date) || [];
  const todayKey = dateKey(new Date());

  const moveMonth = (delta: number) => {
    const next = new Date(visibleMonth());
    next.setMonth(next.getMonth() + delta);
    setVisibleMonth(startOfMonth(next));
  };

  const showToday = () => {
    const today = startOfDay(new Date());
    setVisibleMonth(startOfMonth(today));
    calendar.selectCalendarDate(dateKey(today));
  };

  return (
    <div class="view-panel calendar-view" classList={{ hidden: !props.visible }}>
      <div class="calendar-page">
        <div class="view-header calendar-header">
          <div>
            <h2>Calendar</h2>
            <p>Plan the month and keep this week visible on Home.</p>
          </div>
          <CalendarControls
            shadeActive={shadeActive()}
            onPrevious={() => moveMonth(-1)}
            onToday={showToday}
            onNext={() => moveMonth(1)}
            onToggleShade={() => setShadeActive((active) => !active)}
          />
        </div>

        <div class="calendar-layout">
          <CalendarMonthGrid
            visibleMonth={visibleMonth()}
            monthDays={monthDays()}
            eventsByDate={eventsByDate()}
            jobsByDate={jobsByDate()}
            todayKey={todayKey}
            selectedDate={calendar.calendarForm.date}
            shadeActive={shadeActive()}
            onSelectDate={calendar.selectCalendarDate}
          />

          <CalendarInspector
            form={calendar.calendarForm}
            selectedEvents={selectedEvents()}
            selectedJobs={selectedJobs()}
            onFormChange={calendar.updateCalendarForm}
            onSave={calendar.saveCalendarEvent}
            onEdit={calendar.editCalendarEvent}
            onDelete={calendar.deleteCalendarEvent}
          />
        </div>

        <CalendarSchedulerPanel
          jobs={props.jobs}
          jobForm={calendar.jobForm}
          onJobFormChange={calendar.updateJobForm}
          onAddJob={calendar.addJob}
          onToggleJob={calendar.toggleJob}
          onRunJobNow={calendar.runJobNow}
          onDeleteJob={calendar.deleteJob}
        />
      </div>
    </div>
  );
}
