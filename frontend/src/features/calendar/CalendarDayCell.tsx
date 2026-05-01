import { For, Show } from "solid-js";
import type { CalendarEvent, JobState } from "../../wails.d";
import type { MonthDay } from "./types";
import { jobLabel } from "./calendarUtils";

type CalendarDayCellProps = {
  day: MonthDay;
  events: CalendarEvent[];
  jobs: JobState[];
  todayKey: string;
  selectedDate: string;
  onSelect: (date: string) => void;
};

export function CalendarDayCell(props: CalendarDayCellProps) {
  const visibleEvents = () => props.events.slice(0, 2);
  const visibleJobs = () => props.jobs.slice(0, Math.max(0, 3 - visibleEvents().length));
  const hiddenCount = () => Math.max(0, props.events.length + props.jobs.length - visibleEvents().length - visibleJobs().length);
  const hasItems = () => props.events.length > 0 || props.jobs.length > 0;

  return (
    <button
      type="button"
      class="month-day"
      classList={{
        muted: !props.day.inMonth,
        today: props.day.key === props.todayKey,
        selected: props.selectedDate === props.day.key,
        "has-items": hasItems(),
      }}
      onClick={() => props.onSelect(props.day.key)}
    >
      <span class="month-day-number">{props.day.date.getDate()}</span>
      <div class="month-day-events">
        <For each={visibleEvents()}>
          {(event) => <span class="month-event-pill">{event.title}</span>}
        </For>
        <For each={visibleJobs()}>
          {(job) => <span class="month-event-pill scheduled">{jobLabel(job)}</span>}
        </For>
        <Show when={hiddenCount() > 0}>
          <span class="month-event-more">+{hiddenCount()} more</span>
        </Show>
      </div>
    </button>
  );
}
