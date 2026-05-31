defmodule BusterClawWeb.OrchestrationLive do
  @moduledoc """
  Manage the orchestration schedule: create `orchestrator_tasks`, toggle/delete
  them, and "Run now". The home `OrchestrationPanel` watches them execute; this
  is where the schedule is authored.
  """
  use BusterClawWeb, :live_view

  alias BusterClaw.Orchestration
  alias BusterClaw.Orchestration.Task

  @blank_to_nil ~w(engine cron command prompt)

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Orchestration.subscribe()

    {:ok,
     socket
     |> assign(:page_title, "Orchestration")
     |> assign(:task_type, "pipeline")
     |> load()
     |> assign_form()}
  end

  @impl true
  def handle_info({:orchestration, _event}, socket), do: {:noreply, load(socket)}

  @impl true
  def handle_event("validate", %{"task" => params}, socket) do
    changeset = %Task{} |> Orchestration.change_task(params) |> Map.put(:action, :validate)

    {:noreply,
     socket
     |> assign(:task_type, params["type"] || "pipeline")
     |> assign(:form, to_form(changeset, as: :task))}
  end

  def handle_event("save", %{"task" => params}, socket) do
    case params |> normalize() |> Orchestration.create_task() do
      {:ok, _task} ->
        {:noreply, socket |> put_flash(:info, "Task added.") |> assign(:task_type, "pipeline") |> load() |> assign_form()}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset, as: :task))}
    end
  end

  def handle_event("run_now", %{"id" => id}, socket) do
    id
    |> Orchestration.get_task!()
    |> Orchestration.update_task(%{state: "pending", due_at: now(), next_run_at: nil})

    if Orchestration.shift_active?() and Process.whereis(BusterClaw.Orchestrator) do
      BusterClaw.Orchestrator.tick_now()
    end

    {:noreply, socket |> put_flash(:info, "Queued to run.") |> load()}
  end

  def handle_event("toggle", %{"id" => id}, socket) do
    task = Orchestration.get_task!(id)
    Orchestration.update_task(task, %{enabled: not task.enabled})
    {:noreply, load(socket)}
  end

  def handle_event("delete", %{"id" => id}, socket) do
    Orchestration.get_task!(id) |> Orchestration.delete_task()
    {:noreply, load(socket)}
  end

  defp load(socket) do
    socket
    |> assign(:tasks, Orchestration.list_tasks())
    |> assign(:shift_active?, Orchestration.shift_active?())
  end

  defp assign_form(socket) do
    changeset = Orchestration.change_task(%Task{}, %{"type" => "pipeline"})
    assign(socket, :form, to_form(changeset, as: :task))
  end

  # Blank strings from the form would fail engine/cron validation or create
  # never-due "" crons; treat them as unset.
  defp normalize(params) do
    Enum.reduce(@blank_to_nil, params, fn key, acc ->
      case Map.get(acc, key) do
        "" -> Map.put(acc, key, nil)
        _ -> acc
      end
    end)
    |> then(fn p ->
      if p["run_now"] == "true", do: Map.put(p, "due_at", now()), else: p
    end)
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <section class="space-y-6">
        <div class="flex flex-wrap items-end justify-between gap-3 border-b-2 border-base-content/20 pb-4">
          <div>
            <p class="ic-eyebrow">Orchestration</p>
            <h1 class="font-display text-3xl font-black uppercase tracking-tight">Schedule</h1>
          </div>
          <span class={[
            "rounded-full px-3 py-1 text-xs font-semibold",
            if(@shift_active?, do: "bg-success/15 text-success", else: "bg-base-200 text-base-content/60")
          ]}>
            {if @shift_active?, do: "Shift active", else: "No active shift"}
          </span>
        </div>

        <div class="grid gap-6 lg:grid-cols-[380px_minmax(0,1fr)]">
          <.form
            for={@form}
            id="task-form"
            phx-change="validate"
            phx-submit="save"
            class="ic-panel space-y-4 p-5"
          >
            <h2 class="ic-eyebrow">New task</h2>

            <label class="block">
              <span class="ic-eyebrow">Name</span>
              <input type="text" name="task[name]" value={@form[:name].value} class="input mt-1 w-full" placeholder="Morning digest" />
            </label>

            <label class="block">
              <span class="ic-eyebrow">Type</span>
              <select name="task[type]" class="select mt-1 w-full">
                <option value="pipeline" selected={@task_type == "pipeline"}>Pipeline (Elixir worker)</option>
                <option value="agent" selected={@task_type == "agent"}>Agent (headless claude/codex)</option>
              </select>
            </label>

            <label :if={@task_type == "pipeline"} class="block">
              <span class="ic-eyebrow">Command</span>
              <input type="text" name="task[command]" value={@form[:command].value} class="input mt-1 w-full" placeholder="noop" />
              <span class="mt-1 block text-xs text-base-content/55">e.g. <code>noop</code>, <code>analyze_pending</code></span>
            </label>

            <label :if={@task_type == "agent"} class="block">
              <span class="ic-eyebrow">Engine</span>
              <select name="task[engine]" class="select mt-1 w-full">
                <option value="claude" selected={@form[:engine].value in [nil, "claude"]}>Claude</option>
                <option value="codex" selected={@form[:engine].value == "codex"}>Codex</option>
              </select>
            </label>

            <label :if={@task_type == "agent"} class="block">
              <span class="ic-eyebrow">Prompt</span>
              <textarea name="task[prompt]" rows="3" class="textarea mt-1 w-full" placeholder="What should the agent do?">{@form[:prompt].value}</textarea>
            </label>

            <label class="block">
              <span class="ic-eyebrow">Cron (optional)</span>
              <input type="text" name="task[cron]" value={@form[:cron].value} class="input mt-1 w-full font-mono" placeholder="*/15 * * * *  (blank = one-shot)" />
            </label>

            <label class="flex items-center gap-2 text-sm">
              <input type="hidden" name="task[run_now]" value="false" />
              <input type="checkbox" name="task[run_now]" value="true" class="checkbox checkbox-sm" /> Run immediately
            </label>

            <button type="submit" class="w-full rounded bg-primary px-4 py-2 text-sm font-semibold text-primary-content transition hover:opacity-85">
              Add task
            </button>
          </.form>

          <div class="ic-panel overflow-hidden">
            <div class="border-b-2 border-base-content/15 px-4 py-3">
              <p class="ic-eyebrow">Tasks ({length(@tasks)})</p>
            </div>

            <div :if={@tasks == []} class="px-4 py-10 text-center text-sm text-base-content/55">
              No tasks yet. Add one to populate the schedule.
            </div>

            <ul :if={@tasks != []} class="divide-y divide-base-300">
              <li :for={task <- @tasks} class="flex flex-wrap items-center gap-3 px-4 py-3 text-sm">
                <span class={["size-2 shrink-0 rounded-full", state_dot(task.state)]}></span>
                <div class="min-w-0 flex-1">
                  <p class="truncate font-semibold">{task.name}</p>
                  <p class="truncate font-mono text-xs text-base-content/55">
                    {task.type}{target_label(task)} · {schedule_label(task)} · {task.state}
                  </p>
                </div>
                <button type="button" phx-click="run_now" phx-value-id={task.id} class={action_btn()}>Run now</button>
                <button type="button" phx-click="toggle" phx-value-id={task.id} class={action_btn()}>
                  {if task.enabled, do: "Disable", else: "Enable"}
                </button>
                <button type="button" phx-click="delete" phx-value-id={task.id} data-confirm="Delete this task?" class={action_btn("text-error hover:border-error")}>
                  Delete
                </button>
              </li>
            </ul>
          </div>
        </div>
      </section>
    </Layouts.app>
    """
  end

  defp target_label(%{type: "agent", engine: engine}), do: " · #{engine || "claude"}"
  defp target_label(%{type: "pipeline", command: command}) when is_binary(command), do: " · #{command}"
  defp target_label(_), do: ""

  defp schedule_label(%{cron: cron}) when is_binary(cron) and cron != "", do: cron
  defp schedule_label(_), do: "one-shot"

  defp state_dot("done"), do: "bg-success"
  defp state_dot("running"), do: "bg-warning"
  defp state_dot("claimed"), do: "bg-warning"
  defp state_dot(state) when state in ["failed", "cancelled"], do: "bg-error"
  defp state_dot(_), do: "bg-base-content/40"

  defp action_btn(extra \\ "") do
    "rounded-sm border-2 border-base-content/25 px-2 py-1 font-mono text-xs uppercase tracking-wide transition hover:border-primary hover:text-primary #{extra}"
  end
end
