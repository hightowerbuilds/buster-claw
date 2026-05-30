defmodule BusterClawWeb.AnalysisLive do
  use BusterClawWeb, :live_view

  alias BusterClaw.Analysis
  alias BusterClaw.Library

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Analysis.subscribe()

    {:ok,
     socket
     |> assign(:page_title, "Analysis")
     |> assign(:selected_job, nil)
     |> assign(:last_error, nil)
     |> load_state()}
  end

  @impl true
  def handle_event("queue_document", %{"id" => id}, socket) do
    case Analysis.queue_document(id) do
      {:ok, _job} ->
        {:noreply, load_state(socket)}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:last_error, BusterClawWeb.ErrorFormatter.format(reason))
         |> load_state()}
    end
  end

  def handle_event("run_pending", _params, socket) do
    _results = Analysis.run_pending(limit: 1)
    {:noreply, load_state(socket)}
  end

  def handle_event("drain_pending", _params, socket) do
    _results = Analysis.drain_pending()
    {:noreply, load_state(socket)}
  end

  def handle_event("select_job", %{"id" => id}, socket) do
    job = Enum.find(socket.assigns.jobs, &(to_string(&1.id) == id))
    {:noreply, assign(socket, :selected_job, job)}
  end

  @impl true
  def handle_info({:analysis_job, _event, _job}, socket) do
    {:noreply, load_state(socket)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <section class="space-y-6">
        <div class="flex flex-col gap-3 sm:flex-row sm:items-end sm:justify-between">
          <div>
            <p class="ic-eyebrow">
              Workflow
            </p>
            <h1 class="font-display text-5xl font-black uppercase tracking-tight">Analysis Queue</h1>
            <p class="mt-2 text-base text-base-content/70">
              Queue fetched markdown documents and persist provider-generated reports.
            </p>
          </div>
          <div class="flex flex-wrap gap-2">
            <button
              type="button"
              class="rounded border border-base-300 px-4 py-2 text-sm font-semibold"
              phx-click="run_pending"
            >
              Run Next
            </button>
            <button
              type="button"
              class="rounded bg-base-content px-4 py-2 text-sm font-semibold text-base-100"
              phx-click="drain_pending"
            >
              Drain Queue
            </button>
          </div>
        </div>

        <BusterClawWeb.LibraryTabs.tabs active={:analysis} />

        <div
          :if={@last_error}
          class="rounded border border-error/40 bg-error/10 px-4 py-3 text-sm text-error"
        >
          {@last_error}
        </div>

        <div class="grid gap-4 md:grid-cols-3">
          <.metric label="Documents" value={@documents_count} />
          <.metric label="Queued Jobs" value={@queued_count} />
          <.metric label="Reports" value={@reports_count} />
        </div>

        <div class="grid gap-6 xl:grid-cols-[minmax(280px,420px)_minmax(0,1fr)]">
          <section class="rounded-lg border border-base-300 bg-base-100">
            <div class="border-b border-base-300 px-4 py-3 text-sm font-semibold">
              Documents
            </div>
            <div class="divide-y divide-base-300">
              <div :for={document <- @documents} class="px-4 py-4">
                <div class="flex items-start justify-between gap-4">
                  <div class="min-w-0">
                    <h2 class="truncate text-sm font-semibold">
                      {document.name || document.filename}
                    </h2>
                    <p class="mt-1 truncate font-mono text-xs text-base-content/60">
                      {document.artifact_path}
                    </p>
                  </div>
                  <span class="shrink-0 rounded border border-base-300 px-2 py-1 text-xs">
                    {document.status}
                  </span>
                </div>
                <button
                  type="button"
                  class="mt-3 rounded border border-base-content px-3 py-2 text-xs font-semibold"
                  phx-click="queue_document"
                  phx-value-id={document.id}
                >
                  Queue
                </button>
              </div>

              <div :if={@documents == []} class="px-4 py-10 text-center text-sm text-base-content/60">
                No documents are available to analyze.
              </div>
            </div>
          </section>

          <section class="rounded-lg border border-base-300 bg-base-100">
            <div class="border-b border-base-300 px-4 py-3 text-sm font-semibold">
              Jobs
            </div>
            <div class="divide-y divide-base-300">
              <button
                :for={job <- @jobs}
                type="button"
                class="block w-full px-4 py-4 text-left hover:bg-base-200"
                phx-click="select_job"
                phx-value-id={job.id}
              >
                <div class="grid gap-3 md:grid-cols-[minmax(0,1fr)_120px_80px] md:items-center">
                  <div class="min-w-0">
                    <h2 class="truncate text-sm font-semibold">
                      {job.document && (job.document.name || job.document.filename)}
                    </h2>
                    <p class="mt-1 truncate font-mono text-xs text-base-content/60">
                      {job.model || "model pending"}
                    </p>
                    <p :if={job.error} class="mt-2 text-xs text-error">{job.error}</p>
                  </div>
                  <span class="rounded border border-base-300 px-2 py-1 text-center text-xs">
                    {job.status}
                  </span>
                  <span class="font-mono text-xs text-base-content/70">{job.progress}%</span>
                </div>
              </button>

              <div :if={@jobs == []} class="px-4 py-10 text-center text-sm text-base-content/60">
                No analysis jobs yet.
              </div>
            </div>
          </section>
        </div>

        <section class="rounded-lg border border-base-300 bg-base-100">
          <div class="border-b border-base-300 px-4 py-3 text-sm font-semibold">
            Reports
          </div>
          <div class="divide-y divide-base-300">
            <div :for={report <- @reports} class="px-4 py-4">
              <div class="flex flex-col gap-2 sm:flex-row sm:items-start sm:justify-between">
                <div class="min-w-0">
                  <h2 class="truncate text-sm font-semibold">{report.filename}</h2>
                  <p class="mt-1 break-words font-mono text-xs text-base-content/60">
                    {report.artifact_path}
                  </p>
                </div>
                <span class="text-xs text-base-content/60">{report.model}</span>
              </div>
            </div>

            <div :if={@reports == []} class="px-4 py-10 text-center text-sm text-base-content/60">
              No reports generated yet.
            </div>
          </div>
        </section>
      </section>
    </Layouts.app>
    """
  end

  defp load_state(socket) do
    documents = Library.list_documents()
    jobs = Analysis.list_jobs()
    reports = Analysis.list_reports()

    socket
    |> assign(:documents, documents)
    |> assign(:documents_count, length(documents))
    |> assign(:jobs, jobs)
    |> assign(:queued_count, Enum.count(jobs, &(&1.status in ["queued", "analyzing"])))
    |> assign(:reports, reports)
    |> assign(:reports_count, length(reports))
  end

  attr :label, :string, required: true
  attr :value, :integer, required: true

  defp metric(assigns) do
    ~H"""
    <section class="rounded-lg border border-base-300 bg-base-100 p-4">
      <p class="text-sm text-base-content/60">{@label}</p>
      <p class="mt-2 text-3xl font-semibold">{@value}</p>
    </section>
    """
  end
end
