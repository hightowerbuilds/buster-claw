defmodule BusterClawWeb.GWSLive do
  use BusterClawWeb, :live_view

  alias BusterClaw.Google
  alias BusterClaw.Google.CalendarSync
  alias BusterClaw.Google.Gmail
  alias BusterClaw.Google.GmailSync
  alias BusterClaw.SystemBrowser
  alias BusterClawWeb.ErrorFormatter
  alias BusterClawWeb.GoogleOAuth

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Google.subscribe()

    {:ok,
     socket
     |> assign(:page_title, "GWS")
     |> assign(:auth_url, nil)
     |> assign(:result, nil)
     |> assign(:gmail_labels, [])
     |> assign(:gmail_search, nil)
     |> assign(:gmail_sync, nil)
     |> assign(:gmail_message, nil)
     |> assign(:calendar_sync, nil)
     |> load_accounts()
     |> assign_gmail_forms()
     |> assign_calendar_form()}
  end

  @impl true
  def handle_info({:google_account_changed, _event, _account}, socket) do
    {:noreply, socket |> load_accounts() |> assign_gmail_forms() |> assign_calendar_form()}
  end

  @impl true
  def handle_event("reconnect", %{"id" => id}, socket) do
    account = Google.get_account!(id)

    {:noreply,
     socket
     |> assign(:auth_url, GoogleOAuth.authorization_url(account))
     |> assign(:result, "Continue in Google to reconnect #{account.email}.")}
  end

  def handle_event("open_google_sign_in", _params, socket) do
    case SystemBrowser.open(socket.assigns.auth_url) do
      {:ok, :opened} ->
        {:noreply, assign(socket, :result, "Opened Google sign-in in your browser.")}

      {:error, reason} ->
        {:noreply,
         assign(
           socket,
           :result,
           "Could not open the browser automatically: #{BusterClawWeb.ErrorFormatter.format(reason)}"
         )}
    end
  end

  def handle_event("toggle", %{"id" => id}, socket) do
    account = Google.get_account!(id)
    {:ok, _account} = Google.update_account(account, %{"enabled" => !account.enabled})

    {:noreply,
     socket
     |> assign(:result, "Updated #{account.email}.")
     |> load_accounts()
     |> assign_gmail_forms()
     |> assign_calendar_form()}
  end

  def handle_event("delete_account", %{"id" => id}, socket) do
    account = Google.get_account!(id)
    {:ok, _account} = Google.delete_account(account)

    {:noreply,
     socket
     |> assign(:auth_url, nil)
     |> assign(:result, "Deleted #{account.email}.")
     |> load_accounts()
     |> assign_gmail_forms()
     |> assign_calendar_form()}
  end

  def handle_event("load_gmail_labels", %{"gmail" => params}, socket) do
    with {:ok, account} <- account_from_params(params),
         {:ok, labels} <- Gmail.labels(account) do
      {:noreply,
       socket
       |> assign_gmail_forms(params)
       |> assign(:gmail_labels, labels)
       |> assign(:result, "Loaded #{length(labels)} Gmail labels.")}
    else
      {:error, reason} ->
        {:noreply, assign(socket, :result, ErrorFormatter.format(reason))}
    end
  end

  def handle_event("search_gmail", %{"gmail" => params}, socket) do
    with {:ok, account} <- account_from_params(params),
         {:ok, result} <-
           Gmail.search(account, Map.get(params, "query", ""),
             limit: Map.get(params, "limit", 10)
           ) do
      {:noreply,
       socket
       |> assign_gmail_forms(params)
       |> assign(:gmail_search, result)
       |> assign(:gmail_search_account_id, account.id)
       |> assign(:gmail_message, nil)
       |> assign(:result, "Found #{length(result.messages)} Gmail messages.")}
    else
      {:error, reason} ->
        {:noreply, assign(socket, :result, ErrorFormatter.format(reason))}
    end
  end

  def handle_event("read_gmail_message", %{"account-id" => account_id, "id" => id}, socket) do
    with {:ok, account} <- account_from_params(%{"account_id" => account_id}),
         {:ok, message} <- Gmail.read(account, id) do
      {:noreply,
       socket
       |> assign(:gmail_message, message)
       |> assign(:result, "Loaded Gmail message.")}
    else
      {:error, reason} ->
        {:noreply, assign(socket, :result, ErrorFormatter.format(reason))}
    end
  end

  def handle_event("sync_gmail", %{"gmail" => params}, socket) do
    with {:ok, account} <- account_from_params(params),
         {:ok, result} <-
           GmailSync.sync(account,
             query: Map.get(params, "query", ""),
             limit: Map.get(params, "limit", 10)
           ) do
      {:noreply,
       socket
       |> load_accounts()
       |> assign_gmail_forms(params)
       |> assign(:gmail_sync, result)
       |> assign(:result, "Synced #{result.synced} Gmail messages into Library.")}
    else
      {:error, reason} ->
        {:noreply, assign(socket, :result, ErrorFormatter.format(reason))}
    end
  end

  def handle_event("sync_google_calendar", %{"google_calendar" => params}, socket) do
    with {:ok, account} <- account_from_params(params),
         {:ok, result} <-
           CalendarSync.sync(account,
             calendar_id: Map.get(params, "calendar_id", "primary"),
             days_ahead: Map.get(params, "days_ahead", "90")
           ) do
      {:noreply,
       socket
       |> load_accounts()
       |> assign_calendar_form(params)
       |> assign(:calendar_sync, result)
       |> assign(
         :result,
         "Synced #{result.imported} Google Calendar events into Calendar."
       )}
    else
      {:error, reason} ->
        {:noreply, assign(socket, :result, ErrorFormatter.format(reason))}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <section class="space-y-6">
        <BusterClawWeb.SettingsTabs.tabs active={:gws} />

        <div>
          <.link
            navigate={~p"/"}
            class="inline-block rounded bg-base-content px-4 py-2 text-sm font-semibold text-base-100 transition hover:opacity-85"
          >
            Connect Account
          </.link>
        </div>

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

        <p
          :if={@result}
          id="gws-result"
          class="rounded border border-base-300 bg-base-100 px-4 py-3 text-sm"
        >
          {@result}
        </p>

        <div
          :if={@auth_url}
          id="gws-oauth-next"
          class="flex flex-col gap-3 rounded-lg border border-success/30 bg-success/10 p-4 sm:flex-row sm:items-center sm:justify-between"
        >
          <div>
            <p class="text-sm font-semibold text-success">Google sign-in is ready.</p>
            <p class="mt-1 text-sm text-base-content/70">
              Finish the authorization in your browser, then return here.
            </p>
          </div>
          <button
            type="button"
            id="gws-oauth-link"
            phx-click="open_google_sign_in"
            class="rounded bg-base-content px-4 py-2 text-center text-sm font-semibold text-base-100 transition hover:opacity-85"
          >
            Open Google Sign-In
          </button>
        </div>

        <div
          :if={@auth_url}
          class="rounded border border-base-300 bg-base-100 p-3 text-xs text-base-content/60"
        >
          <label for="gws-oauth-url" class="font-semibold uppercase tracking-wide">
            Manual URL
          </label>
          <input
            id="gws-oauth-url"
            type="text"
            readonly
            value={@auth_url}
            class="mt-2 w-full rounded border border-base-300 bg-base-200 px-2 py-1 font-mono text-xs"
          />
        </div>

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
      </section>
    </Layouts.app>
    """
  end

  defp load_accounts(socket) do
    assign(socket, :accounts, Google.list_account_summaries())
  end

  defp assign_gmail_forms(socket, params \\ %{}) do
    account_id = Map.get(params, "account_id") || default_account_id(socket.assigns.accounts)

    socket
    |> assign(:gmail_label_form, to_form(%{"account_id" => account_id}, as: :gmail))
    |> assign(
      :gmail_search_form,
      to_form(
        %{
          "account_id" => account_id,
          "query" => Map.get(params, "query", "newer_than:7d"),
          "limit" => Map.get(params, "limit", "5")
        },
        as: :gmail
      )
    )
    |> assign(
      :gmail_sync_form,
      to_form(
        %{
          "account_id" => account_id,
          "query" => Map.get(params, "query", "newer_than:7d"),
          "limit" => Map.get(params, "limit", "5")
        },
        as: :gmail
      )
    )
    |> assign(:gmail_search_account_id, account_id)
  end

  defp assign_calendar_form(socket, params \\ %{}) do
    account_id = Map.get(params, "account_id") || default_account_id(socket.assigns.accounts)

    assign(
      socket,
      :calendar_sync_form,
      to_form(
        %{
          "account_id" => account_id,
          "calendar_id" => Map.get(params, "calendar_id", "primary"),
          "days_ahead" => Map.get(params, "days_ahead", "90")
        },
        as: :google_calendar
      )
    )
  end

  defp account_from_params(params) do
    account_id = Map.get(params, "account_id")

    cond do
      account_id not in [nil, ""] ->
        {:ok, Google.get_account!(account_id)}

      account = Google.default_account() ->
        {:ok, account}

      true ->
        {:error, :no_google_account}
    end
  rescue
    Ecto.NoResultsError -> {:error, :not_found}
    Ecto.Query.CastError -> {:error, :not_found}
  end

  defp account_options(accounts), do: Enum.map(accounts, &{&1.email, &1.id})

  defp default_account_id([account | _accounts]), do: account.id
  defp default_account_id([]), do: ""

  defp account_enabled_class(true), do: "rounded bg-success/15 px-2 py-1 text-xs text-success"
  defp account_enabled_class(false), do: "rounded bg-warning/15 px-2 py-1 text-xs text-warning"

  defp account_token_class(true), do: "rounded bg-info/15 px-2 py-1 text-xs text-info"
  defp account_token_class(false), do: "rounded bg-error/15 px-2 py-1 text-xs text-error"

  defp token_expiry_label(nil), do: "not connected"
  defp token_expiry_label(%DateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M UTC")
end
