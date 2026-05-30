defmodule BusterClawWeb.DocumentsLive do
  use BusterClawWeb, :live_view

  alias BusterClaw.Library
  alias BusterClaw.Runtime.Status

  @impl true
  def mount(_params, _session, socket) do
    snapshot = Status.snapshot()

    {:ok,
     socket
     |> assign(:page_title, "Documents")
     |> assign(:selected_document, nil)
     |> assign(:document_content, "")
     |> assign(:library_root, snapshot.library_root)
     |> assign(:library_exists?, snapshot.library_exists?)
     |> load_documents(select: :first)}
  end

  @impl true
  def handle_event("index_existing", _params, socket) do
    Library.index_existing_raw_documents()

    {:noreply, load_documents(socket)}
  end

  def handle_event("open_document", %{"id" => id}, socket) do
    document = Library.get_document!(id)

    {:noreply, select_document(socket, document)}
  end

  def handle_event("delete_document", %{"id" => id}, socket) do
    document = Library.get_document!(id)
    _ = Library.delete_raw_document(document)

    {:noreply, load_documents(socket, select: :first)}
  end

  def handle_event("close_document", _params, socket) do
    {:noreply, assign(socket, selected_document: nil, document_content: "")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <section class="space-y-6">
        <div class="flex flex-col gap-3 sm:flex-row sm:items-end sm:justify-between">
          <div>
            <p class="ic-eyebrow">
              Library
            </p>
            <h1 class="font-display text-5xl font-black uppercase tracking-tight">Documents</h1>
            <p class="mt-2 text-base text-base-content/70">
              Raw markdown artifacts indexed from the local Buster Claw library.
            </p>
          </div>
          <button class="btn btn-primary" phx-click="index_existing">
            Index Existing
          </button>
        </div>

        <BusterClawWeb.LibraryTabs.tabs active={:documents} />

        <section class="ic-panel p-5">
          <div class="flex items-start justify-between gap-4">
            <div class="min-w-0">
              <h2 class="ic-eyebrow">Library Root</h2>
              <p class="mt-2 break-words font-mono text-sm">{@library_root}</p>
            </div>
            <span class={[
              "rounded-sm border-2 px-2 py-1 font-mono text-xs uppercase tracking-wide",
              if(@library_exists?,
                do: "border-success/40 bg-success/15 text-success",
                else: "border-warning/40 bg-warning/15 text-warning"
              )
            ]}>
              {if @library_exists?, do: "ready", else: "pending"}
            </span>
          </div>
        </section>

        <div
          id="documents-reader"
          class="ic-panel relative min-h-[72vh] overflow-hidden"
        >
          <aside
            id="documents-sidebar"
            class="absolute inset-y-0 left-0 z-10 w-80 max-w-[82vw] border-r border-base-300 bg-base-200/95 shadow-xl backdrop-blur transition-transform duration-200 ease-out [[data-documents-sidebar=closed]_&]:-translate-x-full lg:w-[22rem] lg:max-w-none lg:bg-base-200/40 lg:shadow-none lg:backdrop-blur-none"
          >
            <button
              id="documents-sidebar-bumper"
              type="button"
              title="Toggle document list"
              aria-label="Toggle document list"
              phx-click={JS.dispatch("bc:toggle-documents-sidebar")}
              class="absolute top-4 -right-3 z-20 grid size-7 place-items-center rounded-full border border-base-300 bg-base-100 text-base-content shadow-sm transition hover:border-base-content/30 hover:bg-base-200 focus:outline-none focus:ring-2 focus:ring-base-content/30 [[data-documents-sidebar=closed]_&]:-right-10"
            >
              <.icon
                name="hero-chevron-left"
                class="size-4 [[data-documents-sidebar=closed]_&]:hidden"
              />
              <.icon
                name="hero-chevron-right"
                class="hidden size-4 [[data-documents-sidebar=closed]_&]:block"
              />
            </button>

            <div class="flex items-center justify-between gap-3 border-b-2 border-base-content/20 px-4 py-3">
              <div class="min-w-0">
                <h2 class="ic-eyebrow">Library Inbox</h2>
                <p class="mt-1 font-mono text-xs text-base-content/60">
                  {@documents_count} documents
                </p>
              </div>
              <span class="rounded-sm border-2 border-base-content/25 px-2 py-1 font-mono text-xs uppercase tracking-wide text-base-content/70">
                Raw
              </span>
            </div>

            <div
              id="documents-list"
              class="max-h-[calc(72vh-3.75rem)] divide-y-2 divide-base-content/10 overflow-y-auto"
            >
              <button
                :for={document <- @documents}
                id={"document-list-item-#{document.id}"}
                type="button"
                class={[
                  "block w-full border-l-4 border-transparent px-4 py-4 text-left transition hover:bg-base-200/60",
                  selected_document?(document, @selected_document) &&
                    "border-l-primary bg-base-200/60"
                ]}
                phx-click="open_document"
                phx-value-id={document.id}
              >
                <div class="flex items-start justify-between gap-4">
                  <div class="min-w-0">
                    <h2 class="truncate text-sm font-semibold text-base-content">
                      {document_title(document)}
                    </h2>
                    <p class="mt-1 truncate font-mono text-xs text-base-content/60">
                      {document.artifact_path}
                    </p>
                    <p class="mt-2 line-clamp-2 text-sm text-base-content/70">
                      {document.excerpt || "No preview available."}
                    </p>
                  </div>
                  <span class="shrink-0 rounded-sm border-2 border-base-content/20 px-2 py-1 font-mono text-xs uppercase tracking-wide">
                    {document.status}
                  </span>
                </div>
              </button>

              <div
                :if={@documents == []}
                class="px-4 py-12 text-center font-mono text-xs uppercase tracking-wide text-base-content/60"
              >
                No documents indexed yet.
              </div>
            </div>
          </aside>

          <section
            id="documents-main"
            class="min-w-0 bg-base-100 transition-[padding] duration-200 ease-out lg:pl-[22rem] [[data-documents-sidebar=closed]_&]:lg:pl-0"
          >
            <div :if={@selected_document} class="flex h-full min-h-[72vh] flex-col">
              <header class="border-b-2 border-base-content/20 px-5 py-4">
                <div class="flex flex-col gap-4 xl:flex-row xl:items-start xl:justify-between">
                  <div class="min-w-0">
                    <div class="flex flex-wrap items-center gap-2 font-mono text-xs uppercase tracking-wide text-base-content/60">
                      <span class="rounded-sm border-2 border-base-content/25 px-2 py-1">
                        {@selected_document.status}
                      </span>
                      <span>{document_date(@selected_document)}</span>
                    </div>
                    <h2 class="mt-3 font-display text-2xl font-black uppercase tracking-tight">
                      {document_title(@selected_document)}
                    </h2>
                    <p class="mt-2 break-words font-mono text-xs text-base-content/60">
                      {@selected_document.artifact_path}
                    </p>
                  </div>

                  <div class="flex shrink-0 items-center gap-2">
                    <button
                      type="button"
                      class="rounded-sm border-2 border-base-content/25 px-3 py-2 font-mono text-xs uppercase tracking-wide transition hover:border-primary hover:text-primary"
                      phx-click="close_document"
                    >
                      Clear
                    </button>
                    <button
                      type="button"
                      class="rounded-sm border-2 border-error/50 px-3 py-2 font-mono text-xs uppercase tracking-wide text-error transition hover:bg-error/10"
                      phx-click="delete_document"
                      phx-value-id={@selected_document.id}
                    >
                      Delete Raw Artifact
                    </button>
                  </div>
                </div>

                <div class="mt-4 flex flex-wrap gap-2">
                  <span
                    :for={tag <- document_tags(@selected_document)}
                    class="rounded-sm border-2 border-base-content/15 bg-base-200 px-2 py-1 font-mono text-xs uppercase tracking-wide text-base-content/70"
                  >
                    {tag}
                  </span>
                  <.link
                    :if={@selected_document.source_url}
                    navigate={~p"/browse?#{%{url: @selected_document.source_url}}"}
                    class="rounded-sm border-2 border-base-content/25 px-2 py-1 font-mono text-xs uppercase tracking-wide text-base-content/70 transition hover:border-primary hover:text-primary"
                  >
                    Open Source
                  </.link>
                </div>
              </header>

              <div class="min-h-0 flex-1 overflow-y-auto p-5">
                <article
                  id="document-preview"
                  class="min-h-full whitespace-pre-wrap rounded-sm border-2 border-base-content/20 bg-base-200/70 p-5 font-mono text-sm leading-6 text-base-content/90"
                >
                  {@document_content}
                </article>
              </div>
            </div>

            <div
              :if={!@selected_document}
              class="grid min-h-[72vh] place-items-center p-8 text-center text-sm text-base-content/60"
            >
              <div class="flex flex-col items-center gap-3">
                <div class="grid size-12 place-items-center rounded-sm border-2 border-base-content/25 bg-base-200 text-primary">
                  <.icon name="hero-document-text" class="size-6" />
                </div>
                <h2 class="font-display text-base font-black uppercase tracking-tight text-base-content">
                  No document selected
                </h2>
                <p class="mt-1 font-mono text-xs uppercase tracking-wide">
                  Select a document from the sidebar to preview its markdown body.
                </p>
              </div>
            </div>
          </section>
        </div>
      </section>
    </Layouts.app>
    """
  end

  defp load_documents(socket, opts \\ []) do
    documents = Library.list_documents()

    socket
    |> assign(:documents, documents)
    |> assign(:documents_count, length(documents))
    |> select_loaded_document(documents, opts)
  end

  defp select_loaded_document(socket, documents, opts) do
    selected_id =
      case Keyword.get(opts, :select) do
        :first -> nil
        _ -> socket.assigns[:selected_document] && socket.assigns.selected_document.id
      end

    document =
      if selected_id do
        Enum.find(documents, &(&1.id == selected_id)) || List.first(documents)
      else
        List.first(documents)
      end

    case document do
      nil -> assign(socket, selected_document: nil, document_content: "")
      document -> select_document(socket, document)
    end
  end

  defp select_document(socket, document) do
    content =
      case Library.read_raw_document(document) do
        {:ok, body} ->
          body

        {:error, reason} ->
          "Unable to read document: #{BusterClawWeb.ErrorFormatter.format(reason)}"
      end

    assign(socket, selected_document: document, document_content: content)
  end

  defp document_title(document), do: document.name || document.filename

  defp document_date(%{date: %Date{} = date}), do: Calendar.strftime(date, "%b %-d, %Y")
  defp document_date(_document), do: "No date"

  defp document_tags(%{tags: %{"items" => tags}}), do: reject_blank_tags(tags)
  defp document_tags(_document), do: []

  defp reject_blank_tags(tags) do
    tags
    |> List.wrap()
    |> Enum.reject(&(&1 in [nil, ""]))
  end

  defp selected_document?(document, selected_document) do
    selected_document && document.id == selected_document.id
  end
end
