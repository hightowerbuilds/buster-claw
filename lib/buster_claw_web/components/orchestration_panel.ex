defmodule BusterClawWeb.OrchestrationPanel do
  @moduledoc """
  Home left-column panel: the live window into the unattended orchestration
  shift. Shifts are started by the agent from the terminal (`shift_start`); this
  panel shows shift status + emergency stop, what's running, what's up next, and
  recent agent runs. Driven by `Orchestration.snapshot/0`;
  the parent LiveView re-snapshots on the `"orchestration"` PubSub topic.
  """
  use BusterClawWeb, :html

  attr :snapshot, :map, required: true
  attr :manage_link, :boolean, default: true

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
            :if={@manage_link}
            navigate="/orchestration"
            class="rounded-sm border-2 border-base-content/25 px-3 py-2 font-mono text-xs uppercase tracking-wide text-base-content/70 transition hover:border-primary hover:text-primary"
          >
            Manage
          </.link>
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
        <.shift_management snapshot={@snapshot} />

        <div :if={shift_on?(@snapshot)} class="space-y-3">
          <div class="flex flex-wrap items-center justify-between gap-2">
            <span class="rounded-full bg-success/15 px-3 py-1 text-xs font-semibold text-success">
              Active · {elapsed(@snapshot.shift)} on shift
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
            <button
              type="button"
              phx-click="delete_task"
              phx-value-id={task.id}
              aria-label={"Delete #{task.name}"}
              title="Delete task"
              class="grid size-5 shrink-0 place-items-center rounded text-base-content/40 hover:bg-base-300 hover:text-error"
            >
              &times;
            </button>
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

  attr :snapshot, :map, required: true

  defp shift_management(assigns) do
    ~H"""
    <section
      id="home-shift-management"
      class={[
        "space-y-4 rounded border-2 p-4 transition",
        if(shift_on?(@snapshot),
          do: "border-success/45 bg-success/10",
          else: "border-base-content/15 bg-base-200/35"
        )
      ]}
    >
      <div id="home-shift-assignment" class="space-y-3">
        <%= if shift_on?(@snapshot) do %>
          <div class="flex flex-wrap items-start justify-between gap-3">
            <div class="min-w-0">
              <p class="ic-eyebrow">On Shift</p>
              <h3 class="font-display text-2xl font-black uppercase tracking-tight">
                {shift_job_name(@snapshot.shift)}
              </h3>
              <p class="mt-1 text-sm text-base-content/65">
                {shift_description(@snapshot.shift)}
              </p>
            </div>
            <div
              id="shift-shell-open-status"
              class="rounded border-2 border-success/40 bg-success/15 px-3 py-2 text-right"
            >
              <p class="font-mono text-[0.7rem] uppercase tracking-wide text-success">
                Shell open
              </p>
              <p class="font-display text-lg font-black uppercase">{elapsed(@snapshot.shift)}</p>
            </div>
          </div>

          <dl class="grid gap-2 text-sm sm:grid-cols-3">
            <div class="rounded border border-base-300 bg-base-100/60 p-3">
              <dt class="font-mono text-[0.68rem] uppercase tracking-wide text-base-content/45">
                Agent
              </dt>
              <dd class="mt-1 truncate font-semibold">{shift_agent(@snapshot.shift)}</dd>
            </div>
            <div class="rounded border border-base-300 bg-base-100/60 p-3">
              <dt class="font-mono text-[0.68rem] uppercase tracking-wide text-base-content/45">
                Shell
              </dt>
              <dd class="mt-1 truncate font-semibold">{shift_shell(@snapshot.shift)}</dd>
            </div>
            <div class="rounded border border-base-300 bg-base-100/60 p-3">
              <dt class="font-mono text-[0.68rem] uppercase tracking-wide text-base-content/45">
                On Shift Since
              </dt>
              <dd class="mt-1 font-semibold">
                {short_time(@snapshot.shift.started_at)}
              </dd>
            </div>
          </dl>

          <section id="shift-active-assignments" class="space-y-2 border-t border-success/25 pt-3">
            <div class="flex items-center justify-between gap-2">
              <p class="ic-eyebrow">Specialist Shells</p>
              <span class="font-mono text-[0.68rem] uppercase tracking-wide text-base-content/45">
                {length(assignments(@snapshot))} active
              </span>
            </div>

            <div
              :if={assignments(@snapshot) == []}
              class="rounded border border-dashed border-success/25 px-3 py-4 text-sm text-base-content/55"
            >
              No specialist shells are open under this shift.
            </div>

            <div :if={assignments(@snapshot) != []} class="grid gap-2">
              <article
                :for={assignment <- assignments(@snapshot)}
                id={"shift-assignment-#{assignment.id}"}
                class="rounded border border-success/30 bg-base-100/70 p-3"
              >
                <div class="flex flex-wrap items-start justify-between gap-3">
                  <div class="min-w-0">
                    <div class="flex min-w-0 items-center gap-2">
                      <span class="size-2 shrink-0 rounded-full bg-success motion-safe:animate-pulse">
                      </span>
                      <h4 class="truncate font-display text-sm font-black uppercase tracking-tight">
                        {assignment_role_name(assignment)}
                      </h4>
                    </div>
                    <p
                      :if={assignment.purpose not in [nil, ""]}
                      class="mt-1 line-clamp-2 text-xs leading-5 text-base-content/60"
                    >
                      {assignment.purpose}
                    </p>
                  </div>
                  <span class="rounded bg-success/15 px-2 py-1 font-mono text-[0.65rem] uppercase tracking-wide text-success">
                    {assignment.status}
                  </span>
                </div>

                <dl class="mt-3 grid gap-2 text-xs sm:grid-cols-3">
                  <div>
                    <dt class="font-mono uppercase tracking-wide text-base-content/40">Agent</dt>
                    <dd class="mt-0.5 truncate font-semibold">{assignment_agent(assignment)}</dd>
                  </div>
                  <div>
                    <dt class="font-mono uppercase tracking-wide text-base-content/40">Shell</dt>
                    <dd class="mt-0.5 truncate font-semibold">{assignment_shell(assignment)}</dd>
                  </div>
                  <div>
                    <dt class="font-mono uppercase tracking-wide text-base-content/40">Started</dt>
                    <dd class="mt-0.5 font-semibold">{short_time(assignment.started_at)}</dd>
                  </div>
                </dl>
              </article>
            </div>
          </section>
        <% else %>
          <div class="rounded border border-dashed border-base-300 px-4 py-6 text-center text-sm text-base-content/60">
            <p class="font-semibold text-base-content/80">No shift shell open.</p>
            <p class="mt-1">
              The terminal agent starts shifts with <code class="font-mono">buster-claw run shift_start</code>;
              this display turns live when a shell takes a job.
            </p>
          </div>
        <% end %>
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

  defp assignments(%{assignments: assignments}) when is_list(assignments), do: assignments
  defp assignments(_snapshot), do: []

  defp shift_job_name(%{job_name: name}) when is_binary(name) and name != "", do: name
  defp shift_job_name(_shift), do: "Lookout"

  defp shift_description(%{job_description: description})
       when is_binary(description) and description != "",
       do: description

  defp shift_description(_shift), do: "Active operator shift."

  defp shift_agent(%{agent_name: agent}) when is_binary(agent) and agent != "", do: agent
  defp shift_agent(_shift), do: "Unassigned"

  defp shift_shell(%{shell: shell}) when is_binary(shell) and shell != "", do: shell
  defp shift_shell(_shift), do: "Shell not set"

  defp short_time(%DateTime{} = dt), do: Calendar.strftime(dt, "%H:%M")
  defp short_time(_dt), do: "unknown"

  defp assignment_role_name(%{role_key: role_key}) when is_binary(role_key) do
    role_key
    |> String.split("-", trim: true)
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  defp assignment_role_name(_assignment), do: "Specialist"

  defp assignment_agent(%{agent_name: agent_name})
       when is_binary(agent_name) and agent_name != "",
       do: agent_name

  defp assignment_agent(_assignment), do: "Unassigned"

  defp assignment_shell(%{shell: shell}) when is_binary(shell) and shell != "", do: shell
  defp assignment_shell(_assignment), do: "Shell not set"

  defp elapsed(%{started_at: %DateTime{} = started_at}) do
    secs = max(DateTime.diff(DateTime.utc_now(), started_at), 0)

    cond do
      secs < 60 -> "just now"
      secs < 3600 -> "#{div(secs, 60)}m"
      true -> "#{div(secs, 3600)}h #{rem(div(secs, 60), 60)}m"
    end
  end

  defp elapsed(_shift), do: "—"

  defp due_label(%{next_run_at: %DateTime{} = dt}), do: Calendar.strftime(dt, "%H:%M")
  defp due_label(%{due_at: %DateTime{} = dt}), do: Calendar.strftime(dt, "%H:%M")
  defp due_label(_), do: "—"

  defp run_dot("done"), do: "bg-success"
  defp run_dot("running"), do: "bg-warning"
  defp run_dot(status) when status in ["failed", "timeout", "killed"], do: "bg-error"
  defp run_dot(_), do: "bg-base-content/40"
end
