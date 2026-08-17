defmodule BusterClawWeb.SettingsLive do
  @moduledoc """
  Settings → Configuration sub-tab. The single home for account-level
  configuration: **Google Workspace** (connect, accounts, per-surface health,
  Gmail/Calendar tools), **agent models**, the profile, onboarding progress, and
  the recovery key.

  ## The sub-tab rail (08-15)

  Those are four unrelated features, and until 08-15 they were one scroll with a
  ~378-line `render/1`. They are now a rail:
  `BusterClawWeb.Settings.Registry` is the data-only source the rail, the
  `select_settings_tab` whitelist and the `:if` dispatch below all read, so a
  tab cannot exist in one and not the others — the same shape as Explained's and
  Studio's rails, and the fix the GWS console rail underneath needed on 08-08.

  Only **Agent & models** is extracted so far, into
  `BusterClawWeb.Settings.ModelsComponent`. Google Workspace, the profile and
  the credentials are still inline: a rail with one moved section is a real
  intermediate state, and a half-moved Google Workspace would not be. GWS is the
  next cut and the awkward one — it is 12 of the remaining `handle_event`
  clauses and the only section whose refresh arrives as a `handle_info`, so
  moving it means reaching it with `send_update/2` the way
  `BusterClawWeb.Status.Studio` does.

  The rail does not write the URL; see `BusterClawWeb.Settings.Rail` for why.
  `?tab=` is read at mount so a link or a test can open one directly.

  The model picker sits here rather than on a tab of its own — it is agent
  configuration, and its whole value is being read next to the rest of it. It
  renders `ModelPolicy.in_force/0` per surface, so an operator who set a global
  default and is silently held at the money-surface floor can see that, with the
  reason, on the row where it bites.

  Google Workspace used to live on its own `/gws` sub-tab; it was folded in here
  so "Configuration" owns everything that isn't Appearance / Integrations /
  Security. The connect flow (bundled one-click + the Advanced BYO form on the
  Setup wizard) and the Gmail/Calendar panels are unchanged — reused from
  `BusterClaw.Google` + `BusterClawWeb.GoogleOAuth` + `BusterClawWeb.GwsPanels`.
  """
  use BusterClawWeb, :live_view

  alias BusterClaw.BuildInfo
  alias BusterClaw.Clinch
  alias BusterClaw.Clinch.AppKeys
  alias BusterClaw.Clinch.Rekey
  alias BusterClaw.Google
  alias BusterClaw.Google.CalendarSync
  alias BusterClaw.Google.Gmail
  alias BusterClaw.Google.GmailSync
  alias BusterClaw.Recovery
  alias BusterClaw.Setup
  alias BusterClaw.SystemBrowser
  alias BusterClawWeb.ErrorFormatter
  alias BusterClawWeb.GoogleOAuth
  alias BusterClawWeb.Settings.Registry

  @impl true
  def mount(params, _session, socket) do
    if connected?(socket), do: Google.subscribe()

    {:ok,
     socket
     |> assign(:page_title, "Configuration")
     # The rail. `?tab=` is read but never written — see `Settings.Rail`.
     |> assign(:settings_tab, Registry.resolve(tab_param(params)))
     # --- Google Workspace ---
     |> assign(:bundled_available, BusterClaw.Google.BundledClient.available?())
     |> assign(:gws_tab, :accounts)
     |> assign(:auth_url, nil)
     |> assign(:result, nil)
     |> assign(:gmail_labels, [])
     |> assign(:gmail_search, nil)
     |> assign(:gmail_sync, nil)
     |> assign(:gmail_message, nil)
     |> assign(:calendar_sync, nil)
     |> load_accounts()
     |> assign_gmail_forms()
     |> assign_calendar_form()
     # Agent models own every assign they need — see `Settings.ModelsComponent`.
     # --- profile / onboarding / recovery ---
     |> assign(:profile_name, Setup.profile_name())
     |> assign(:profile_org, Setup.profile_org())
     |> assign(:profile_note, nil)
     # The recovery key is deliberately NOT assigned. It used to be — which put
     # the value that decrypts every other credential into a LiveView payload and
     # a rendered diff. The `RecoveryKey` hook reads it from the Keychain through
     # the desktop shell instead, so it never reaches the server and cannot cross
     # a tunnel (Clinch Phase 2).
     |> assign(:restore_path, Recovery.restore_file_path())
     |> assign(:clinch_entries, Clinch.list())
     |> assign(:app_keys, app_keys())
     |> assign(:unreadable, Rekey.unreadable())
     # --- about ---
     # Both are constant for the life of the VM, so they are read once at mount
     # rather than on every render. See `BusterClaw.BuildInfo` for why they are
     # derived rather than stored.
     |> assign(:build_version, BuildInfo.version())
     |> assign(:build_architecture, BuildInfo.architecture_label())
     |> assign_status()}
  end

  @impl true
  def handle_info({:google_account_changed, _event, _account}, socket) do
    {:noreply, socket |> load_accounts() |> assign_gmail_forms() |> assign_calendar_form()}
  end

  # Ignore any unexpected message shape on the subscribed topic rather than
  # crashing the LiveView with a FunctionClauseError.
  def handle_info(_msg, socket), do: {:noreply, socket}

  # --- The sub-tab rail ---------------------------------------------------

  # `SplitLive` renders this view with `live_render/3`, and a child mounted
  # outside the router is handed the ATOM `:not_mounted_at_router` in place of a
  # params map — `params["tab"]` on that raises. Pattern-matched rather than
  # `Access`ed for exactly that reason.
  defp tab_param(%{"tab" => tab}), do: tab
  defp tab_param(_params), do: nil

  # `Registry.resolve/1` is the whitelist: a forged key lands on the default
  # rather than assigning one no branch renders, which would leave the page
  # blank below the rail.
  @impl true
  def handle_event("select_settings_tab", %{"tab" => tab}, socket) do
    {:noreply, assign(socket, :settings_tab, Registry.resolve(tab))}
  end

  # --- Google Workspace events -------------------------------------------

  def handle_event("gws_tab", %{"tab" => tab}, socket) do
    {:noreply, assign(socket, :gws_tab, gws_tab(tab))}
  end

  def handle_event("reconnect", %{"id" => id}, socket) do
    account = Google.get_account!(id)

    {:noreply,
     socket
     |> assign(:auth_url, GoogleOAuth.authorization_url(account))
     |> assign(:result, "Continue in Google to reconnect #{account.email}.")}
  end

  # One-click connect via the bundled OAuth client: opens the system browser
  # straight away (the whole point is a single click); the auth_url is still
  # assigned so the manual-URL fallback renders if the browser didn't open.
  def handle_event("bundled_connect", _params, socket) do
    case GoogleOAuth.bundled_authorization_url() do
      {:ok, url} ->
        result =
          case SystemBrowser.open(url) do
            {:ok, :opened} ->
              "Continue in Google — pick your account and approve."

            {:error, reason} ->
              "Could not open the browser automatically (#{ErrorFormatter.format(reason)}) — use the manual URL below."
          end

        {:noreply, socket |> assign(:auth_url, url) |> assign(:result, result)}

      {:error, :bundled_client_unavailable} ->
        {:noreply,
         socket
         |> assign(:bundled_available, false)
         |> assign(
           :result,
           "One-click connect isn't available in this build — use Advanced setup to add an account with your own OAuth client."
         )}
    end
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
           "Could not open the browser automatically: #{ErrorFormatter.format(reason)}"
         )}
    end
  end

  # On-demand health check. Runs off-process (three API calls at up to 10s
  # each must not freeze the LiveView); the run broadcasts an account update
  # when it lands, which re-renders the Health row. Honors the same
  # :google_self_test mode switch as the OAuth callback (:disabled in tests).
  def handle_event("self_test", %{"id" => id}, socket) do
    account = Google.get_account!(id)

    case Application.get_env(:buster_claw, :google_self_test, :async) do
      :disabled ->
        :ok

      :sync ->
        BusterClaw.Google.SelfTest.run(account)

      _async ->
        Task.Supervisor.start_child(BusterClaw.SwarmTaskSupervisor, fn ->
          BusterClaw.Google.SelfTest.run(account)
        end)
    end

    {:noreply, assign(socket, :result, "Self-test running for #{account.email}…")}
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

  # --- Profile / onboarding / recovery events ----------------------------

  def handle_event("save_profile", %{"name" => name, "org" => org}, socket) do
    Setup.put_profile(name, org)

    {:noreply,
     socket
     |> assign(:profile_name, String.trim(name))
     |> assign(:profile_org, String.trim(org))
     |> assign(:profile_note, "Saved.")
     |> assign_status()}
  end

  def handle_event("rerun_setup", _params, socket) do
    {:noreply, push_navigate(socket, to: ~p"/setup")}
  end

  # The shell stored or forgot a credential. Re-read the listing — names and
  # metadata only; the value was never here and is not arriving now.
  def handle_event("clinch:changed", _params, socket) do
    {:noreply,
     socket
     |> assign(:clinch_entries, Clinch.list())
     |> assign(:app_keys, app_keys())
     |> assign(:unreadable, Rekey.unreadable())}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} socket={@socket}>
      <section id="settings" class="space-y-6">
        <BusterClawWeb.SettingsTabs.tabs active={:configuration} />
        <BusterClawWeb.Settings.Rail.rail active={@settings_tab} />

        <.live_component
          :if={@settings_tab == "models"}
          module={BusterClawWeb.Settings.ModelsComponent}
          id="settings-models"
        />

        <section :if={@settings_tab == "google"} class="ic-panel space-y-4 p-6">
          <h2 class="ic-eyebrow">Google Workspace</h2>
          <p class="max-w-2xl text-sm text-base-content/70">
            Connect the Google account Buster Claw works on your behalf — Gmail,
            Calendar, Drive and the rest. Manage accounts, check their health, and
            pull mail/events into the Library here.
          </p>

          <div class="flex flex-wrap items-center gap-3">
            <button
              :if={@bundled_available}
              type="button"
              id="gws-bundled-connect"
              phx-click="bundled_connect"
              class="inline-block rounded bg-base-content px-4 py-2 text-sm font-semibold text-base-100 transition hover:opacity-85"
            >
              Connect Google
            </button>
            <.link
              navigate={~p"/setup"}
              class={[
                "inline-block rounded px-4 py-2 text-sm font-semibold transition",
                if(@bundled_available,
                  do: "border border-base-300 text-base-content/70 hover:text-base-content",
                  else: "bg-base-content text-base-100 hover:opacity-85"
                )
              ]}
            >
              {if @bundled_available, do: "Advanced setup", else: "Connect Account"}
            </.link>
          </div>

          <p
            :if={@bundled_available and GoogleOAuth.beta_testing?()}
            class="max-w-2xl text-xs leading-5 text-base-content/60"
          >
            Beta: Google limits this app to approved testers right now.
            <a href={GoogleOAuth.beta_request_mailto()} class="underline hover:text-base-content">
              Request access
            </a>
            with the Gmail address you'll connect — and expect Google to ask you to
            reconnect about once a week until verification completes.
          </p>

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

          <BusterClawWeb.GwsPanels.workspace_console
            active_tab={@gws_tab}
            accounts={@accounts}
            gmail_label_form={@gmail_label_form}
            gmail_search_form={@gmail_search_form}
            gmail_sync_form={@gmail_sync_form}
            gmail_labels={@gmail_labels}
            gmail_search={@gmail_search}
            gmail_search_account_id={@gmail_search_account_id}
            gmail_sync={@gmail_sync}
            gmail_message={@gmail_message}
            calendar_sync_form={@calendar_sync_form}
            calendar_sync={@calendar_sync}
          />
        </section>

        <section :if={@settings_tab == "profile"} class="ic-panel space-y-4 p-6">
          <h2 class="ic-eyebrow">Profile</h2>
          <form phx-submit="save_profile" class="grid gap-3 sm:grid-cols-2">
            <label class="block">
              <span class="ic-eyebrow">Your name</span>
              <input
                type="text"
                name="name"
                value={@profile_name}
                autocomplete="off"
                placeholder="Ada Lovelace"
                class="input mt-1 w-full"
              />
            </label>
            <label class="block">
              <span class="ic-eyebrow">Organization</span>
              <input
                type="text"
                name="org"
                value={@profile_org}
                autocomplete="off"
                placeholder="Analytical Engines Ltd."
                class="input mt-1 w-full"
              />
            </label>
            <button type="submit" class={["sm:col-span-2 sm:justify-self-start", button_outline()]}>
              Save profile
            </button>
          </form>
          <p
            :if={@profile_note}
            class="rounded-sm border-2 border-primary/40 bg-primary/10 px-3 py-2 text-sm"
          >
            {@profile_note}
          </p>
        </section>

        <section :if={@settings_tab == "profile"} class="ic-panel space-y-4 p-6">
          <div class="flex items-center justify-between gap-4">
            <h2 class="ic-eyebrow">Setup progress</h2>
            <span class="font-mono text-xs text-base-content/60">
              {@status.completed} of {@status.total} complete
            </span>
          </div>
          <ul class="space-y-2 text-sm">
            <li :for={s <- @status.steps} class="flex items-center gap-2">
              <.icon
                name={if s.complete, do: "hero-check-circle-solid", else: "hero-minus-circle"}
                class={[
                  "size-5 shrink-0",
                  if(s.complete, do: "text-success", else: "text-base-content/40")
                ]}
              />
              <span class={if s.complete, do: "", else: "text-base-content/60"}>{s.label}</span>
            </li>
          </ul>
          <button type="button" phx-click="rerun_setup" class={button_outline()}>
            {if @status.complete?, do: "Re-run setup wizard", else: "Finish setup"}
          </button>
        </section>

        <div :if={@settings_tab == "credentials"} class="space-y-6">
          <BusterClawWeb.ClinchPanels.app_keys_panel app_keys={@app_keys} />
          <BusterClawWeb.ClinchPanels.clinch_panel
            entries={@clinch_entries}
            unreadable={@unreadable}
          />
          <BusterClawWeb.ClinchPanels.recovery_panel restore_path={@restore_path} />
        </div>

        <section :if={@settings_tab == "about"} class="ic-panel space-y-4 p-6">
          <h2 class="ic-eyebrow">About</h2>
          <dl class="grid gap-3 sm:grid-cols-2">
            <div>
              <dt class="ic-eyebrow">Version</dt>
              <dd class="mt-1 font-mono text-lg">{@build_version}</dd>
            </div>
            <div>
              <dt class="ic-eyebrow">Build</dt>
              <dd class="mt-1 font-mono text-lg">{@build_architecture}</dd>
            </div>
          </dl>
          <p class="text-sm text-base-content/60">
            Buster Claw ships one build per processor architecture — never a universal
            binary. Quote both lines when reporting a problem.
          </p>
        </section>
      </section>
    </Layouts.app>
    """
  end

  # --- Google Workspace helpers ------------------------------------------

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

  # Map the phx-value-tab string to a known console tab atom (any unknown value
  # falls back to Accounts rather than minting an atom or crashing).
  #
  # Derived from `GwsPanels.console_tab_keys/0` rather than retyped. It used to
  # be a second hand-written list, which is the exact shape of the bug that
  # shipped Phone as a home tab the rail offered and the guard had never heard
  # of: the console would have rendered a rail button for a sixth tab and then
  # silently fallen back to Accounts when it was clicked.
  #
  # Read at runtime rather than into a module attribute: an attribute would add
  # a compile-time edge to the component for a five-element list this is never
  # hot enough to care about.
  defp gws_tab(tab) do
    Enum.find(BusterClawWeb.GwsPanels.console_tab_keys(), :accounts, &(Atom.to_string(&1) == tab))
  end

  # --- shared ------------------------------------------------------------

  defp assign_status(socket), do: assign(socket, :status, Setup.status())

  # The service-credential rows, grouped for the panel. `source/1` is read here
  # rather than in the component so the template stays free of storage lookups —
  # and so a refresh after `clinch:changed` genuinely re-reads where each value is
  # coming from, which is the column the panel exists to show.
  defp app_keys do
    AppKeys.all()
    |> Enum.map(&Map.put(&1, :source, AppKeys.source(&1.name)))
    |> Enum.group_by(& &1.group)
    |> Enum.sort_by(fn {group, _keys} -> group end)
  end

  defp button_outline,
    do:
      "rounded border-2 border-base-content/30 px-4 py-2 text-sm font-semibold transition hover:bg-base-200"
end
