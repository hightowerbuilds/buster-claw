defmodule BusterClawWeb.SettingsLive do
  @moduledoc """
  Settings → Configuration sub-tab. The single home for account-level
  configuration: **Google Workspace** (connect, accounts, per-surface health,
  Gmail/Calendar tools), **agent models**, the profile, onboarding progress, and
  the recovery key.

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

  alias BusterClaw.AgentBackend
  alias BusterClaw.Google
  alias BusterClaw.Google.CalendarSync
  alias BusterClaw.Google.Gmail
  alias BusterClaw.Google.GmailSync
  alias BusterClaw.ModelPolicy
  alias BusterClaw.Recovery
  alias BusterClaw.Setup
  alias BusterClaw.SystemBrowser
  alias BusterClawWeb.ErrorFormatter
  alias BusterClawWeb.GoogleOAuth

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Google.subscribe()

    {:ok,
     socket
     |> assign(:page_title, "Configuration")
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
     # --- agent models ---
     |> assign(:backend_choices, ModelPolicy.backends())
     # A harness that is not installed is shown DISABLED rather than hidden:
     # hiding it makes the app look like it does not support codex at all, and
     # offering it live would fail at the moment a run was expected.
     |> assign(:backend_installed, AgentBackend.installed())
     |> assign(:model_note, nil)
     |> assign_model_policy()
     # --- profile / onboarding / recovery ---
     |> assign(:profile_name, Setup.profile_name())
     |> assign(:profile_org, Setup.profile_org())
     |> assign(:profile_note, nil)
     |> assign(:recovery_key, Recovery.recovery_key())
     |> assign(:recovery_revealed, false)
     |> assign(:restore_path, Recovery.restore_file_path())
     |> assign_status()}
  end

  @impl true
  def handle_info({:google_account_changed, _event, _account}, socket) do
    {:noreply, socket |> load_accounts() |> assign_gmail_forms() |> assign_calendar_form()}
  end

  # Ignore any unexpected message shape on the subscribed topic rather than
  # crashing the LiveView with a FunctionClauseError.
  def handle_info(_msg, socket), do: {:noreply, socket}

  # --- Google Workspace events -------------------------------------------

  @impl true
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

  # --- Agent model events ------------------------------------------------

  # The pickers: an empty selection clears back to unset/inherit, which is the
  # shipped state — no `--model` flag reaches the CLI at all.
  def handle_event("model_default", %{"model" => model}, socket) do
    {:noreply, put_model(socket, :default, blank_to_nil(model))}
  end

  def handle_event("model_default_backend", %{"backend" => backend}, socket) do
    ModelPolicy.put_backend(:default, parse_backend_choice(backend))
    {:noreply, assign_model_policy(socket)}
  end

  def handle_event("model_backend", %{"surface" => surface, "backend" => backend}, socket) do
    ModelPolicy.put_backend(model_target(surface), parse_backend_choice(backend))
    {:noreply, assign_model_policy(socket)}
  end

  def handle_event("model_surface", %{"surface" => surface, "model" => model}, socket) do
    {:noreply, put_model(socket, model_target(surface), blank_to_nil(model))}
  end

  # The escape hatch. The CLI takes aliases and models newer than our list, so a
  # typed string goes straight to `ModelPolicy.put/2` — which validates it, and
  # refuses blank rather than reading it as "clear" (clearing is the picker's
  # job, and a blank that silently unset the default would be a nasty surprise).
  def handle_event("model_custom", %{"target" => target, "model" => model}, socket) do
    {:noreply, put_model(socket, model_target(target), String.trim(model))}
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

  def handle_event("toggle_recovery", _params, socket) do
    {:noreply, update(socket, :recovery_revealed, &(not &1))}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} socket={@socket}>
      <section id="settings" class="space-y-6">
        <BusterClawWeb.SettingsTabs.tabs active={:configuration} />

        <section class="ic-panel space-y-4 p-6">
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

        <section class="ic-panel space-y-4 p-6">
          <h2 class="ic-eyebrow">Agent harness &amp; models</h2>
          <p class="max-w-2xl text-sm text-base-content/70">
            Buster Claw drives your own agent CLI. Pick the <strong>harness</strong>
            first — a model name only means something inside its own harness — then
            the model within it. Left unset it passes no <code class="font-mono">--model</code>
            flag and detects the CLI itself, exactly as it always has. Your models
            are remembered per harness, so switching and switching back loses
            nothing.
          </p>

          <form id="model-default-backend-form" phx-change="model_default_backend">
            <label class="block max-w-sm">
              <span class="ic-eyebrow">Global harness</span>
              <select
                name="backend"
                aria-label="Global default harness"
                class="select select-bordered mt-1 w-full font-mono text-xs"
              >
                <option value="auto" selected={is_nil(@model_default_backend)}>
                  — auto — whichever CLI is found
                </option>
                <option
                  :for={backend <- @backend_choices}
                  value={backend}
                  selected={@model_default_backend == backend}
                  disabled={backend not in @backend_installed}
                >
                  {backend_label(backend, backend in @backend_installed)}
                </option>
              </select>
            </label>
          </form>

          <div class="grid gap-4 sm:grid-cols-2">
            <form id="model-default-form" phx-change="model_default">
              <label class="block">
                <span class="ic-eyebrow">
                  Global default model · {backend_display(@model_default_backend)}
                </span>
                <select
                  name="model"
                  aria-label="Global default model"
                  class="select select-bordered mt-1 w-full font-mono text-xs"
                >
                  <option value="" selected={is_nil(@model_default)}>
                    Unset — your {backend_display(@model_default_backend)} CLI decides
                  </option>
                  <option
                    :for={model <- @model_choices}
                    value={model}
                    selected={@model_default == model}
                  >
                    {model}
                  </option>
                  <option
                    :if={@model_default && @model_default not in @model_choices}
                    value={@model_default}
                    selected
                  >
                    {@model_default}
                  </option>
                </select>
              </label>
              <p :if={@model_choices == []} class="pt-1 text-xs leading-5 text-base-content/60">
                {backend_display(@model_default_backend)} cannot list its own models from here, so there is nothing to pick —
                type the model beside this instead. A name only means something to
                its own harness: OpenCode wants <code>provider/model</code>.
              </p>
            </form>

            <form id="model-custom-form" phx-submit="model_custom" class="space-y-2">
              <label class="block">
                <span class="ic-eyebrow">Any other model</span>
                <input
                  type="text"
                  name="model"
                  value=""
                  autocomplete="off"
                  placeholder="claude-sonnet-4-6"
                  class="input mt-1 w-full font-mono text-xs"
                />
              </label>
              <div class="flex flex-wrap items-center gap-2">
                <select
                  name="target"
                  aria-label="Where the typed model applies"
                  class="select select-bordered select-sm min-w-0 flex-1 text-xs"
                >
                  <option value="default">Global default</option>
                  <option :for={{surface, _entry} <- @model_rows} value={surface}>
                    {surface_label(surface)}
                  </option>
                </select>
                <button type="submit" class={button_outline()}>Set</button>
              </div>
              <p class="text-xs leading-5 text-base-content/60">
                The CLI accepts aliases and models newer than the list above, so
                anything non-blank is accepted here.
              </p>
            </form>
          </div>

          <p
            :if={@model_note}
            id="model-note"
            class="rounded-sm border-2 border-primary/40 bg-primary/10 px-3 py-2 text-sm"
          >
            {@model_note}
          </p>

          <div class="border-t-2 border-base-content/20 pt-2">
            <p class="ic-eyebrow py-2">In force, per surface</p>
            <div class="divide-y divide-base-300">
              <div
                :for={{surface, entry} <- @model_rows}
                class="flex flex-wrap items-start justify-between gap-4 py-4"
              >
                <div class="max-w-md min-w-0 space-y-1">
                  <p class="text-sm font-semibold">{entry.description}</p>
                  <p class="font-mono text-xs text-base-content/70">
                    {backend_display(entry.backend)} · {model_display(entry.model)} · {source_note(
                      entry.source
                    )}
                  </p>
                  <p
                    :if={entry.floor && entry.floor_applies}
                    class="border-l-2 border-primary/60 pl-3 text-xs leading-5 text-base-content/60"
                  >
                    Floor: {entry.floor}. A cheaper model on this surface was measured
                    inventing a financial answer instead of reporting a problem, so the
                    global default cannot lower it. Naming this surface here still can.
                  </p>
                  <p
                    :if={ModelPolicy.claude_only?(surface)}
                    class="border-l-2 border-base-content/30 pl-3 text-xs leading-5 text-base-content/60"
                  >
                    Claude only. This surface's Robinhood confinement is written in
                    Claude's flags, which the other harnesses reject outright — so
                    there is no harness to choose here rather than a choice that
                    would fail.
                  </p>
                </div>

                <form
                  :if={!ModelPolicy.claude_only?(surface)}
                  id={"model-backend-#{surface}"}
                  phx-change="model_backend"
                  class="shrink-0"
                >
                  <input type="hidden" name="surface" value={surface} />
                  <select
                    name="backend"
                    aria-label={"Harness for #{surface_label(surface)}"}
                    class="select select-bordered select-sm min-w-40 font-mono text-xs"
                  >
                    <option value="auto" selected={entry.backend_source == :auto}>
                      — auto —
                    </option>
                    <option
                      :for={backend <- @backend_choices}
                      value={backend}
                      selected={entry.backend_source != :auto and entry.backend == backend}
                      disabled={backend not in @backend_installed}
                    >
                      {backend_label(backend, backend in @backend_installed)}
                    </option>
                  </select>
                </form>

                <form id={"model-surface-#{surface}"} phx-change="model_surface" class="shrink-0">
                  <input type="hidden" name="surface" value={surface} />
                  <select
                    name="model"
                    aria-label={"Model for #{surface_label(surface)}"}
                    class="select select-bordered select-sm min-w-56 font-mono text-xs"
                  >
                    <option value="" selected={entry.source != :surface}>— inherit —</option>
                    <option
                      :for={model <- @model_choices}
                      value={model}
                      selected={entry.source == :surface and entry.model == model}
                    >
                      {model}
                    </option>
                    <option
                      :if={entry.source == :surface and entry.model not in @model_choices}
                      value={entry.model}
                      selected
                    >
                      {entry.model}
                    </option>
                  </select>
                </form>
              </div>
            </div>
          </div>
        </section>

        <section class="ic-panel space-y-4 p-6">
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

        <section class="ic-panel space-y-4 p-6">
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

        <section class="ic-panel space-y-4 p-6">
          <h2 class="ic-eyebrow">Recovery key</h2>
          <p class="text-sm text-base-content/70">
            This key encrypts every credential Buster Claw stores — Google tokens,
            integration secrets. It lives in your system keychain. Back it up to
            move Buster Claw to another machine; anyone with it can decrypt your
            data, so keep it somewhere safe.
          </p>
          <div :if={@recovery_key} class="space-y-3">
            <button type="button" phx-click="toggle_recovery" class={button_outline()}>
              {if @recovery_revealed, do: "Hide key", else: "Reveal key"}
            </button>
            <div :if={@recovery_revealed} class="space-y-3">
              <input
                type="text"
                readonly
                value={@recovery_key}
                aria-label="Recovery key"
                class="input w-full font-mono text-xs"
              />
              <p class="text-xs text-base-content/60">
                To restore on a new machine: save this value, then before first
                launch create a file named <code class="font-mono">RESTORE_SECRET_KEY</code>
                containing it at <code class="break-all font-mono">{@restore_path}</code>.
              </p>
            </div>
          </div>
          <p :if={is_nil(@recovery_key)} class="text-sm text-base-content/60">
            No recovery key is configured in this environment.
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
  defp gws_tab("search"), do: :search
  defp gws_tab("labels"), do: :labels
  defp gws_tab("sync_mail"), do: :sync_mail
  defp gws_tab("calendar"), do: :calendar
  defp gws_tab(_), do: :accounts

  # --- Agent model helpers -----------------------------------------------

  # `in_force/0` is a map; the rows are materialized in `surface_keys/0` order
  # so the list is stable between renders instead of following map term order.
  defp assign_model_policy(socket) do
    in_force = ModelPolicy.in_force()

    # Models are stored per `{backend, surface}` since 08-03, so the global
    # default shown here is the one for the harness the default surface resolves
    # to — showing claude's default while running codex would be a lie.
    default_backend = ModelPolicy.backend_for(:default)

    socket
    |> assign(:model_default_backend, default_backend)
    # The offered models follow the CHOSEN harness, not claude forever. Resolved
    # here rather than at mount for that reason: a list that never changes would
    # have offered claude model IDs to an operator running opencode, which is the
    # one mistake `plausible_model?/2` exists to catch.
    |> assign(:model_choices, ModelPolicy.known_models(default_backend))
    |> assign(:model_rows, Enum.map(ModelPolicy.surface_keys(), &{&1, Map.fetch!(in_force, &1)}))
    |> assign(:model_default, ModelPolicy.model_for(default_backend, :default))
  end

  # "auto" is a real choice — it hands the harness back to PATH detection — so it
  # maps to nil rather than being treated as "nothing selected".
  defp parse_backend_choice("auto"), do: nil

  defp parse_backend_choice(given),
    do: Enum.find(ModelPolicy.backends(), &(Atom.to_string(&1) == given))

  defp backend_display(nil), do: "auto"
  defp backend_display(backend), do: Atom.to_string(backend)

  defp backend_label(backend, true), do: Atom.to_string(backend)
  defp backend_label(backend, false), do: Atom.to_string(backend) <> " (not installed)"

  defp put_model(socket, target, model) do
    case ModelPolicy.put(target, model) do
      {:ok, in_force} ->
        socket
        |> assign_model_policy()
        |> assign(:model_note, model_note(target, model, in_force))

      {:error, reason} ->
        assign(socket, :model_note, model_error(reason))
    end
  end

  defp model_note(:default, nil, _in_force),
    do: "Cleared. Every surface without a model of its own lets your claude CLI decide again."

  defp model_note(:default, model, in_force) do
    held = for {surface, entry} <- in_force, entry.source == :floor, do: surface_label(surface)

    case Enum.sort(held) do
      [] -> "Global default set to #{model}."
      names -> "Global default set to #{model}. Held at the floor: #{Enum.join(names, ", ")}."
    end
  end

  defp model_note(surface, nil, _in_force),
    do: "#{surface_label(surface)} inherits the global default again."

  defp model_note(surface, model, _in_force), do: "#{surface_label(surface)} set to #{model}."

  defp model_error(:blank_model),
    do: "Type a model name — the picker is how you clear one back to unset."

  defp model_error({:unknown_surface, _surface}), do: "That is not a surface Buster Claw runs."
  defp model_error(_reason), do: "Could not save that model."

  defp model_display(nil), do: "Your claude CLI decides"
  defp model_display(model), do: model

  # Why the row resolved the way it did. `:cli` has to read as an answer, not as
  # a blank — "nothing is set" is a real, and shipped, state.
  defp source_note(:cli), do: "your claude CLI decides"
  defp source_note(:default), do: "from the global default"
  defp source_note(:surface), do: "set for this surface"
  defp source_note(:floor), do: "held at the floor — the global default is lower"

  # The short head of the surface description, for notes and labels.
  defp surface_label(:default), do: "The global default"

  defp surface_label(surface) do
    ModelPolicy.surfaces() |> Map.fetch!(surface) |> String.split(" — ") |> List.first()
  end

  # Never `String.to_atom/1` a form value: resolve it against the known keys.
  # An unrecognised target stays a string, and `ModelPolicy.put/2` rejects it.
  defp model_target("default"), do: :default

  defp model_target(target) when is_binary(target) do
    Enum.find(ModelPolicy.surface_keys(), target, &(Atom.to_string(&1) == target))
  end

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank_to_nil(_value), do: nil

  # --- shared ------------------------------------------------------------

  defp assign_status(socket), do: assign(socket, :status, Setup.status())

  defp button_outline,
    do:
      "rounded border-2 border-base-content/30 px-4 py-2 text-sm font-semibold transition hover:bg-base-200"
end
