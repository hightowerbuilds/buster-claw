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
     |> load_documents()}
  end

  @impl true
  def handle_event("index_existing", _params, socket) do
    Library.index_existing_raw_documents()

    {:noreply, load_documents(socket)}
  end

  def handle_event("open_document", %{"id" => id}, socket) do
    document = Library.get_document!(id)

    content =
      case Library.read_raw_document(document) do
        {:ok, body} -> body
        {:error, reason} -> "Unable to read document: #{inspect(reason)}"
      end

    {:noreply, assign(socket, selected_document: document, document_content: content)}
  end

  def handle_event("delete_document", %{"id" => id}, socket) do
    document = Library.get_document!(id)
    _ = Library.delete_raw_document(document)

    {:noreply,
     socket
     |> assign(:selected_document, nil)
     |> assign(:document_content, "")
     |> load_documents()}
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
            <p class="text-sm font-semibold uppercase tracking-wide text-base-content/60">
              Library
            </p>
            <h1 class="text-4xl font-semibold tracking-normal">Documents</h1>
            <p class="mt-2 text-base text-base-content/70">
              Raw markdown artifacts indexed from the local Buster Claw library.
            </p>
          </div>
          <button
            class="rounded bg-base-content px-4 py-2 text-sm font-semibold text-base-100"
            phx-click="index_existing"
          >
            Index Existing
          </button>
        </div>

        <section class="rounded-lg border border-base-300 bg-base-100 p-5">
          <div class="flex items-start justify-between gap-4">
            <div class="min-w-0">
              <h2 class="text-sm font-semibold text-base-content/70">Library Root</h2>
              <p class="mt-2 break-words font-mono text-sm">{@library_root}</p>
            </div>
            <span class={[
              "rounded-full px-2 py-1 text-xs font-semibold",
              if(@library_exists?,
                do: "bg-success/15 text-success",
                else: "bg-warning/15 text-warning"
              )
            ]}>
              {if @library_exists?, do: "ready", else: "pending"}
            </span>
          </div>
        </section>

        <div class="grid gap-6 lg:grid-cols-[minmax(0,1fr)_minmax(320px,480px)]">
          <section class="rounded-lg border border-base-300 bg-base-100">
            <div class="border-b border-base-300 px-4 py-3 text-sm font-semibold">
              {@documents_count} documents
            </div>
            <div class="divide-y divide-base-300">
              <button
                :for={document <- @documents}
                type="button"
                class="block w-full px-4 py-4 text-left hover:bg-base-200"
                phx-click="open_document"
                phx-value-id={document.id}
              >
                <div class="flex items-start justify-between gap-4">
                  <div class="min-w-0">
                    <h2 class="truncate text-sm font-semibold">
                      {document.name || document.filename}
                    </h2>
                    <p class="mt-1 truncate font-mono text-xs text-base-content/60">
                      {document.artifact_path}
                    </p>
                    <p class="mt-2 line-clamp-2 text-sm text-base-content/70">{document.excerpt}</p>
                  </div>
                  <span class="rounded border border-base-300 px-2 py-1 text-xs">
                    {document.status}
                  </span>
                </div>
              </button>

              <div :if={@documents == []} class="px-4 py-10 text-center text-sm text-base-content/60">
                No documents indexed yet.
              </div>
            </div>
          </section>

          <aside class="rounded-lg border border-base-300 bg-base-100">
            <div class="flex items-center justify-between border-b border-base-300 px-4 py-3">
              <h2 class="text-sm font-semibold">Inspector</h2>
              <button
                :if={@selected_document}
                type="button"
                class="text-sm text-base-content/60 hover:text-base-content"
                phx-click="close_document"
              >
                Close
              </button>
            </div>

            <div :if={@selected_document} class="space-y-4 p-4">
              <div>
                <h3 class="font-semibold">
                  {@selected_document.name || @selected_document.filename}
                </h3>
                <p class="mt-1 break-words font-mono text-xs text-base-content/60">
                  {@selected_document.artifact_path}
                </p>
              </div>

              <button
                type="button"
                class="rounded border border-error/40 px-3 py-2 text-sm font-semibold text-error"
                phx-click="delete_document"
                phx-value-id={@selected_document.id}
              >
                Delete Raw Artifact
              </button>

              <article class="max-h-[60vh] overflow-auto whitespace-pre-wrap rounded border border-base-300 bg-base-200 p-4 text-sm leading-6">
                {@document_content}
              </article>
            </div>

            <div :if={!@selected_document} class="p-8 text-center text-sm text-base-content/60">
              Select a document to preview its markdown body.
            </div>
          </aside>
        </div>
      </section>
    </Layouts.app>
    """
  end

  defp load_documents(socket) do
    documents = Library.list_documents()

    socket
    |> assign(:documents, documents)
    |> assign(:documents_count, length(documents))
  end
end
