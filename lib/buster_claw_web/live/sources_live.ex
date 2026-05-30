defmodule BusterClawWeb.SourcesLive do
  use BusterClawWeb, :live_view

  alias BusterClaw.{Ingest, Sources}
  alias BusterClaw.Sources.Source

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Phoenix.PubSub.subscribe(BusterClaw.PubSub, "sources")

    changeset = Source.changeset(%Source{}, %{type: "article", enabled: true})

    {:ok,
     socket
     |> assign(:page_title, "Sources")
     |> assign(:form, to_form(changeset))
     |> assign(:result, nil)
     |> load_sources()}
  end

  @impl true
  def handle_info({_event, _payload}, socket) do
    {:noreply, load_sources(socket)}
  end

  @impl true
  def handle_event("validate", %{"source" => params}, socket) do
    changeset =
      %Source{}
      |> Source.changeset(normalize_source_params(params))
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :form, to_form(changeset))}
  end

  def handle_event("add_source", %{"source" => params}, socket) do
    case Sources.create_source(normalize_source_params(params)) do
      {:ok, _source} ->
        {:noreply,
         socket
         |> assign(:form, to_form(Source.changeset(%Source{}, %{type: "article", enabled: true})))
         |> assign(:result, "Source added.")
         |> load_sources()}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset))}
    end
  end

  def handle_event("delete_source", %{"id" => id}, socket) do
    source = Sources.get_source!(id)
    {:ok, _} = Sources.delete_source(source)

    {:noreply, load_sources(assign(socket, :result, "Source deleted."))}
  end

  def handle_event("ingest_source", %{"id" => id}, socket) do
    source = Sources.get_source!(id)
    result = Ingest.ingest_source(source) |> format_ingest_result()

    {:noreply, load_sources(assign(socket, :result, result))}
  end

  def handle_event("ingest_all", _params, socket) do
    result = socket.assigns.sources |> Ingest.ingest_sources() |> format_summary()

    {:noreply, assign(socket, :result, result)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <section class="space-y-6">
        <div class="flex flex-col gap-3 sm:flex-row sm:items-end sm:justify-between">
          <div>
            <p class="ic-eyebrow">
              Ingestion
            </p>
            <h1 class="font-display text-5xl font-black uppercase tracking-tight">Sources</h1>
            <p class="mt-2 text-base text-base-content/70">
              Configure URL and RSS sources, then ingest them into the local Library.
            </p>
          </div>
          <button
            class="rounded bg-base-content px-4 py-2 text-sm font-semibold text-base-100"
            phx-click="ingest_all"
            disabled={@sources == []}
          >
            Ingest All
          </button>
        </div>

        <BusterClawWeb.LibraryTabs.tabs active={:sources} />

        <p :if={@result} class="rounded border border-base-300 bg-base-100 px-4 py-3 text-sm">
          {@result}
        </p>

        <div class="grid gap-6 lg:grid-cols-[380px_minmax(0,1fr)]">
          <.form
            for={@form}
            phx-change="validate"
            phx-submit="add_source"
            class="space-y-4 rounded-lg border border-base-300 bg-base-100 p-5"
          >
            <h2 class="text-lg font-semibold">Add Source</h2>
            <.input field={@form[:url]} label="URL" />
            <.input field={@form[:name]} label="Name" />
            <.input
              field={@form[:type]}
              label="Type"
              type="select"
              options={[
                {"Article", "article"},
                {"Documentation", "documentation"},
                {"RSS", "rss"},
                {"Browser", "browser"}
              ]}
            />
            <.input field={@form[:browser_engine]} label="Browser engine" />
            <.input field={@form[:tags_text]} label="Tags" value={@form[:tags_text].value || ""} />
            <button class="rounded bg-base-content px-4 py-2 text-sm font-semibold text-base-100">
              Add Source
            </button>
          </.form>

          <section class="rounded-lg border border-base-300 bg-base-100">
            <div class="border-b border-base-300 px-4 py-3 text-sm font-semibold">
              {@sources_count} sources
            </div>

            <div class="divide-y divide-base-300">
              <div
                :for={source <- @sources}
                class="flex flex-col gap-4 px-4 py-4 sm:flex-row sm:items-center sm:justify-between"
              >
                <div class="min-w-0">
                  <h2 class="truncate text-sm font-semibold">{source.name || source.url}</h2>
                  <p class="mt-1 truncate font-mono text-xs text-base-content/60">{source.url}</p>
                  <div class="mt-2 flex flex-wrap gap-2 text-xs">
                    <span class="rounded border border-base-300 px-2 py-1">{source.type}</span>
                    <span :for={tag <- tags(source)} class="rounded border border-base-300 px-2 py-1">
                      {tag}
                    </span>
                  </div>
                </div>

                <div class="flex gap-2">
                  <button
                    class="rounded border border-base-300 px-3 py-2 text-sm"
                    phx-click="ingest_source"
                    phx-value-id={source.id}
                  >
                    Ingest
                  </button>
                  <button
                    class="rounded border border-error/40 px-3 py-2 text-sm text-error"
                    phx-click="delete_source"
                    phx-value-id={source.id}
                  >
                    Delete
                  </button>
                </div>
              </div>

              <div :if={@sources == []} class="px-4 py-10 text-center text-sm text-base-content/60">
                No sources configured yet.
              </div>
            </div>
          </section>
        </div>
      </section>
    </Layouts.app>
    """
  end

  defp load_sources(socket) do
    sources = Sources.list_sources()

    socket
    |> assign(:sources, sources)
    |> assign(:sources_count, length(sources))
  end

  defp normalize_source_params(params) do
    params
    |> Map.put("tags", %{"items" => parse_tags(Map.get(params, "tags_text", ""))})
    |> Map.drop(["tags_text"])
  end

  defp parse_tags(text) do
    text
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp tags(source), do: get_in(source.tags || %{}, ["items"]) || []

  defp format_ingest_result({:ok, count, _items}), do: "Ingested #{count} documents."

  defp format_ingest_result({:error, reason}),
    do: "Ingest failed: #{BusterClawWeb.ErrorFormatter.format(reason)}"

  defp format_summary(%{saved: saved, errors: []}), do: "Ingested #{saved} documents."

  defp format_summary(%{saved: saved, errors: errors}),
    do: "Ingested #{saved} documents with #{length(errors)} errors."
end
