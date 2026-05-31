defmodule BusterClawWeb.OrchestrationLive do
  @moduledoc """
  Orchestration hub: the live shift dashboard (home `OrchestrationPanel`), a
  guided **new-task wizard**, and the task table (run-now / enable / delete).

  The wizard walks the user through Type → Brief → Schedule → Review. For agent
  tasks the answers are assembled into a structured markdown **brief** stored as
  the task's prompt — that brief is exactly what the on-shift model (Claude /
  Codex) reads and interprets when the Orchestrator dispatches the task.
  """
  use BusterClawWeb, :live_view

  alias BusterClaw.Orchestration

  @steps [:type, :brief, :schedule, :review]
  @step_bar [{:type, "Type"}, {:brief, "Brief"}, {:schedule, "Schedule"}, {:review, "Review"}]
  @blank_to_nil ~w(engine cron command prompt)
  @wizard_defaults %{
    "type" => nil,
    "engine" => "claude",
    "command" => "noop",
    "objective" => "",
    "context" => "",
    "deliverable" => "",
    "done" => "",
    "schedule" => "once",
    "cron" => "",
    "name" => ""
  }

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Orchestration.subscribe()
      :timer.send_interval(30_000, self(), :refresh)
    end

    {:ok,
     socket
     |> assign(:page_title, "Orchestration")
     |> reset_wizard()
     |> load()}
  end

  @impl true
  def handle_info({:orchestration, _event}, socket), do: {:noreply, load(socket)}
  def handle_info(:refresh, socket), do: {:noreply, load(socket)}

  # --- shift controls (mirror the home panel) ---

  @impl true
  def handle_event("start_shift", _params, socket) do
    Orchestration.clear_kill_switch()
    Orchestration.start_shift()
    {:noreply, load(socket)}
  end

  def handle_event("kill_shift", _params, socket) do
    Orchestration.engage_kill_switch()
    Orchestration.stop_shift("kill switch")
    {:noreply, load(socket)}
  end

  # --- new-task wizard ---

  def handle_event("wizard_type", %{"type" => type}, socket) do
    wizard = Map.put(socket.assigns.wizard, "type", type)
    {:noreply, socket |> assign(:wizard, wizard) |> assign(:wizard_step, :brief)}
  end

  def handle_event("wizard_change", params, socket) do
    {:noreply, assign(socket, :wizard, merge_wizard(socket.assigns.wizard, params))}
  end

  def handle_event("wizard_schedule", %{"mode" => mode}, socket) do
    {:noreply, assign(socket, :wizard, Map.put(socket.assigns.wizard, "schedule", mode))}
  end

  def handle_event("wizard_back", _params, socket) do
    {:noreply, assign(socket, :wizard_step, step_shift(socket.assigns.wizard_step, -1))}
  end

  def handle_event("wizard_next", _params, socket) do
    case validate_step(socket.assigns.wizard_step, socket.assigns.wizard) do
      :ok ->
        {:noreply, assign(socket, :wizard_step, step_shift(socket.assigns.wizard_step, +1))}

      {:error, message} ->
        {:noreply, put_flash(socket, :error, message)}
    end
  end

  def handle_event("wizard_restart", _params, socket), do: {:noreply, reset_wizard(socket)}

  def handle_event("wizard_create", _params, socket) do
    wizard = socket.assigns.wizard

    with :ok <- validate_step(:review, wizard),
         {:ok, _task} <- Orchestration.create_task(build_attrs(wizard)) do
      {:noreply, socket |> put_flash(:info, "Task added.") |> reset_wizard() |> load()}
    else
      {:error, message} when is_binary(message) ->
        {:noreply, put_flash(socket, :error, message)}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Couldn't create the task — check the fields.")}
    end
  end

  # --- task table ---

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

  def handle_event("delete", %{"id" => id}, socket), do: do_delete(id, socket)
  def handle_event("delete_task", %{"id" => id}, socket), do: do_delete(id, socket)

  defp do_delete(id, socket) do
    case Orchestration.get_task(id) do
      nil -> :ok
      task -> Orchestration.delete_task(task)
    end

    {:noreply, load(socket)}
  end

  # --- state ---

  defp load(socket) do
    socket
    |> assign(:tasks, Orchestration.list_tasks())
    |> assign(:snapshot, Orchestration.snapshot())
  end

  defp reset_wizard(socket) do
    socket |> assign(:wizard_step, :type) |> assign(:wizard, @wizard_defaults)
  end

  defp merge_wizard(wizard, params) do
    Enum.reduce(~w(engine command objective context deliverable done cron name), wizard, fn key,
                                                                                            acc ->
      case Map.fetch(params, key) do
        {:ok, value} -> Map.put(acc, key, value)
        :error -> acc
      end
    end)
  end

  defp step_shift(step, delta) do
    idx = Enum.find_index(@steps, &(&1 == step)) || 0
    Enum.at(@steps, max(0, min(length(@steps) - 1, idx + delta)))
  end

  defp validate_step(:brief, %{"type" => "pipeline"} = w) do
    if blank?(w["command"]), do: {:error, "Pick a command for the pipeline task."}, else: :ok
  end

  defp validate_step(:brief, %{"type" => "agent"} = w) do
    if blank?(w["objective"]),
      do: {:error, "Describe the objective the agent should accomplish."},
      else: :ok
  end

  defp validate_step(:schedule, %{"schedule" => "recurring"} = w) do
    if BusterClaw.Scheduler.Cron.valid?(w["cron"]),
      do: :ok,
      else: {:error, "Enter a valid cron expression (e.g. */15 * * * *)."}
  end

  defp validate_step(:review, w) do
    if blank?(w["name"]), do: {:error, "Give the task a name."}, else: :ok
  end

  defp validate_step(_step, _w), do: :ok

  defp build_attrs(w) do
    schedule =
      case w["schedule"] do
        "once" -> %{"due_at" => now()}
        "recurring" -> %{"cron" => w["cron"]}
        _ -> %{}
      end

    target =
      case w["type"] do
        "agent" -> %{"engine" => w["engine"], "prompt" => build_brief(w)}
        "pipeline" -> %{"command" => w["command"]}
        _ -> %{}
      end

    %{"name" => w["name"], "type" => w["type"]}
    |> Map.merge(target)
    |> Map.merge(schedule)
    |> normalize()
  end

  # Assemble the answers into the markdown brief the on-shift agent reads.
  defp build_brief(w) do
    [
      "# Task: #{w["name"]}",
      section("Objective", w["objective"]),
      section("Context", w["context"]),
      section("Deliverable", w["deliverable"]),
      section("Done when", w["done"])
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n\n")
  end

  defp section(_title, value) when value in [nil, ""], do: nil
  defp section(title, value), do: "## #{title}\n#{value}"

  defp normalize(attrs) do
    Enum.reduce(@blank_to_nil, attrs, fn key, acc ->
      if Map.get(acc, key) == "", do: Map.put(acc, key, nil), else: acc
    end)
  end

  defp blank?(value), do: value in [nil, ""]
  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)

  # --- render ---

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <section class="space-y-6">
        <div class="border-b-2 border-base-content/20 pb-4">
          <p class="ic-eyebrow">Orchestration</p>
          <h1 class="font-display text-3xl font-black uppercase tracking-tight">Schedule</h1>
        </div>

        <BusterClawWeb.OrchestrationPanel.panel snapshot={@snapshot} manage_link={false} />

        <div class="grid gap-6 lg:grid-cols-[420px_minmax(0,1fr)]">
          <.wizard wizard={@wizard} step={@wizard_step} />
          <.task_table tasks={@tasks} />
        </div>
      </section>
    </Layouts.app>
    """
  end

  attr :wizard, :map, required: true
  attr :step, :atom, required: true

  defp wizard(assigns) do
    assigns = assign(assigns, :bar, @step_bar)

    ~H"""
    <div class="ic-panel space-y-5 p-5">
      <div class="flex items-center justify-between gap-2">
        <h2 class="ic-eyebrow">New task</h2>
        <button
          :if={@step != :type}
          type="button"
          phx-click="wizard_restart"
          class="font-mono text-xs uppercase tracking-wide text-base-content/50 hover:text-primary"
        >
          Start over
        </button>
      </div>

      <ol class="flex flex-wrap gap-2 font-mono text-xs uppercase tracking-wide">
        <li
          :for={{key, label} <- @bar}
          class={[
            "rounded-sm border-2 px-3 py-1",
            if(key == @step,
              do: "border-primary bg-primary/15 text-primary",
              else: "border-base-content/20 text-base-content/55"
            )
          ]}
        >
          {label}
        </li>
      </ol>

      <%= case @step do %>
        <% :type -> %>
          <div class="space-y-3">
            <p class="text-sm text-base-content/70">What kind of task is this?</p>
            <button
              type="button"
              phx-click="wizard_type"
              phx-value-type="agent"
              class="block w-full rounded-lg border-2 border-base-content/20 p-4 text-left transition hover:border-primary"
            >
              <span class="block font-display text-sm font-black uppercase tracking-tight">
                Agent
              </span>
              <span class="block text-xs text-base-content/60">
                A headless Claude/Codex run. You'll write a brief the on-shift model reads and acts on.
              </span>
            </button>
            <button
              type="button"
              phx-click="wizard_type"
              phx-value-type="pipeline"
              class="block w-full rounded-lg border-2 border-base-content/20 p-4 text-left transition hover:border-primary"
            >
              <span class="block font-display text-sm font-black uppercase tracking-tight">
                Pipeline
              </span>
              <span class="block text-xs text-base-content/60">
                A deterministic Elixir job (no model) — e.g. analyze queued documents.
              </span>
            </button>
          </div>
        <% :brief -> %>
          <form phx-change="wizard_change" class="space-y-4">
            <%= if @wizard["type"] == "agent" do %>
              <label class="block">
                <span class="ic-eyebrow">Engine</span>
                <select name="engine" class="select mt-1 w-full">
                  <option value="claude" selected={@wizard["engine"] in [nil, "claude"]}>
                    Claude
                  </option>
                  <option value="codex" selected={@wizard["engine"] == "codex"}>Codex</option>
                </select>
              </label>
              <label class="block">
                <span class="ic-eyebrow">Objective <span class="text-error">*</span></span>
                <textarea
                  name="objective"
                  rows="2"
                  class="textarea mt-1 w-full"
                  placeholder="What should the agent accomplish?"
                >{@wizard["objective"]}</textarea>
              </label>
              <label class="block">
                <span class="ic-eyebrow">Context / inputs</span>
                <textarea
                  name="context"
                  rows="2"
                  class="textarea mt-1 w-full"
                  placeholder="Background, files, links the agent should use"
                >{@wizard["context"]}</textarea>
              </label>
              <label class="block">
                <span class="ic-eyebrow">Deliverable</span>
                <textarea
                  name="deliverable"
                  rows="2"
                  class="textarea mt-1 w-full"
                  placeholder="What to produce and where to save it"
                >{@wizard["deliverable"]}</textarea>
              </label>
              <label class="block">
                <span class="ic-eyebrow">Done when</span>
                <textarea
                  name="done"
                  rows="2"
                  class="textarea mt-1 w-full"
                  placeholder="How the agent knows it's finished"
                >{@wizard["done"]}</textarea>
              </label>
            <% else %>
              <label class="block">
                <span class="ic-eyebrow">Command</span>
                <select name="command" class="select mt-1 w-full">
                  <option value="noop" selected={@wizard["command"] == "noop"}>noop (test)</option>
                  <option value="analyze_pending" selected={@wizard["command"] == "analyze_pending"}>
                    analyze_pending
                  </option>
                </select>
                <span class="mt-1 block text-xs text-base-content/55">
                  Deterministic job run by an Elixir worker.
                </span>
              </label>
            <% end %>
          </form>
        <% :schedule -> %>
          <form phx-change="wizard_change" class="space-y-3">
            <p class="text-sm text-base-content/70">When should it run?</p>
            <.schedule_option
              mode="once"
              current={@wizard["schedule"]}
              title="Once, immediately"
              desc="Dispatch as soon as the shift picks it up."
            />
            <.schedule_option
              mode="recurring"
              current={@wizard["schedule"]}
              title="On a schedule"
              desc="Repeat on a cron expression."
            />
            <.schedule_option
              mode="manual"
              current={@wizard["schedule"]}
              title="Manual only"
              desc="Sits idle until you hit Run now."
            />
            <label :if={@wizard["schedule"] == "recurring"} class="block">
              <span class="ic-eyebrow">Cron</span>
              <input
                type="text"
                name="cron"
                value={@wizard["cron"]}
                class="input mt-1 w-full font-mono"
                placeholder="*/15 * * * *"
              />
            </label>
          </form>
        <% :review -> %>
          <form phx-change="wizard_change" class="space-y-4">
            <label class="block">
              <span class="ic-eyebrow">Task name <span class="text-error">*</span></span>
              <input
                type="text"
                name="name"
                value={@wizard["name"]}
                class="input mt-1 w-full"
                placeholder="Morning digest"
              />
            </label>
            <div class="rounded-lg border-2 border-base-content/15 bg-base-200/40 p-3">
              <p class="ic-eyebrow mb-2">{review_heading(@wizard)}</p>
              <pre class="whitespace-pre-wrap break-words font-mono text-xs leading-6 text-base-content/80">{review_body(@wizard)}</pre>
            </div>
            <p :if={@wizard["type"] == "agent"} class="text-xs text-base-content/55">
              This brief is what the on-shift agent ({@wizard["engine"] || "claude"}) reads and interprets when dispatched.
            </p>
          </form>
      <% end %>

      <div class="flex items-center justify-between gap-2 border-t-2 border-base-content/10 pt-4">
        <button
          :if={@step != :type}
          type="button"
          phx-click="wizard_back"
          class="rounded border-2 border-base-content/30 px-4 py-2 text-sm font-semibold transition hover:bg-base-200"
        >
          Back
        </button>
        <span :if={@step == :type}></span>
        <button
          :if={@step in [:brief, :schedule]}
          type="button"
          phx-click="wizard_next"
          class="rounded bg-primary px-4 py-2 text-sm font-semibold text-primary-content transition hover:opacity-85"
        >
          Next
        </button>
        <button
          :if={@step == :review}
          type="button"
          phx-click="wizard_create"
          class="rounded bg-primary px-4 py-2 text-sm font-semibold text-primary-content transition hover:opacity-85"
        >
          Create task
        </button>
      </div>
    </div>
    """
  end

  attr :mode, :string, required: true
  attr :current, :string, required: true
  attr :title, :string, required: true
  attr :desc, :string, required: true

  defp schedule_option(assigns) do
    ~H"""
    <button
      type="button"
      phx-click="wizard_schedule"
      phx-value-mode={@mode}
      class={[
        "block w-full rounded-lg border-2 p-3 text-left transition",
        if(@current == @mode,
          do: "border-primary bg-primary/10",
          else: "border-base-content/20 hover:border-primary"
        )
      ]}
    >
      <span class="block text-sm font-semibold">{@title}</span>
      <span class="block text-xs text-base-content/60">{@desc}</span>
    </button>
    """
  end

  attr :tasks, :list, required: true

  defp task_table(assigns) do
    ~H"""
    <div class="ic-panel overflow-hidden">
      <div class="border-b-2 border-base-content/15 px-4 py-3">
        <p class="ic-eyebrow">Tasks ({length(@tasks)})</p>
      </div>

      <div :if={@tasks == []} class="px-4 py-10 text-center text-sm text-base-content/55">
        No tasks yet. Add one with the wizard.
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
          <button type="button" phx-click="run_now" phx-value-id={task.id} class={action_btn()}>
            Run now
          </button>
          <button type="button" phx-click="toggle" phx-value-id={task.id} class={action_btn()}>
            {if task.enabled, do: "Disable", else: "Enable"}
          </button>
          <button
            type="button"
            phx-click="delete"
            phx-value-id={task.id}
            class={action_btn("text-error hover:border-error")}
          >
            Delete
          </button>
        </li>
      </ul>
    </div>
    """
  end

  defp review_heading(%{"type" => "agent"}), do: "Brief for the on-shift agent"
  defp review_heading(%{"type" => "pipeline"}), do: "Pipeline job"
  defp review_heading(_), do: "Summary"

  defp review_body(%{"type" => "agent"} = w), do: build_brief(w)

  defp review_body(%{"type" => "pipeline"} = w),
    do: "Runs the `#{w["command"]}` pipeline command."

  defp review_body(_), do: ""

  defp target_label(%{type: "agent", engine: engine}), do: " · #{engine || "claude"}"

  defp target_label(%{type: "pipeline", command: command}) when is_binary(command),
    do: " · #{command}"

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
