defmodule BusterClawWeb.StatusLive do
  use BusterClawWeb, :live_view

  alias BusterClaw.Calendar, as: AppCalendar
  alias BusterClaw.Google
  alias BusterClaw.Google.Account, as: GoogleAccount
  alias BusterClaw.Google.Gmail
  alias BusterClaw.Google.OAuth, as: GoogleOAuthCore
  alias BusterClaw.LocalTime
  alias BusterClaw.Runtime.Status
  alias BusterClaw.SystemBrowser
  alias BusterClawWeb.ErrorFormatter
  alias BusterClawWeb.GoogleOAuth

  @google_default_query "newer_than:7d"
  @recent_email_limit 5

  @impl true
  def mount(_params, _session, socket) do
    today = LocalTime.today()

    if connected?(socket) do
      Google.subscribe()
      send(self(), :load_recent_emails)
    end

    {:ok,
     socket
     |> assign(status: Status.snapshot())
     |> assign(:today, today)
     |> assign(:google_auth_url, nil)
     |> assign(:google_note, nil)
     |> assign(:emails, [])
     |> assign(:emails_state, :loading)
     |> assign(:emails_error, nil)
     |> load_google_accounts()
     |> load_daily_events()
     |> assign_google_form()}
  end

  @impl true
  def handle_params(_params, _uri, socket) do
    {:noreply,
     assign(socket,
       current_view: socket.assigns.live_action,
       page_title: page_title(socket.assigns.live_action)
     )}
  end

  @impl true
  def handle_event("validate_google", %{"google_account" => params}, socket) do
    changeset =
      %GoogleAccount{}
      |> GoogleAccount.changeset(put_google_defaults(params))
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :google_form, to_form(changeset, as: :google_account))}
  end

  def handle_event("connect_google", %{"google_account" => params}, socket) do
    case Google.upsert_account(put_google_defaults(params)) do
      {:ok, account} ->
        {:noreply,
         socket
         |> assign(:google_auth_url, GoogleOAuth.authorization_url(account))
         |> assign(:google_note, "Google account saved.")
         |> load_google_accounts()
         |> assign_google_form()}

      {:error, changeset} ->
        {:noreply,
         assign(
           socket,
           :google_form,
           to_form(%{changeset | action: :insert}, as: :google_account)
         )}
    end
  end

  def handle_event("open_google_sign_in", _params, socket) do
    case SystemBrowser.open(socket.assigns.google_auth_url) do
      {:ok, :opened} ->
        {:noreply, assign(socket, :google_note, "Opened Google sign-in in your browser.")}

      {:error, reason} ->
        {:noreply,
         assign(
           socket,
           :google_note,
           "Could not open the browser automatically: #{ErrorFormatter.format(reason)}"
         )}
    end
  end

  @impl true
  def handle_info(:load_recent_emails, socket) do
    {:noreply, load_recent_emails(socket)}
  end

  def handle_info({:google_account_changed, _event, _account}, socket) do
    send(self(), :load_recent_emails)
    {:noreply, load_google_accounts(socket)}
  end

  # Recent emails are fetched live from Gmail for the default connected account.
  defp load_recent_emails(socket) do
    case Google.default_account() do
      nil ->
        assign(socket, emails: [], emails_state: :no_account, emails_error: nil)

      account ->
        query = blank_to_default(account.default_query, @google_default_query)

        case Gmail.search(account, query, limit: @recent_email_limit) do
          {:ok, %{messages: messages}} ->
            assign(socket, emails: messages, emails_state: :ready, emails_error: nil)

          {:error, reason} ->
            assign(socket,
              emails: [],
              emails_state: :error,
              emails_error: ErrorFormatter.format(reason)
            )
        end
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <section class="space-y-8">
        <div class="space-y-2 border-b-2 border-base-content/20 pb-5">
          <p class="ic-eyebrow flex items-center gap-2">
            <span class="ic-dot"></span> {@status.phase}
          </p>
          <h1 class="font-display text-5xl font-black uppercase tracking-tight">Buster Claw</h1>
          <p class="max-w-3xl text-base leading-7 text-base-content/70">
            Local-first research and chat runtime.
          </p>
        </div>

        <.daily_calendar_panel today={@today} events={@daily_events} />

        <.google_workspace_login_panel
          form={@google_form}
          accounts={@google_accounts}
          auth_url={@google_auth_url}
          note={@google_note}
          emails={@emails}
          emails_state={@emails_state}
          emails_error={@emails_error}
        />
      </section>
    </Layouts.app>
    """
  end

  attr :today, Date, required: true
  attr :events, :list, required: true

  defp daily_calendar_panel(assigns) do
    ~H"""
    <section id="home-daily-calendar" class="ic-panel">
      <header class="flex flex-wrap items-center justify-between gap-3 border-b-2 border-base-content/20 px-5 py-4">
        <div>
          <p class="ic-eyebrow">Today's Calendar</p>
          <h2 class="font-display text-2xl font-black uppercase tracking-tight">
            {Elixir.Calendar.strftime(@today, "%A, %B %-d")}
          </h2>
        </div>

        <.link
          navigate={~p"/calendar"}
          class="rounded-sm border-2 border-base-content/25 px-3 py-2 font-mono text-xs uppercase tracking-wide text-base-content/70 transition hover:border-primary hover:text-primary"
        >
          Open Calendar
        </.link>
      </header>

      <div class="p-5">
        <ol :if={@events != []} class="divide-y divide-base-300 rounded border border-base-300">
          <li
            :for={event <- @events}
            id={"home-event-#{event.id}-#{Date.to_iso8601(event.date)}"}
            class="grid gap-3 px-4 py-3 text-sm sm:grid-cols-[7rem_minmax(0,1fr)] sm:items-start"
          >
            <div class="font-mono text-xs font-semibold uppercase tracking-wide text-primary">
              {event_time_label(event)}
            </div>
            <div class="min-w-0">
              <div class="flex min-w-0 items-center gap-2">
                <span class={["size-2.5 shrink-0 rounded-full", event_dot_class(event.color)]} />
                <h3 class="truncate font-semibold">{event.title}</h3>
                <span
                  :if={event.frequency}
                  class="rounded-full bg-base-200 px-2 py-0.5 text-xs font-semibold text-base-content/60"
                >
                  {event.frequency}
                </span>
              </div>
              <p
                :if={event.notes not in [nil, ""]}
                class="mt-1 line-clamp-2 text-sm text-base-content/60"
              >
                {event.notes}
              </p>
            </div>
          </li>
        </ol>

        <div
          :if={@events == []}
          class="rounded border border-dashed border-base-300 px-4 py-10 text-center text-sm text-base-content/60"
        >
          Nothing scheduled today.
        </div>
      </div>
    </section>
    """
  end

  attr :form, :any, required: true
  attr :accounts, :list, required: true
  attr :auth_url, :string, default: nil
  attr :note, :string, default: nil
  attr :emails, :list, required: true
  attr :emails_state, :atom, required: true
  attr :emails_error, :string, default: nil

  defp google_workspace_login_panel(assigns) do
    assigns = assign(assigns, :default_query, @google_default_query)

    ~H"""
    <details
      id="home-google-workspace-login"
      open={@auth_url != nil or @note != nil}
      class="group ic-panel"
    >
      <summary class="flex cursor-pointer list-none items-center justify-between gap-4 px-5 py-4 [&::-webkit-details-marker]:hidden">
        <div class="min-w-0">
          <p class="ic-eyebrow">Google Workspace</p>
          <h2 class="font-display text-lg font-black uppercase tracking-tight">Connect GWS</h2>
          <p class="mt-1 text-sm text-base-content/60">
            Save your desktop OAuth client and finish Google authorization.
          </p>
        </div>
        <span class="grid size-9 shrink-0 place-items-center rounded-sm border-2 border-base-content/25 text-base-content/70 transition group-open:rotate-180 group-open:border-primary group-open:text-primary">
          <.icon name="hero-chevron-down" class="size-4" />
        </span>
      </summary>

      <div class="space-y-5 border-t-2 border-base-content/20 p-5">
        <div class="grid gap-5 lg:grid-cols-[minmax(0,1fr)_18rem]">
          <div class="space-y-4">
            <div class="flex justify-end">
              <.link
                navigate={~p"/gws"}
                class="rounded-sm border-2 border-base-content/25 px-3 py-2 font-mono text-xs uppercase tracking-wide text-base-content/70 transition hover:border-primary hover:text-primary"
              >
                Open GWS
              </.link>
            </div>

            <p
              :if={@note}
              id="google-connect-note"
              class="rounded border border-base-300 bg-base-200/40 px-3 py-2 text-sm"
            >
              {@note}
            </p>

            <.form
              for={@form}
              id="google-account-form"
              phx-change="validate_google"
              phx-submit="connect_google"
              class="grid gap-3 sm:grid-cols-2"
            >
              <input
                type="hidden"
                name="google_account[scopes]"
                value={@form[:scopes].value || GoogleOAuthCore.default_scope_string()}
              />
              <input
                type="hidden"
                name="google_account[default_query]"
                value={@form[:default_query].value || @default_query}
              />

              <.input field={@form[:email]} type="email" label="Google account" />
              <.input field={@form[:client_id]} type="text" label="OAuth client ID" />
              <div class="sm:col-span-2">
                <.input
                  field={@form[:client_secret]}
                  type="password"
                  label="OAuth client secret"
                  autocomplete="off"
                />
              </div>

              <button class="btn btn-primary sm:col-span-2">
                Connect Google
              </button>
            </.form>

            <div
              :if={@auth_url}
              id="google-oauth-next"
              class="flex flex-col gap-3 rounded-sm border-2 border-success/40 bg-success/10 p-4 sm:flex-row sm:items-center sm:justify-between"
            >
              <p class="font-mono text-sm font-semibold uppercase tracking-wide text-success">
                Google sign-in is ready.
              </p>
              <button
                type="button"
                id="google-oauth-link"
                phx-click="open_google_sign_in"
                class="btn btn-primary"
              >
                Open Google Sign-In
              </button>
            </div>

            <div
              :if={@auth_url}
              class="rounded-sm border-2 border-base-content/20 bg-base-100 p-3 text-xs text-base-content/60"
            >
              <label for="google-oauth-url" class="ic-eyebrow">
                Manual URL
              </label>
              <input
                id="google-oauth-url"
                type="text"
                readonly
                value={@auth_url}
                class="mt-2 w-full rounded-sm border-2 border-base-content/20 bg-base-200 px-2 py-1 font-mono text-xs"
              />
            </div>
          </div>

          <aside class="rounded-sm border-2 border-base-content/20">
            <div class="ic-eyebrow border-b-2 border-base-content/20 px-3 py-2">
              GWS accounts
            </div>
            <div class="divide-y-2 divide-base-content/10 text-sm">
              <div :for={account <- @accounts} class="px-3 py-2">
                <div class="truncate font-medium">{account.email}</div>
                <div class="mt-1 flex flex-wrap gap-2 font-mono text-xs uppercase tracking-wide">
                  <span class={google_status_class(account.has_refresh_token)}>
                    {if account.has_refresh_token, do: "connected", else: "pending"}
                  </span>
                  <span class="rounded-sm border-2 border-base-content/20 px-2 py-0.5">
                    {if account.enabled, do: "enabled", else: "disabled"}
                  </span>
                </div>
              </div>
              <div
                :if={@accounts == []}
                class="px-3 py-8 text-center font-mono text-xs uppercase tracking-wide text-base-content/50"
              >
                No GWS accounts yet.
              </div>
            </div>
          </aside>
        </div>

        <section id="home-recent-emails" class="rounded-sm border-2 border-base-content/20">
          <div class="ic-eyebrow border-b-2 border-base-content/20 px-3 py-2">
            Recent emails
          </div>
          <div class="divide-y-2 divide-base-content/10 text-sm">
            <div
              :if={@emails_state == :loading}
              class="px-3 py-6 text-center font-mono text-xs uppercase tracking-wide text-base-content/50"
            >
              Loading recent emails…
            </div>
            <div
              :if={@emails_state == :no_account}
              class="px-3 py-6 text-center font-mono text-xs uppercase tracking-wide text-base-content/50"
            >
              Connect a Google account to see recent emails.
            </div>
            <div :if={@emails_state == :error} class="px-3 py-3 font-mono text-xs text-warning">
              Couldn't load recent emails: {@emails_error}
            </div>
            <%= if @emails_state == :ready do %>
              <div
                :for={email <- @emails}
                class="border-l-2 border-transparent px-3 py-2 transition hover:border-primary hover:bg-base-200/50"
              >
                <div class="truncate font-medium">{email.subject || "(no subject)"}</div>
                <div class="truncate font-mono text-xs text-base-content/60">{email.from}</div>
              </div>
              <div
                :if={@emails == []}
                class="px-3 py-6 text-center font-mono text-xs uppercase tracking-wide text-base-content/50"
              >
                No recent emails.
              </div>
            <% end %>
          </div>
        </section>
      </div>
    </details>
    """
  end

  defp event_time_label(%{start_time: nil}), do: "All day"

  defp event_time_label(%{start_time: start_time, end_time: nil}),
    do: format_event_time(start_time)

  defp event_time_label(%{start_time: start_time, end_time: end_time}),
    do: "#{format_event_time(start_time)}-#{format_event_time(end_time)}"

  defp format_event_time(%Time{} = time), do: Elixir.Calendar.strftime(time, "%H:%M")

  defp event_dot_class(color) do
    case color do
      "work" -> "bg-info"
      "personal" -> "bg-secondary"
      "social" -> "bg-accent"
      "travel" -> "bg-warning"
      "health" -> "bg-success"
      "holiday" -> "bg-error"
      _ -> "bg-base-content/40"
    end
  end

  defp google_status_class(true),
    do: "rounded-sm border-2 border-success/40 bg-success/15 px-2 py-0.5 text-success"

  defp google_status_class(false),
    do: "rounded-sm border-2 border-warning/40 bg-warning/15 px-2 py-0.5 text-warning"

  defp page_title(:home), do: "Home"

  defp page_title(action) do
    action
    |> Atom.to_string()
    |> String.replace("_", " ")
    |> String.split()
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  defp load_google_accounts(socket) do
    assign(socket, :google_accounts, Google.list_account_summaries())
  end

  defp load_daily_events(socket) do
    today = socket.assigns.today

    events =
      today
      |> AppCalendar.events_in_range(today)
      |> Enum.sort_by(&daily_event_sort_key/1)

    assign(socket, :daily_events, events)
  end

  defp daily_event_sort_key(%{start_time: nil}), do: {0, ~T[00:00:00]}
  defp daily_event_sort_key(%{start_time: time}), do: {1, time}

  defp assign_google_form(socket, attrs \\ %{}) do
    changeset =
      %GoogleAccount{}
      |> GoogleAccount.changeset(Map.merge(google_form_defaults(), attrs))

    assign(socket, :google_form, to_form(changeset, as: :google_account))
  end

  defp put_google_defaults(params) do
    params
    |> Map.put(
      "scopes",
      blank_to_default(Map.get(params, "scopes"), GoogleOAuthCore.default_scope_string())
    )
    |> Map.put(
      "default_query",
      blank_to_default(Map.get(params, "default_query"), @google_default_query)
    )
  end

  defp google_form_defaults do
    %{
      "scopes" => GoogleOAuthCore.default_scope_string(),
      "default_query" => @google_default_query,
      "enabled" => true
    }
  end

  defp blank_to_default(nil, default), do: default
  defp blank_to_default("", default), do: default
  defp blank_to_default(value, _default), do: value
end
