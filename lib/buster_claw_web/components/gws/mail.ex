defmodule BusterClawWeb.Gws.Mail do
  @moduledoc """
  The three Gmail tool panes of the Google Workspace console: search, labels,
  and sync-to-Library.

  Each was an inline block inside a three-hundred-line `workspace_console/1`
  until 08-08. They are components now, so each declares the assigns it
  actually reads — which is how it became visible that they barely overlap.
  """
  use BusterClawWeb, :html

  import BusterClawWeb.Gws.Shared

  attr :accounts, :list, required: true
  attr :gmail_search_form, :any, required: true
  attr :gmail_search, :any, default: nil
  attr :gmail_search_account_id, :any, default: nil
  attr :gmail_message, :any, default: nil

  def search_pane(assigns) do
    ~H"""
    <.tool_pane title="Search Gmail">
      <:form>
        <.form
          for={@gmail_search_form}
          id="gmail-search-form"
          phx-submit="search_gmail"
          class="space-y-3"
        >
          <.input
            field={@gmail_search_form[:account_id]}
            id="gmail-search-account-id"
            type="select"
            label="Account"
            options={account_options(@accounts)}
          />
          <.input
            field={@gmail_search_form[:query]}
            id="gmail-search-query"
            type="text"
            label="Query"
          />
          <.input
            field={@gmail_search_form[:limit]}
            id="gmail-search-limit"
            type="number"
            label="Limit"
            min="1"
            max="50"
          />
          <button
            class="w-full rounded bg-base-content px-3 py-2 text-sm font-semibold text-base-100 transition hover:opacity-85 disabled:opacity-40"
            disabled={@accounts == []}
          >
            Search Gmail
          </button>
        </.form>
      </:form>

      <div :if={@gmail_search} id="gmail-search-results" class="rounded border border-base-300">
        <div class="border-b border-base-300 px-3 py-2 text-xs font-semibold uppercase tracking-wide text-base-content/60">
          Results
        </div>
        <div class="divide-y divide-base-300">
          <div
            :for={message <- @gmail_search.messages}
            id={"gmail-message-#{message.id}"}
            class="grid gap-3 px-3 py-3 sm:grid-cols-[minmax(0,1fr)_auto]"
          >
            <div class="min-w-0">
              <h3 class="truncate text-sm font-semibold">{message.subject || "(no subject)"}</h3>
              <p class="mt-1 truncate text-xs text-base-content/60">{message.from}</p>
              <p class="mt-2 line-clamp-2 text-sm text-base-content/70">{message.snippet}</p>
            </div>
            <button
              class="rounded border border-base-300 px-3 py-2 text-sm"
              phx-click="read_gmail_message"
              phx-value-account-id={@gmail_search_account_id}
              phx-value-id={message.id}
            >
              Read
            </button>
          </div>
        </div>
      </div>

      <article
        :if={@gmail_message}
        id="gmail-selected-message"
        class="mt-4 rounded border border-base-300 p-4"
      >
        <p class="text-xs font-semibold uppercase tracking-wide text-base-content/60">Message</p>
        <h3 class="mt-1 text-lg font-semibold">{@gmail_message.subject || "(no subject)"}</h3>
        <p class="mt-1 text-xs text-base-content/60">
          {@gmail_message.from} · {@gmail_message.date}
        </p>
        <pre class="mt-4 whitespace-pre-wrap rounded bg-base-200 p-3 text-sm leading-6">{@gmail_message.body_text}</pre>
      </article>

      <p :if={is_nil(@gmail_search)} class="text-sm text-base-content/50">
        Run a search to see matching messages here.
      </p>
    </.tool_pane>
    """
  end

  attr :accounts, :list, required: true
  attr :gmail_label_form, :any, required: true
  attr :gmail_labels, :list, required: true

  def labels_pane(assigns) do
    ~H"""
    <.tool_pane title="Gmail labels">
      <:form>
        <.form
          for={@gmail_label_form}
          id="gmail-label-form"
          phx-submit="load_gmail_labels"
          class="space-y-3"
        >
          <.input
            field={@gmail_label_form[:account_id]}
            id="gmail-label-account-id"
            type="select"
            label="Account"
            options={account_options(@accounts)}
          />
          <button
            class="w-full rounded border border-base-300 px-3 py-2 text-sm font-semibold transition hover:bg-base-200 disabled:opacity-40"
            disabled={@accounts == []}
          >
            Load Labels
          </button>
        </.form>
      </:form>

      <div :if={@gmail_labels != []} id="gmail-labels" class="rounded border border-base-300 p-3">
        <h3 class="text-xs font-semibold uppercase tracking-wide text-base-content/60">Labels</h3>
        <div class="mt-3 flex flex-wrap gap-2">
          <span
            :for={label <- @gmail_labels}
            class="rounded border border-base-300 px-2 py-1 text-xs"
          >
            {label.name}
          </span>
        </div>
      </div>

      <p :if={@gmail_labels == []} class="text-sm text-base-content/50">
        Load an account's labels to list them here.
      </p>
    </.tool_pane>
    """
  end

  attr :accounts, :list, required: true
  attr :gmail_sync_form, :any, required: true
  attr :gmail_sync, :any, default: nil

  def sync_mail_pane(assigns) do
    ~H"""
    <.tool_pane title="Sync mail to Library">
      <:form>
        <.form
          for={@gmail_sync_form}
          id="gmail-sync-form"
          phx-submit="sync_gmail"
          class="space-y-3"
        >
          <.input
            field={@gmail_sync_form[:account_id]}
            id="gmail-sync-account-id"
            type="select"
            label="Account"
            options={account_options(@accounts)}
          />
          <.input
            field={@gmail_sync_form[:query]}
            id="gmail-sync-query"
            type="text"
            label="Sync Query"
          />
          <.input
            field={@gmail_sync_form[:limit]}
            id="gmail-sync-limit"
            type="number"
            label="Sync Limit"
            min="1"
            max="50"
          />
          <button
            class="w-full rounded bg-base-content px-3 py-2 text-sm font-semibold text-base-100 transition hover:opacity-85 disabled:opacity-40"
            disabled={@accounts == []}
          >
            Sync to Library
          </button>
        </.form>
      </:form>

      <div :if={@gmail_sync} id="gmail-sync-results" class="rounded border border-base-300">
        <div class="border-b border-base-300 px-3 py-2 text-xs font-semibold uppercase tracking-wide text-base-content/60">
          Synced Documents
        </div>
        <div class="divide-y divide-base-300">
          <div
            :for={document <- @gmail_sync.documents}
            id={"gmail-synced-document-#{document.id}"}
            class="px-3 py-3"
          >
            <h3 class="truncate text-sm font-semibold">{document.name || document.filename}</h3>
            <p class="mt-1 truncate font-mono text-xs text-base-content/60">
              {document.artifact_path}
            </p>
          </div>

          <div
            :if={@gmail_sync.documents == []}
            class="px-3 py-6 text-center text-sm text-base-content/60"
          >
            No Gmail messages matched the sync query.
          </div>
        </div>
      </div>

      <p :if={is_nil(@gmail_sync)} class="text-sm text-base-content/50">
        Sync a query to file matching messages into the Library.
      </p>
    </.tool_pane>
    """
  end
end
