import { For, Show } from "solid-js";
import { dateKey, startOfDay } from "../../lib/dates";
import type { JobState } from "../../wails.d";

type WeeklyPlanCalendarProps = {
  jobs: JobState[];
};

export function WeeklyPlanCalendar(props: WeeklyPlanCalendarProps) {
  const days = () => {
    const today = startOfDay(new Date());
    return Array.from({ length: 7 }, (_, index) => {
      const date = new Date(today);
      date.setDate(today.getDate() + index);
      return date;
    });
  };

  const jobsForDay = (day: Date) => {
    const key = dateKey(day);
    return props.jobs.filter((job) => {
      if (!job.enabled || !job.nextRun) return false;
      const nextRun = new Date(job.nextRun);
      if (Number.isNaN(nextRun.getTime())) return false;
      return dateKey(nextRun) === key;
    });
  };

  const jobLabel = (job: JobState) => {
    if (job.customCmd) return job.customCmd;
    if (job.type === "full") return "Full research pipeline";
    if (job.type === "ingest") return "Ingest sources";
    if (job.type === "analyze") return "Analyze queue";
    if (job.type === "digest") return "Digest delivery";
    return job.id;
  };

  return (
    <section class="weekly-plan">
      <h2 class="section-title">This Week</h2>
      <div class="weekly-plan-grid">
        <For each={days()}>
          {(day, index) => {
            const dayJobs = () => jobsForDay(day);
            return (
              <div class="week-day" classList={{ today: index() === 0 }}>
                <div class="week-day-heading">
                  <span>{index() === 0 ? "Today" : day.toLocaleDateString(undefined, { weekday: "short" })}</span>
                  <strong>{day.toLocaleDateString(undefined, { month: "short", day: "numeric" })}</strong>
                </div>
                <div class="week-day-plans">
                  <Show when={dayJobs().length > 0} fallback={<div class="week-empty">No scheduled work</div>}>
                    <For each={dayJobs()}>
                      {(job) => (
                        <div class="week-plan-item">
                          <span class="week-plan-type">{job.type}</span>
                          <span class="week-plan-title">{jobLabel(job)}</span>
                          <span class="week-plan-time">{new Date(job.nextRun).toLocaleTimeString(undefined, { hour: "numeric", minute: "2-digit" })}</span>
                        </div>
                      )}
                    </For>
                  </Show>
                </div>
              </div>
            );
          }}
        </For>
      </div>
    </section>
  );
}
