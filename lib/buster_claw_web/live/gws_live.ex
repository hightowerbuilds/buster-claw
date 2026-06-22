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

        <BusterClawWeb.GwsPanels.accounts_panel accounts={@accounts} />

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

        <BusterClawWeb.GwsPanels.gmail_panel
          accounts={@accounts}
          gmail_label_form={@gmail_label_form}
          gmail_search_form={@gmail_search_form}
          gmail_sync_form={@gmail_sync_form}
          gmail_labels={@gmail_labels}
          gmail_search={@gmail_search}
          gmail_search_account_id={@gmail_search_account_id}
          gmail_sync={@gmail_sync}
          gmail_message={@gmail_message}
        />

        <BusterClawWeb.GwsPanels.calendar_panel
          accounts={@accounts}
          calendar_sync_form={@calendar_sync_form}
          calendar_sync={@calendar_sync}
        />
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

  defp default_account_id([account | _accounts]), do: account.id
  defp default_account_id([]), do: ""
end
