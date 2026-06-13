defmodule BusterClawWeb.OrchestrationLive do
  @moduledoc """
  Orchestration hub: the live shift dashboard (home `OrchestrationPanel`), a
  guided **new-task wizard**, and the task table (run-now / enable / delete).

  The wizard walks the user through Type → Brief → Schedule → Review.

  - **Agent** tasks assemble the answers into a structured markdown **brief**
    stored as the task's prompt — what the on-shift model (Claude / Codex) reads.
  - **GWS action** tasks are deterministic `pipeline` tasks whose `command` is a
    Google Workspace command (sync Gmail/Calendar, search, draft, send) and whose
    `params` carry the action's arguments, resolved through `Commands.call`.

  Note: the Orchestrator no longer auto-dispatches these tasks — work is pulled
  from the Dispatch queue by a terminal Claude Code session. See
  `daily-growth/roadmaps/06-09-26-terminal-pull-queue-roadmap.md`.
  """
  use BusterClawWeb, :live_view

  alias BusterClaw.Google
  alias BusterClaw.Orchestration

  @steps [:type, :brief, :schedule, :review]
  @step_bar [{:type, "Type"}, {:brief, "Brief"}, {:schedule, "Schedule"}, {:review, "Review"}]
  @blank_to_nil ~w(engine cron command prompt)

  # GWS actions selectable in the wizard: {command, label, ordered fields}.
  @gws_actions [
    {"gmail_sync", "Sync Gmail → workspace", [:account, :query, :limit]},
    {"google_calendar_sync", "Sync Calendar → app", [:account, :calendar_id, :days_ahead]},
    {"gmail_search", "Search Gmail", [:account, :query, :limit]},
    {"gmail_read", "Read a message", [:account, :message_id]},
    {"gmail_label_list", "List Gmail labels", [:account]},
    {"gmail_draft_create", "Create a draft email", [:account, :to, :subject, :body]},
    {"gmail_send", "Send an email", [:account, :to, :subject, :body]}
  ]

  # field => {wizard_key, command_param_key, label, input_type, required?}
  @gws_fields %{
    account: {"gws_account", "email", "Google account", :account, false},
    query: {"gws_query", "query", "Query", :text, false},
    limit: {"gws_limit", "limit", "Limit", :number, false},
    calendar_id: {"gws_calendar_id", "calendar_id", "Calendar ID", :text, false},
    days_ahead: {"gws_days_ahead", "days_ahead", "Days ahead", :number, false},
    message_id: {"gws_message_id", "message_id", "Message ID", :text, true},
    to: {"gws_to", "to", "To", :text, true},
    subject: {"gws_subject", "subject", "Subject", :text, true},
    body: {"gws_body", "body", "Body", :textarea, true}
  }

  @wizard_defaults %{
    "type" => nil,
    "engine" => "claude",
    "objective" => "",
    "context" => "",
    "deliverable" => "",
    "done" => "",
    "schedule" => "once",
    "cron" => "",
    "name" => "",
    "gws_action" => "gmail_sync",
    "gws_account" => "",
    "gws_query" => "",
    "gws_limit" => "",
    "gws_calendar_id" => "",
    "gws_days_ahead" => "",
    "gws_message_id" => "",
    "gws_to" => "",
    "gws_subject" => "",
    "gws_body" => ""
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
     |> assign(:confirm_delete, nil)
     |> assign(:editing, nil)
     |> reset_wizard()
     |> load()}
  end

  @impl true
  def handle_info({:orchestration, _event}, socket), do: {:noreply, load(socket)}
  def handle_info(:refresh, socket), do: {:noreply, load(socket)}

  # --- shift control (emergency stop; shifts start from the terminal) ---

  @impl true
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

  # --- schedule row: edit ---

  def handle_event("edit_task", %{"id" => id}, socket) do
    case Orchestration.get_task(id) do
      nil -> {:noreply, load(socket)}
      task -> {:noreply, assign(socket, :editing, edit_form_for(task))}
    end
  end

  def handle_event("edit_change", params, socket) do
    editing =
      Enum.reduce(~w(name schedule cron enabled), socket.assigns.editing, fn key, acc ->
        case Map.fetch(params, key) do
          {:ok, value} -> Map.put(acc, key, value)
          :error -> acc
        end
      end)

    {:noreply, assign(socket, :editing, editing)}
  end

  def handle_event("cancel_edit", _params, socket), do: {:noreply, assign(socket, :editing, nil)}

  def handle_event("save_edit", _params, socket) do
    editing = socket.assigns.editing

    with :ok <- validate_edit(editing),
         task when not is_nil(task) <- Orchestration.get_task(editing["id"]),
         {:ok, _task} <- Orchestration.update_task(task, edit_attrs(editing, task)) do
      {:noreply, socket |> assign(:editing, nil) |> put_flash(:info, "Task updated.") |> load()}
    else
      {:error, message} when is_binary(message) ->
        {:noreply, put_flash(socket, :error, message)}

      _ ->
        {:noreply, put_flash(socket, :error, "Couldn't update the task — check the fields.")}
    end
  end

  # --- schedule row: delete (with confirmation) ---

  def handle_event("confirm_delete", %{"id" => id}, socket) do
    case Orchestration.get_task(id) do
      nil -> {:noreply, load(socket)}
      task -> {:noreply, assign(socket, :confirm_delete, %{id: task.id, name: task.name})}
    end
  end

  def handle_event("cancel_delete", _params, socket),
    do: {:noreply, assign(socket, :confirm_delete, nil)}

  def handle_event("delete_confirmed", _params, socket) do
    case socket.assigns.confirm_delete do
      %{id: id} ->
        case Orchestration.get_task(id) do
          nil -> :ok
          task -> Orchestration.delete_task(task)
        end

      _ ->
        :ok
    end

    {:noreply, socket |> assign(:confirm_delete, nil) |> load()}
  end

  # --- state ---

  defp load(socket) do
    socket
    |> assign(:tasks, Orchestration.list_tasks())
    |> assign(:snapshot, Orchestration.snapshot())
    |> assign(:accounts, Google.list_account_summaries())
  end

  defp reset_wizard(socket) do
    socket |> assign(:wizard_step, :type) |> assign(:wizard, @wizard_defaults)
  end

  @wizard_keys ~w(engine objective context deliverable done cron name
                  gws_action gws_account gws_query gws_limit gws_calendar_id
                  gws_days_ahead gws_message_id gws_to gws_subject gws_body)

  defp merge_wizard(wizard, params) do
    Enum.reduce(@wizard_keys, wizard, fn key, acc ->
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

  defp validate_step(:brief, %{"type" => "gws"} = w) do
    missing =
      w
      |> gws_field_atoms()
      |> Enum.filter(fn atom ->
        {wiz_key, _param, _label, _type, required} = @gws_fields[atom]
        required and blank?(w[wiz_key])
      end)

    if missing == [],
      do: :ok,
      else: {:error, "Fill in the required fields for this action."}
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

    {task_type, target} =
      case w["type"] do
        "agent" -> {"agent", %{"engine" => w["engine"], "prompt" => build_brief(w)}}
        "gws" -> {"pipeline", %{"command" => w["gws_action"], "params" => gws_params(w)}}
        other -> {other, %{}}
      end

    %{"name" => w["name"], "type" => task_type}
    |> Map.merge(target)
    |> Map.merge(schedule)
    |> normalize()
  end

  # The ordered fields for the currently-selected GWS action.
  defp gws_field_atoms(w) do
    case List.keyfind(@gws_actions, w["gws_action"], 0) do
      {_command, _label, fields} -> fields
      nil -> []
    end
  end

  defp gws_action_label(action) do
    case List.keyfind(@gws_actions, action, 0) do
      {_command, label, _fields} -> label
      nil -> action
    end
  end

  # Collect the chosen action's fields into the command's params map.
  defp gws_params(w) do
    base =
      w
      |> gws_field_atoms()
      |> Enum.reduce(%{}, fn atom, acc ->
        {wiz_key, param_key, _label, type, _required} = @gws_fields[atom]
        value = w[wiz_key]

        cond do
          blank?(value) -> acc
          type == :number -> maybe_put_int(acc, param_key, value)
          true -> Map.put(acc, param_key, value)
        end
      end)

    # A scheduled send is pre-authorized by the user when they set up the task.
    if w["gws_action"] == "gmail_send", do: Map.put(base, "confirm_send", true), else: base
  end

  defp maybe_put_int(acc, key, value) do
    case Integer.parse(to_string(value)) do
      {n, _rest} -> Map.put(acc, key, n)
      :error -> acc
    end
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

  # --- edit (scheduling + status only) ---

  defp edit_form_for(task) do
    %{
      "id" => task.id,
      "name" => task.name,
      "schedule" => schedule_mode_of(task),
      "cron" => task.cron || "",
      "enabled" => task.enabled,
      "summary" => "#{task.type}#{target_label(task)}"
    }
  end

  defp schedule_mode_of(%{cron: cron}) when is_binary(cron) and cron != "", do: "recurring"
  defp schedule_mode_of(%{due_at: %DateTime{}}), do: "once"
  defp schedule_mode_of(_task), do: "manual"

  defp validate_edit(%{"name" => name}) when name in [nil, ""],
    do: {:error, "Give the task a name."}

  defp validate_edit(%{"schedule" => "recurring", "cron" => cron}) do
    if BusterClaw.Scheduler.Cron.valid?(cron),
      do: :ok,
      else: {:error, "Enter a valid cron expression (e.g. */15 * * * *)."}
  end

  defp validate_edit(_editing), do: :ok

  defp edit_attrs(editing, task) do
    schedule =
      case editing["schedule"] do
        "once" -> %{due_at: now(), cron: nil, next_run_at: nil}
        "recurring" -> %{cron: editing["cron"], due_at: nil, next_run_at: nil}
        _manual -> %{cron: nil, due_at: nil, next_run_at: nil}
      end

    %{name: editing["name"], enabled: checkbox_on?(editing["enabled"])}
    |> Map.merge(schedule)
    |> maybe_rearm(task)
  end

  # Re-arm a finished task so an edited schedule actually runs again; leave
  # running/claimed/pending tasks alone.
  defp maybe_rearm(attrs, %{state: state}) when state in ~w(done failed cancelled),
    do: Map.put(attrs, :state, "pending")

  defp maybe_rearm(attrs, _task), do: attrs

  defp checkbox_on?(value), do: value in [true, "true", "on", "1"]

  # --- render ---

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
          <.shift_status snapshot={@snapshot} />
        </div>

        <div class="grid gap-6 lg:grid-cols-[420px_minmax(0,1fr)]">
          <.wizard wizard={@wizard} step={@wizard_step} accounts={@accounts} />
          <.schedule tasks={@tasks} />
        </div>
      </section>

      <.delete_modal confirm={@confirm_delete} />
      <.edit_modal editing={@editing} />
    </Layouts.app>
    """
  end

  attr :confirm, :map, default: nil

  defp delete_modal(assigns) do
    ~H"""
    <div :if={@confirm} class="fixed inset-0 z-50 flex items-center justify-center p-4">
      <div class="absolute inset-0 bg-black/50" phx-click="cancel_delete" aria-hidden="true"></div>
      <div
        role="dialog"
        aria-modal="true"
        class="relative w-full max-w-sm space-y-4 rounded-lg border-2 border-base-content/20 bg-base-100 p-5 shadow-xl"
      >
        <h2 class="font-display text-lg font-black uppercase tracking-tight">Delete task</h2>
        <p class="text-sm leading-6 text-base-content/80">
          Delete <span class="font-semibold">"{@confirm.name}"</span>? This can't be undone.
        </p>
        <div class="flex justify-end gap-2">
          <button
            type="button"
            phx-click="cancel_delete"
            class="rounded border-2 border-base-content/30 px-4 py-2 text-sm font-semibold transition hover:bg-base-200"
          >
            Cancel
          </button>
          <button
            type="button"
            phx-click="delete_confirmed"
            class="rounded border-2 border-error/60 bg-error/10 px-4 py-2 text-sm font-semibold text-error transition hover:bg-error/20"
          >
            Delete
          </button>
        </div>
      </div>
    </div>
    """
  end

  attr :editing, :map, default: nil

  defp edit_modal(assigns) do
    ~H"""
    <div :if={@editing} class="fixed inset-0 z-50 flex items-center justify-center p-4">
      <div class="absolute inset-0 bg-black/50" phx-click="cancel_edit" aria-hidden="true"></div>
      <div
        role="dialog"
        aria-modal="true"
        class="relative w-full max-w-md rounded-lg border-2 border-base-content/20 bg-base-100 p-5 shadow-xl"
      >
        <h2 class="mb-1 font-display text-lg font-black uppercase tracking-tight">Edit task</h2>
        <p class="mb-4 font-mono text-xs text-base-content/55">{@editing["summary"]}</p>

        <form phx-change="edit_change" phx-submit="save_edit" class="space-y-4">
          <label class="block">
            <span class="ic-eyebrow">Name <span class="text-error">*</span></span>
            <input type="text" name="name" value={@editing["name"]} class="input mt-1 w-full" />
          </label>

          <label class="block">
            <span class="ic-eyebrow">Schedule</span>
            <select name="schedule" class="select mt-1 w-full">
              <option value="once" selected={@editing["schedule"] == "once"}>
                Once, immediately
              </option>
              <option value="recurring" selected={@editing["schedule"] == "recurring"}>
                On a schedule (cron)
              </option>
              <option value="manual" selected={@editing["schedule"] == "manual"}>
                Manual only
              </option>
            </select>
          </label>

          <label :if={@editing["schedule"] == "recurring"} class="block">
            <span class="ic-eyebrow">Cron</span>
            <input
              type="text"
              name="cron"
              value={@editing["cron"]}
              class="input mt-1 w-full font-mono"
              placeholder="*/15 * * * *"
            />
          </label>

          <label class="flex items-center gap-2">
            <input type="hidden" name="enabled" value="false" />
            <input
              type="checkbox"
              name="enabled"
              value="true"
              checked={checkbox_on?(@editing["enabled"])}
              class="checkbox"
            />
            <span class="text-sm">Enabled</span>
          </label>

          <div class="flex justify-end gap-2 border-t-2 border-base-content/10 pt-4">
            <button
              type="button"
              phx-click="cancel_edit"
              class="rounded border-2 border-base-content/30 px-4 py-2 text-sm font-semibold transition hover:bg-base-200"
            >
              Cancel
            </button>
            <button
              type="submit"
              class="rounded bg-primary px-4 py-2 text-sm font-semibold text-primary-content transition hover:opacity-85"
            >
              Save
            </button>
          </div>
        </form>
      </div>
    </div>
    """
  end

  # Compact shift status + emergency stop (the running/upcoming lists live in the
  # Schedule column now; the full panel stays on Home).
  attr :snapshot, :map, required: true

  defp shift_status(assigns) do
    ~H"""
    <div class="flex flex-wrap items-center gap-2 text-xs">
      <%= if @snapshot.shift do %>
        <span class="rounded-full bg-success/15 px-3 py-1 font-semibold text-success">
          Active · {elapsed(@snapshot.shift)} on shift
        </span>
        <span class="font-mono text-base-content/55">
          {@snapshot.shift.dispatched_count} dispatched · {@snapshot.shift.done_count} done · {@snapshot.shift.failed_count} failed
        </span>
        <button
          type="button"
          phx-click="kill_shift"
          class="rounded border-2 border-error/60 bg-error/10 px-3 py-1 font-semibold text-error transition hover:bg-error/20"
        >
          Emergency stop
        </button>
      <% else %>
        <span class="font-mono text-base-content/55">
          No active shift — start one from the terminal.
        </span>
      <% end %>
    </div>
    """
  end

  defp elapsed(%{started_at: %DateTime{} = started_at}) do
    secs = max(DateTime.diff(DateTime.utc_now(), started_at), 0)

    cond do
      secs < 60 -> "just now"
      secs < 3600 -> "#{div(secs, 60)}m"
      true -> "#{div(secs, 3600)}h #{rem(div(secs, 60), 60)}m"
    end
  end

  defp elapsed(_shift), do: "—"

  attr :wizard, :map, required: true
  attr :step, :atom, required: true
  attr :accounts, :list, default: []

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
              phx-value-type="gws"
              class="block w-full rounded-lg border-2 border-base-content/20 p-4 text-left transition hover:border-primary"
            >
              <span class="block font-display text-sm font-black uppercase tracking-tight">
                GWS action
              </span>
              <span class="block text-xs text-base-content/60">
                A deterministic Google Workspace action — sync Gmail/Calendar, search, draft, or send email.
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
                <span class="ic-eyebrow">Action</span>
                <select name="gws_action" class="select mt-1 w-full">
                  <option
                    :for={{command, label, _fields} <- gws_actions()}
                    value={command}
                    selected={@wizard["gws_action"] == command}
                  >
                    {label}
                  </option>
                </select>
                <span class="mt-1 block text-xs text-base-content/55">
                  Runs deterministically during the shift — no model.
                </span>
              </label>

              <label class="block">
                <span class="ic-eyebrow">Google account</span>
                <select name="gws_account" class="select mt-1 w-full">
                  <option value="" selected={@wizard["gws_account"] in [nil, ""]}>
                    Default account
                  </option>
                  <option
                    :for={account <- @accounts}
                    value={account.email}
                    selected={@wizard["gws_account"] == account.email}
                  >
                    {account.email}
                  </option>
                </select>
              </label>

              <.gws_field
                :for={atom <- gws_field_atoms(@wizard) -- [:account]}
                field={atom}
                wizard={@wizard}
              />

              <p
                :if={@wizard["gws_action"] == "gmail_send"}
                class="rounded-sm border-2 border-primary/50 bg-primary/10 px-3 py-2 text-xs leading-5"
              >
                Heads up: this sends a real email every time the task runs — it's
                pre-authorized by scheduling it here.
              </p>
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

  # Module attrs aren't visible as `@...` inside ~H (that's assigns); expose them.
  defp gws_actions, do: @gws_actions

  attr :field, :atom, required: true
  attr :wizard, :map, required: true

  defp gws_field(assigns) do
    {wiz_key, _param, label, type, required} = @gws_fields[assigns.field]

    assigns =
      assign(assigns,
        wiz_key: wiz_key,
        label: label,
        type: type,
        required: required,
        value: assigns.wizard[wiz_key]
      )

    ~H"""
    <label class="block">
      <span class="ic-eyebrow">
        {@label}<span :if={@required} class="text-error"> *</span>
      </span>
      <textarea :if={@type == :textarea} name={@wiz_key} rows="3" class="textarea mt-1 w-full">{@value}</textarea>
      <input
        :if={@type != :textarea}
        type={if @type == :number, do: "number", else: "text"}
        name={@wiz_key}
        value={@value}
        class="input mt-1 w-full"
      />
    </label>
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

  defp schedule(assigns) do
    {non_cron, cron} = split_schedule(assigns.tasks)
    assigns = assign(assigns, non_cron: non_cron, cron: cron)

    ~H"""
    <div class="ic-panel overflow-hidden">
      <div class="flex items-center justify-between border-b-2 border-base-content/15 px-4 py-3">
        <p class="ic-eyebrow">Schedule</p>
        <span class="font-mono text-xs text-base-content/55">{length(@tasks)} tasks</span>
      </div>

      <div :if={@tasks == []} class="px-4 py-10 text-center text-sm text-base-content/55">
        No tasks yet. Add one with the wizard.
      </div>

      <ul :if={@tasks != []} class="divide-y divide-base-300">
        <.task_row :for={task <- @non_cron} task={task} />
        <li
          :if={@cron != [] and @non_cron != []}
          class="bg-base-200/40 px-4 py-1 font-mono text-[0.7rem] uppercase tracking-wide text-base-content/45"
        >
          Recurring
        </li>
        <.task_row :for={task <- @cron} task={task} />
      </ul>
    </div>
    """
  end

  attr :task, :map, required: true

  defp task_row(assigns) do
    ~H"""
    <li class="flex flex-wrap items-center gap-3 px-4 py-3 text-sm">
      <span class={["size-2 shrink-0 rounded-full", state_dot(@task.state)]}></span>
      <div class="min-w-0 flex-1">
        <p class="truncate font-semibold">{@task.name}</p>
        <p class="truncate font-mono text-xs text-base-content/55">
          {@task.type}{target_label(@task)} · {schedule_label(@task)} · {@task.state}
        </p>
      </div>
      <span
        :if={not @task.enabled}
        class="rounded-sm border-2 border-base-content/20 px-2 py-1 font-mono text-[0.7rem] uppercase tracking-wide text-base-content/45"
      >
        paused
      </span>
      <button type="button" phx-click="edit_task" phx-value-id={@task.id} class={action_btn()}>
        Edit
      </button>
      <button
        type="button"
        phx-click="confirm_delete"
        phx-value-id={@task.id}
        class={action_btn("text-error hover:border-error")}
      >
        Delete
      </button>
    </li>
    """
  end

  # Schedule ordering: one-shot / manual (non-cron) tasks on top, then recurring
  # (cron) tasks chronologically by next run.
  defp split_schedule(tasks) do
    {cron, non_cron} = Enum.split_with(tasks, &recurring?/1)
    {Enum.sort_by(non_cron, &due_key/1), Enum.sort_by(cron, &next_key/1)}
  end

  defp recurring?(%{cron: cron}), do: is_binary(cron) and cron != ""
  defp recurring?(_task), do: false

  defp due_key(task), do: {at_key(task.due_at), task.name || ""}
  defp next_key(task), do: {at_key(task.next_run_at), task.name || ""}

  defp at_key(%DateTime{} = at), do: DateTime.to_unix(at)
  defp at_key(_at), do: :infinity

  defp review_heading(%{"type" => "agent"}), do: "Brief for the on-shift agent"
  defp review_heading(%{"type" => "gws"}), do: "Google Workspace action"
  defp review_heading(_), do: "Summary"

  defp review_body(%{"type" => "agent"} = w), do: build_brief(w)

  defp review_body(%{"type" => "gws"} = w) do
    account = if blank?(w["gws_account"]), do: "default", else: w["gws_account"]

    detail =
      gws_params(w)
      |> Map.drop(["email", "confirm_send"])
      |> Enum.map(fn {key, value} -> "#{key}: #{value}" end)

    Enum.join(
      [
        "Action: #{gws_action_label(w["gws_action"])} (#{w["gws_action"]})",
        "Account: #{account}" | detail
      ],
      "\n"
    )
  end

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
