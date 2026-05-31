defmodule BusterClawWeb.SchedulerLive do
  use BusterClawWeb, :live_view

  alias BusterClaw.Automation.SchedulerJob
  alias BusterClaw.Scheduler

  @impl true
  def mount(_params, _session, socket) do
    changeset = Scheduler.change_job(%SchedulerJob{}, %{type: "ingest", enabled: true})

    {:ok,
     socket
     |> assign(:page_title, "Scheduler")
     |> assign(:form, to_form(changeset))
     |> assign(:result, nil)
     |> load_jobs()}
  end

  @impl true
  def handle_event("validate", %{"scheduler_job" => params}, socket) do
    changeset =
      %SchedulerJob{}
      |> Scheduler.change_job(params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :form, to_form(changeset))}
  end

  def handle_event("save", %{"scheduler_job" => params}, socket) do
    case Scheduler.create_job(params) do
      {:ok, _job} ->
        {:noreply,
         socket
         |> assign(:form, to_form(Scheduler.change_job(%SchedulerJob{}, %{type: "ingest"})))
         |> assign(:result, "Scheduler job saved.")
         |> load_jobs()}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset))}
    end
  end

  def handle_event("run_now", %{"id" => id}, socket) do
    result =
      case Scheduler.run_now(id) do
        {:ok, summary} -> "Run completed: #{inspect(summary)}"
        {:error, reason} -> "Run failed: #{BusterClawWeb.ErrorFormatter.format(reason)}"
      end

    {:noreply, socket |> assign(:result, result) |> load_jobs()}
  end

  def handle_event("toggle", %{"id" => id}, socket) do
    job = Scheduler.get_job!(id)
    {:ok, _job} = Scheduler.update_job(job, %{enabled: !job.enabled})
    {:noreply, load_jobs(socket)}
  end

  def handle_event("delete", %{"id" => id}, socket) do
    id |> Scheduler.get_job!() |> Scheduler.delete_job()
    {:noreply, socket |> assign(:result, "Scheduler job deleted.") |> load_jobs()}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <section class="space-y-6">
        <div>
          <p class="ic-eyebrow">
            Automation
          </p>
          <h1 class="font-display text-5xl font-black uppercase tracking-tight">Scheduler</h1>
          <p class="mt-2 max-w-3xl text-base text-base-content/70">
            Configure recurring automation jobs and trigger a manual run.
          </p>
        </div>

        <BusterClawWeb.AdvancedTabs.tabs active={:scheduler} />

        <p :if={@result} class="rounded border border-base-300 bg-base-100 px-4 py-3 text-sm">
          {@result}
        </p>

        <div class="grid gap-6 lg:grid-cols-[380px_minmax(0,1fr)]">
          <.form
            for={@form}
            id="scheduler-job-form"
            phx-change="validate"
            phx-submit="save"
            class="space-y-4 rounded-lg border border-base-300 bg-base-100 p-5"
          >
            <h2 class="text-lg font-semibold">New Job</h2>
            <.input field={@form[:job_id]} label="Job ID" />
            <.input
              field={@form[:type]}
              label="Type"
              type="select"
              options={[
                {"Ingest", "ingest"},
                {"Analyze", "analyze"},
                {"Poll Integrations", "integrations_poll"},
                {"Monitoring Brief", "monitoring_brief"},
                {"Full", "full"},
                {"Digest", "digest"},
                {"Custom", "custom"}
              ]}
            />
            <.input field={@form[:cron]} label="Cron" />
            <.input field={@form[:custom_cmd]} label="Custom Command" />
            <.input field={@form[:deliver_to]} label="Deliver To" />
            <.input field={@form[:enabled]} label="Enabled" type="checkbox" />
            <button class="rounded bg-base-content px-4 py-2 text-sm font-semibold text-base-100">
              Save Job
            </button>
          </.form>

          <section class="rounded-lg border border-base-300 bg-base-100">
            <div class="border-b border-base-300 px-4 py-3 text-sm font-semibold">
              {@jobs_count} jobs
            </div>
            <div class="divide-y divide-base-300">
              <div
                :for={job <- @jobs}
                class="flex flex-col gap-4 px-4 py-4 sm:flex-row sm:items-center sm:justify-between"
              >
                <div class="min-w-0">
                  <h2 class="truncate text-sm font-semibold">{job.job_id}</h2>
                  <p class="mt-1 font-mono text-xs text-base-content/60">{job.cron}</p>
                  <div class="mt-2 flex flex-wrap gap-2 text-xs">
                    <span class="rounded border border-base-300 px-2 py-1">{job.type}</span>
                    <span class="rounded border border-base-300 px-2 py-1">
                      {if job.enabled, do: "enabled", else: "disabled"}
                    </span>
                  </div>
                </div>

                <div class="flex flex-wrap gap-2">
                  <button
                    class="rounded border border-base-300 px-3 py-2 text-sm"
                    phx-click="run_now"
                    phx-value-id={job.id}
                  >
                    Run
                  </button>
                  <button
                    class="rounded border border-base-300 px-3 py-2 text-sm"
                    phx-click="toggle"
                    phx-value-id={job.id}
                  >
                    Toggle
                  </button>
                  <button
                    class="rounded border border-error/40 px-3 py-2 text-sm text-error"
                    phx-click="delete"
                    phx-value-id={job.id}
                  >
                    Delete
                  </button>
                </div>
              </div>
              <div :if={@jobs == []} class="px-4 py-10 text-center text-sm text-base-content/60">
                No scheduler jobs configured yet.
              </div>
            </div>
          </section>
        </div>
      </section>
    </Layouts.app>
    """
  end

  defp load_jobs(socket) do
    jobs = Scheduler.list_jobs()

    socket
    |> assign(:jobs, jobs)
    |> assign(:jobs_count, length(jobs))
  end
end
