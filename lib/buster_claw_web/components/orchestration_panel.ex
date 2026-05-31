defmodule BusterClawWeb.OrchestrationPanel do
  @moduledoc """
  Home left-column panel: the live window into the unattended orchestration
  shift. Shows shift status + controls (start / emergency stop), what's running,
  what's up next, and recent agent runs. Driven by `Orchestration.snapshot/0`;
  the parent LiveView re-snapshots on the `"orchestration"` PubSub topic.
  """
  use BusterClawWeb, :html

  attr :snapshot, :map, required: true

  def panel(assigns) do
    ~H"""
    <section id="home-left-panel" class="ic-panel flex min-h-64 flex-col">
      <header class="flex items-center justify-between gap-2 border-b-2 border-base-content/20 px-5 py-4">
        <div>
          <p class="ic-eyebrow flex items-center gap-2">
            <span class={["ic-dot", not shift_on?(@snapshot) && "opacity-30"]}></span> Orchestration
          </p>
          <h2 class="font-display text-2xl font-black uppercase tracking-tight">Shift</h2>
        </div>

        <div class="flex shrink-0 items-center gap-2">
          <.link
            navigate="/orchestration"
            class="rounded-sm border-2 border-base-content/25 px-3 py-2 font-mono text-xs uppercase tracking-wide text-base-content/70 transition hover:border-primary hover:text-primary"
          >
            Manage
          </.link>
          <button
            :if={not shift_on?(@snapshot)}
            type="button"
            phx-click="start_shift"
            class="rounded bg-primary px-3 py-2 text-sm font-semibold text-primary-content transition hover:opacity-85"
          >
            Start shift
          </button>
          <button
            :if={shift_on?(@snapshot)}
            type="button"
            phx-click="kill_shift"
            class="rounded border-2 border-error/60 bg-error/10 px-3 py-2 text-sm font-semibold text-error transition hover:bg-error/20"
          >
            Emergency stop
          </button>
        </div>
      </header>

      <div class="flex-1 space-y-5 overflow-auto p-5">
        <div
          :if={not shift_on?(@snapshot)}
          class="rounded border border-dashed border-base-300 px-4 py-8 text-center text-sm text-base-content/60"
        >
          No active shift. Start a 12-hour shift to begin dispatching scheduled work.
        </div>

        <div :if={shift_on?(@snapshot)} class="space-y-3">
          <div class="flex flex-wrap items-center justify-between gap-2">
            <span class="rounded-full bg-success/15 px-3 py-1 text-xs font-semibold text-success">
              Active · {time_left(@snapshot.shift)}
            </span>
            <span class="font-mono text-xs text-base-content/55">
              {@snapshot.shift.dispatched_count} dispatched · {@snapshot.shift.done_count} done · {@snapshot.shift.failed_count} failed
            </span>
          </div>

          <% v = vitals(@snapshot) %>
          <div class="flex flex-wrap items-center gap-x-4 gap-y-1 font-mono text-[0.7rem] uppercase tracking-wide text-base-content/45">
            <span>concurrency {v.running}/{v.max_concurrent}</span>
            <span>runs this hour {v.runs_last_hour}/{v.max_runs_per_hour}</span>
            <span>{v.done_today} done · {v.failed_today} failed</span>
          </div>
        </div>

        <.list_block title="Now running" items={@snapshot.running} empty="Nothing running.">
          <:row :let={task}>
            <span class="size-2 shrink-0 rounded-full bg-warning motion-safe:animate-pulse"></span>
            <span class="min-w-0 flex-1 truncate font-medium">{task.name}</span>
            <span class="font-mono text-xs text-base-content/50">{task.type}</span>
          </:row>
        </.list_block>

        <.list_block title="Up next" items={@snapshot.upcoming} empty="Queue is empty.">
          <:row :let={task}>
            <span class="size-2 shrink-0 rounded-full bg-base-content/30"></span>
            <span class="min-w-0 flex-1 truncate">{task.name}</span>
            <span class="font-mono text-xs text-base-content/50">{due_label(task)}</span>
          </:row>
        </.list_block>

        <.list_block title="Recent runs" items={@snapshot.recent} empty="No runs yet.">
          <:row :let={run}>
            <span class={["size-2 shrink-0 rounded-full", run_dot(run.status)]}></span>
            <span class="min-w-0 flex-1 truncate font-mono text-xs">
              {run.engine} · run ##{run.id}
            </span>
            <span class="font-mono text-xs text-base-content/50">{run.status}</span>
          </:row>
        </.list_block>
      </div>
    </section>
    """
  end

  attr :title, :string, required: true
  attr :items, :list, required: true
  attr :empty, :string, required: true
  slot :row, required: true

  defp list_block(assigns) do
    ~H"""
    <div class="space-y-2">
      <p class="ic-eyebrow">{@title}</p>
      <ul :if={@items != []} class="divide-y divide-base-300 rounded border border-base-300">
        <li :for={item <- @items} class="flex items-center gap-2 px-3 py-2 text-sm">
          {render_slot(@row, item)}
        </li>
      </ul>
      <p :if={@items == []} class="px-1 text-xs text-base-content/45">{@empty}</p>
    </div>
    """
  end

  defp shift_on?(%{shift: shift}), do: shift != nil

  @empty_vitals %{
    running: 0,
    max_concurrent: 0,
    runs_last_hour: 0,
    max_runs_per_hour: 0,
    done_today: 0,
    failed_today: 0
  }

  defp vitals(%{vitals: %{} = v}), do: Map.merge(@empty_vitals, v)
  defp vitals(_), do: @empty_vitals

  defp time_left(%{ends_at: ends_at}) do
    secs = DateTime.diff(ends_at, DateTime.utc_now())

    cond do
      secs <= 0 -> "ending"
      secs < 3600 -> "#{div(secs, 60)}m left"
      true -> "#{div(secs, 3600)}h #{rem(div(secs, 60), 60)}m left"
    end
  end

  defp due_label(%{next_run_at: %DateTime{} = dt}), do: Calendar.strftime(dt, "%H:%M")
  defp due_label(%{due_at: %DateTime{} = dt}), do: Calendar.strftime(dt, "%H:%M")
  defp due_label(_), do: "—"

  defp run_dot("done"), do: "bg-success"
  defp run_dot("running"), do: "bg-warning"
  defp run_dot(status) when status in ["failed", "timeout", "killed"], do: "bg-error"
  defp run_dot(_), do: "bg-base-content/40"
end
