defmodule BusterClawWeb.GwsPanels do
  @moduledoc """
  Presentation components for the Google Workspace section of the Configuration
  tab (`SettingsLive`): the connected accounts list, the Gmail tools panel, and
  the Google Calendar tools panel.

  Stateless function components — every `phx-submit`/`phx-click` bubbles to the
  parent LiveView, which owns all account/Gmail/Calendar state and event handling.
  The small account-status formatters live here since only these panels use them.
  """
  use BusterClawWeb, :html

  attr :accounts, :list, required: true

  def accounts_panel(assigns) do
    ~H"""
    <section id="gws-accounts" class="rounded-lg border border-base-300 bg-base-100">
      <div class="flex items-center justify-between gap-3 border-b border-base-300 px-4 py-3">
        <h2 class="text-sm font-semibold">{length(@accounts)} accounts</h2>
      </div>

      <div class="divide-y divide-base-300">
        <div
          :for={account <- @accounts}
          id={"gws-account-#{account.id}"}
          class="grid gap-4 px-4 py-4 lg:grid-cols-[minmax(0,1fr)_auto]"
        >
          <div class="min-w-0">
            <div class="flex min-w-0 flex-wrap items-center gap-2">
              <h3 class="truncate text-sm font-semibold">{account.email}</h3>
              <span class={account_enabled_class(account.enabled)}>
                {if account.enabled, do: "enabled", else: "disabled"}
              </span>
              <span class={account_token_class(account.has_refresh_token)}>
                {if account.has_refresh_token, do: "authorized", else: "needs auth"}
              </span>
              <span
                :if={missing_scopes?(account)}
                class="rounded-sm border border-warning/50 bg-warning/15 px-2 py-0.5 text-xs font-semibold text-warning"
              >
                Reconnect required — new permissions available
              </span>
              <span
                :if={account.reconnect_needed}
                class="rounded-sm border border-warning/50 bg-warning/15 px-2 py-0.5 text-xs font-semibold text-warning"
              >
                Reconnect needed — Google session expired
              </span>
            </div>

            <dl class="mt-3 grid gap-2 text-xs text-base-content/60 sm:grid-cols-2">
              <div>
                <dt class="font-semibold uppercase tracking-wide">Client ID</dt>
                <dd class="truncate font-mono">{account.client_id}</dd>
              </div>
              <div>
                <dt class="font-semibold uppercase tracking-wide">Scopes</dt>
                <dd class="truncate font-mono">{account.scopes || "default"}</dd>
              </div>
              <div>
                <dt class="font-semibold uppercase tracking-wide">Default Query</dt>
                <dd class="truncate font-mono">{account.default_query || "newer_than:7d"}</dd>
              </div>
              <div>
                <dt class="font-semibold uppercase tracking-wide">Access Token</dt>
                <dd>{token_expiry_label(account.access_token_expires_at)}</dd>
              </div>
              <div class="sm:col-span-2">
                <dt class="font-semibold uppercase tracking-wide">Health</dt>
                <dd>{self_test_label(account.self_test)}</dd>
              </div>
            </dl>
          </div>

          <div class="flex flex-wrap items-start gap-2 lg:justify-end">
            <button
              class="rounded border border-base-300 px-3 py-2 text-sm"
              phx-click="reconnect"
              phx-value-id={account.id}
            >
              Reconnect
            </button>
            <button
              class="rounded border border-base-300 px-3 py-2 text-sm"
              phx-click="self_test"
              phx-value-id={account.id}
            >
              Self-test
            </button>
            <button
              class="rounded border border-base-300 px-3 py-2 text-sm"
              phx-click="toggle"
              phx-value-id={account.id}
            >
              {if account.enabled, do: "Disable", else: "Enable"}
            </button>
            <button
              class="rounded border border-error/40 px-3 py-2 text-sm text-error"
              phx-click="delete_account"
              phx-value-id={account.id}
            >
              Delete
            </button>
          </div>
        </div>

        <div
          :if={@accounts == []}
          id="gws-empty"
          class="px-4 py-10 text-center text-sm text-base-content/60"
        >
          No Google Workspace accounts connected yet.
        </div>
      </div>
    </section>
    """
  end

  attr :accounts, :list, required: true
  attr :gmail_label_form, :any, required: true
  attr :gmail_search_form, :any, required: true
  attr :gmail_sync_form, :any, required: true
  attr :gmail_labels, :list, required: true
  attr :gmail_search, :any, default: nil
  attr :gmail_search_account_id, :any, default: nil
  attr :gmail_sync, :any, default: nil
  attr :gmail_message, :any, default: nil

  def gmail_panel(assigns) do
    ~H"""
    <section id="gmail-tools" class="rounded-lg border border-base-300 bg-base-100">
      <div class="border-b border-base-300 px-4 py-3">
        <h2 class="text-sm font-semibold">Gmail</h2>
      </div>

      <div class="space-y-5 p-4">
        <div class="grid gap-4 md:grid-cols-3">
          <.form
            for={@gmail_label_form}
            id="gmail-label-form"
            phx-submit="load_gmail_labels"
            class="space-y-3 rounded border border-base-300 p-3"
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

          <.form
            for={@gmail_search_form}
            id="gmail-search-form"
            phx-submit="search_gmail"
            class="space-y-3 rounded border border-base-300 p-3"
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

          <.form
            for={@gmail_sync_form}
            id="gmail-sync-form"
            phx-submit="sync_gmail"
            class="space-y-3 rounded border border-base-300 p-3"
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
        </div>

        <div class="space-y-4">
          <div
            :if={@gmail_labels != []}
            id="gmail-labels"
            class="rounded border border-base-300 p-3"
          >
            <h3 class="text-xs font-semibold uppercase tracking-wide text-base-content/60">
              Labels
            </h3>
            <div class="mt-3 flex flex-wrap gap-2">
              <span
                :for={label <- @gmail_labels}
                class="rounded border border-base-300 px-2 py-1 text-xs"
              >
                {label.name}
              </span>
            </div>
          </div>

          <div
            :if={@gmail_search}
            id="gmail-search-results"
            class="rounded border border-base-300"
          >
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
                  <h3 class="truncate text-sm font-semibold">
                    {message.subject || "(no subject)"}
                  </h3>
                  <p class="mt-1 truncate text-xs text-base-content/60">{message.from}</p>
                  <p class="mt-2 line-clamp-2 text-sm text-base-content/70">
                    {message.snippet}
                  </p>
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
                <h3 class="truncate text-sm font-semibold">
                  {document.name || document.filename}
                </h3>
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

          <article
            :if={@gmail_message}
            id="gmail-selected-message"
            class="rounded border border-base-300 p-4"
          >
            <p class="text-xs font-semibold uppercase tracking-wide text-base-content/60">
              Message
            </p>
            <h3 class="mt-1 text-lg font-semibold">{@gmail_message.subject || "(no subject)"}</h3>
            <p class="mt-1 text-xs text-base-content/60">
              {@gmail_message.from} · {@gmail_message.date}
            </p>
            <pre class="mt-4 whitespace-pre-wrap rounded bg-base-200 p-3 text-sm leading-6">{@gmail_message.body_text}</pre>
          </article>
        </div>
      </div>
    </section>
    """
  end

  attr :accounts, :list, required: true
  attr :calendar_sync_form, :any, required: true
  attr :calendar_sync, :any, default: nil

  def calendar_panel(assigns) do
    ~H"""
    <section id="google-calendar-tools" class="rounded-lg border border-base-300 bg-base-100">
      <div class="border-b border-base-300 px-4 py-3">
        <h2 class="text-sm font-semibold">Google Calendar</h2>
      </div>

      <div class="grid gap-5 p-4 lg:grid-cols-[22rem_minmax(0,1fr)]">
        <.form
          for={@calendar_sync_form}
          id="google-calendar-sync-form"
          phx-submit="sync_google_calendar"
          class="space-y-3 rounded border border-base-300 p-3"
        >
          <.input
            field={@calendar_sync_form[:account_id]}
            id="google-calendar-account-id"
            type="select"
            label="Account"
            options={account_options(@accounts)}
          />
          <.input
            field={@calendar_sync_form[:calendar_id]}
            id="google-calendar-id"
            type="text"
            label="Calendar ID"
          />
          <.input
            field={@calendar_sync_form[:days_ahead]}
            id="google-calendar-days-ahead"
            type="number"
            label="Days Ahead"
            min="1"
            max="365"
          />
          <button
            class="w-full rounded bg-base-content px-3 py-2 text-sm font-semibold text-base-100 transition hover:opacity-85 disabled:opacity-40"
            disabled={@accounts == []}
          >
            Sync Calendar
          </button>
        </.form>

        <div
          :if={@calendar_sync}
          id="google-calendar-sync-results"
          class="rounded border border-base-300"
        >
          <div class="border-b border-base-300 px-3 py-2 text-xs font-semibold uppercase tracking-wide text-base-content/60">
            Imported Events
          </div>
          <div class="divide-y divide-base-300">
            <div
              :for={event <- @calendar_sync.events}
              id={"google-calendar-event-#{event.id}"}
              class="px-3 py-3"
            >
              <h3 class="truncate text-sm font-semibold">{event.title}</h3>
              <p class="mt-1 text-xs text-base-content/60">
                {event.date} {event.start_time && Calendar.strftime(event.start_time, "%H:%M")}
              </p>
            </div>

            <div
              :if={@calendar_sync.events == []}
              class="px-3 py-6 text-center text-sm text-base-content/60"
            >
              No Google Calendar events matched the sync window.
            </div>
          </div>
        </div>
      </div>
    </section>
    """
  end

  defp account_options(accounts), do: Enum.map(accounts, &{&1.email, &1.id})

  defp account_enabled_class(true), do: "rounded bg-success/15 px-2 py-1 text-xs text-success"
  defp account_enabled_class(false), do: "rounded bg-warning/15 px-2 py-1 text-xs text-warning"

  defp account_token_class(true), do: "rounded bg-info/15 px-2 py-1 text-xs text-info"
  defp account_token_class(false), do: "rounded bg-error/15 px-2 py-1 text-xs text-error"

  defp token_expiry_label(nil), do: "not connected"
  defp token_expiry_label(%DateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M UTC")

  # One line per account: "Mail ✓ · Calendar ✓ · Drive ✗ (HTTP 403: ...)".
  # Green checks are the whole point of the post-connect self-test — the
  # failing surface is *named* instead of surfacing later as a mystery.
  defp self_test_label(nil), do: "not yet tested — run Self-test"

  defp self_test_label(%{results: results, at: at}) do
    line =
      Enum.map_join(BusterClaw.Google.SelfTest.surfaces(), " · ", fn surface ->
        name = surface |> Atom.to_string() |> String.capitalize()

        case Map.get(results, Atom.to_string(surface)) do
          "ok" -> "#{name} ✓"
          nil -> "#{name} —"
          error -> "#{name} ✗ (#{error})"
        end
      end)

    if at, do: "#{line} · tested #{at}", else: line
  end

  defp missing_scopes?(account) do
    granted =
      (account.scopes || "")
      |> String.split(~r/\s+/, trim: true)
      |> MapSet.new()

    Enum.any?(BusterClaw.Google.OAuth.default_scopes(), &(not MapSet.member?(granted, &1)))
  end
end
