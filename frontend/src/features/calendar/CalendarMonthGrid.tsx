import { For } from "solid-js";
import type { CalendarEvent, JobState } from "../../wails.d";
import { CalendarDayCell } from "./CalendarDayCell";
import type { CalendarEventMap, CalendarJobMap, MonthDay } from "./types";

type CalendarMonthGridProps = {
  visibleMonth: Date;
  monthDays: MonthDay[];
  eventsByDate: CalendarEventMap;
  jobsByDate: CalendarJobMap;
  todayKey: string;
  selectedDate: string;
  shadeActive: boolean;
  onSelectDate: (date: string) => void;
};

export function CalendarMonthGrid(props: CalendarMonthGridProps) {
  const eventsFor = (key: string): CalendarEvent[] => props.eventsByDate.get(key) || [];
  const jobsFor = (key: string): JobState[] => props.jobsByDate.get(key) || [];

  return (
    <section class="month-calendar" classList={{ shaded: props.shadeActive }}>
      <div class="month-calendar-title">
        {props.visibleMonth.toLocaleDateString(undefined, { month: "long", year: "numeric" })}
      </div>
      <div class="month-calendar-weekdays">
        <For each={["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]}>
          {(day) => <div>{day}</div>}
        </For>
      </div>
      <div class="month-calendar-grid">
        <For each={props.monthDays}>
          {(day) => (
            <CalendarDayCell
              day={day}
              events={eventsFor(day.key)}
              jobs={jobsFor(day.key)}
              todayKey={props.todayKey}
              selectedDate={props.selectedDate}
              onSelect={props.onSelectDate}
            />
          )}
        </For>
      </div>
    </section>
  );
}
