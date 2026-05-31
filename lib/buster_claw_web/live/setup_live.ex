defmodule BusterClawWeb.SetupLive do
  @moduledoc """
  First-run setup wizard. Walks a new user through: how Buster Claw works, the
  workspace folder, connecting Google Workspace, and configuring an AI provider.

  Reuses existing contexts rather than reimplementing flows:
  `BusterClaw.Google` + `BusterClawWeb.GoogleOAuth` for GWS, and
  `BusterClaw.Providers` for the AI model. Completion is recorded via
  `BusterClaw.Settings.mark_onboarding_complete/0`.
  """
  use BusterClawWeb, :live_view

  alias BusterClaw.Google
  alias BusterClaw.Google.Account, as: GoogleAccount
  alias BusterClaw.Google.OAuth, as: GoogleOAuthCore
  alias BusterClaw.Library.Artifact
  alias BusterClaw.Providers
  alias BusterClaw.Providers.Provider
  alias BusterClaw.Settings
  alias BusterClaw.Setup
  alias BusterClaw.SystemBrowser
  alias BusterClawWeb.ErrorFormatter
  alias BusterClawWeb.GoogleOAuth

  @steps [:intro, :identity, :workspace, :gws, :provider, :done]
  @step_bar [
    {:intro, "Welcome"},
    {:identity, "You"},
    {:workspace, "Workspace"},
    {:gws, "Google"},
    {:provider, "AI Model"}
  ]
  @google_default_query "newer_than:7d"

  @provider_types [
    {"Anthropic (Claude)", "anthropic"},
    {"Google Gemini", "gemini"},
    {"OpenAI (Chat Completions)", "openai"},
    {"Ollama (local)", "ollama"}
  ]

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Setup")
     |> assign(:step, :intro)
     |> assign(:workspace_note, nil)
     |> assign(:profile_name, Setup.profile_name())
     |> assign(:profile_org, Setup.profile_org())
     |> assign(:profile_note, nil)
     |> assign(:google_auth_url, nil)
     |> assign(:google_note, nil)
     |> assign(:provider_note, nil)
     |> assign(:provider_types, @provider_types)
     |> assign_status()
     |> load_workspace()
     |> load_google_accounts()
     |> load_providers()
     |> assign_google_form()
     |> assign_provider_form()}
  end

  # --- Step navigation ----------------------------------------------------

  @impl true
  def handle_event("goto", %{"step" => step}, socket) do
    {:noreply, assign(socket, :step, to_step(step))}
  end

  def handle_event("next", _params, socket) do
    {:noreply, assign(socket, :step, advance(socket.assigns.step, +1))}
  end

  def handle_event("back", _params, socket) do
    {:noreply, assign(socket, :step, advance(socket.assigns.step, -1))}
  end

  def handle_event("finish", _params, socket) do
    Settings.mark_onboarding_complete()
    {:noreply, push_navigate(socket, to: ~p"/")}
  end

  # --- Identity -----------------------------------------------------------

  def handle_event("save_profile", %{"name" => name, "org" => org}, socket) do
    Setup.put_profile(name, org)

    {:noreply,
     socket
     |> assign(:profile_name, String.trim(name))
     |> assign(:profile_org, String.trim(org))
     |> assign(:profile_note, "Saved.")
     |> assign_status()}
  end

  # --- Workspace ----------------------------------------------------------

  def handle_event("confirm_workspace", _params, socket) do
    Setup.confirm_workspace()

    {:noreply,
     socket
     |> assign(:workspace_note, "Workspace confirmed.")
     |> assign_status()}
  end

  # --- Google Workspace ---------------------------------------------------

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
         |> assign(:google_note, "Google account saved. Open sign-in to authorize.")
         |> load_google_accounts()
         |> assign_google_form()
         |> assign_status()}

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

  # --- AI provider --------------------------------------------------------

  def handle_event("validate_provider", %{"provider" => params}, socket) do
    changeset =
      %Provider{}
      |> Provider.changeset(params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :provider_form, to_form(changeset, as: :provider))}
  end

  def handle_event("add_provider", %{"provider" => params}, socket) do
    params = fill_provider_defaults(params)
    existing = socket.assigns.providers

    case Providers.create_provider(params) do
      {:ok, provider} ->
        if Enum.all?(existing, &(!&1.active)), do: Providers.set_active_provider(provider)

        {:noreply,
         socket
         |> assign(:provider_note, "Saved #{provider.name} and set it active.")
         |> load_providers()
         |> assign_provider_form()
         |> assign_status()}

      {:error, changeset} ->
        {:noreply, assign(socket, :provider_form, to_form(changeset, as: :provider))}
    end
  end

  # --- Render -------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <section id="setup-wizard" class="mx-auto max-w-3xl space-y-8">
        <div class="space-y-3 border-b-2 border-base-content/20 pb-5">
          <p class="ic-eyebrow">First-run setup</p>
          <h1 class="font-display text-3xl font-black uppercase tracking-tight">
            Get Buster Claw running
          </h1>
          <.step_bar step={@step} />
        </div>

        <div :if={@step == :intro} class="space-y-5">
          <div class="ic-panel space-y-4 p-6">
            <h2 class="font-display text-xl font-black uppercase tracking-tight">
              How Buster Claw works
            </h2>
            <p class="text-sm leading-7 text-base-content/80">
              Buster Claw is a desktop runtime where an AI agent manages your web interactivity. The
              main way to use it is to run <span class="font-semibold">Claude Code or Codex in the
                built-in terminal</span> — those agents operate Buster Claw through its MCP server and
              your workspace to browse the web, act on Google Workspace and integrations, and deliver
              results, all through one auditable command surface. A built-in chat with your own AI
              provider is also available.
            </p>
            <ul class="space-y-2 text-sm leading-7 text-base-content/80">
              <li>
                <span class="font-mono text-primary">ingest</span>
                → fetch URLs, RSS, and email into the Library
              </li>
              <li>
                <span class="font-mono text-primary">analyze</span>
                → run documents through your AI provider
              </li>
              <li>
                <span class="font-mono text-primary">deliver</span>
                → push results to Slack, email, and more
              </li>
            </ul>
            <p class="text-sm leading-7 text-base-content/60">
              The app and your data stay on your machine. Every command, outbound send, and untrusted
              fetch is recorded on the Security audit feed. This wizard sets up the essentials — you can change
              any of it later from Settings.
            </p>
          </div>
          <div class="flex justify-end">
            <button type="button" phx-click="next" class={button_primary()}>Get started</button>
          </div>
        </div>

        <div :if={@step == :identity} class="space-y-5">
          <div class="ic-panel space-y-4 p-6">
            <h2 class="font-display text-xl font-black uppercase tracking-tight">
              Who's using Buster Claw?
            </h2>
            <p class="text-sm leading-7 text-base-content/80">
              Tell us your name or your organization. Enter at least one — it's used to personalize
              the app and label what you create.
            </p>

            <form phx-submit="save_profile" class="space-y-3">
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
                <span class="ic-eyebrow">Organization (optional)</span>
                <input
                  type="text"
                  name="org"
                  value={@profile_org}
                  autocomplete="off"
                  placeholder="Analytical Engines Ltd."
                  class="input mt-1 w-full"
                />
              </label>
              <button type="submit" class={button_outline()}>Save</button>
            </form>

            <p
              :if={@profile_note}
              class="rounded-sm border-2 border-primary/40 bg-primary/10 px-3 py-2 text-sm"
            >
              {@profile_note}
            </p>
          </div>
          <.step_nav can_back={true} skip_label="Skip" />
        </div>

        <div :if={@step == :workspace} class="space-y-5">
          <div class="ic-panel space-y-4 p-6">
            <h2 class="font-display text-xl font-black uppercase tracking-tight">Your workspace</h2>
            <p class="text-sm leading-7 text-base-content/80">
              This is where Buster Claw keeps your files — a <span class="font-mono">library/</span>
              for documents plus <span class="font-mono">sources/</span>, <span class="font-mono">analysis/</span>, and
              <span class="font-mono">memory/</span>
              folders.
            </p>

            <div>
              <p class="ic-eyebrow">Current workspace</p>
              <p class="mt-1 break-words font-mono text-sm">{@workspace_root}</p>
            </div>

            <ul class="grid grid-cols-2 gap-2 font-mono text-xs text-base-content/70 sm:grid-cols-4">
              <li class="rounded-sm border-2 border-base-content/20 px-2 py-1">library/</li>
              <li
                :for={sub <- @workspace_subdirs}
                class="rounded-sm border-2 border-base-content/20 px-2 py-1"
              >
                {sub}/
              </li>
            </ul>

            <p class="text-sm text-base-content/60">
              Browse, create, or move files — and change the workspace location — anytime from the
              <.link navigate={~p"/workspace"} class="text-primary underline">Workspace</.link>
              tab.
            </p>

            <p
              :if={@workspace_note}
              class="rounded-sm border-2 border-primary/40 bg-primary/10 px-3 py-2 text-sm"
            >
              {@workspace_note}
            </p>

            <div class="flex flex-wrap gap-3">
              <button type="button" phx-click="confirm_workspace" class={button_outline()}>
                Use this workspace
              </button>
            </div>
          </div>
          <.step_nav can_back={true} skip_label="Skip" />
        </div>

        <div :if={@step == :gws} class="space-y-5">
          <div class="ic-panel space-y-4 p-6">
            <h2 class="font-display text-xl font-black uppercase tracking-tight">
              Connect Google Workspace
            </h2>
            <p class="text-sm leading-7 text-base-content/80">
              Paste your desktop OAuth client credentials to read Gmail and Calendar. This is optional —
              you can connect later from the GWS tab.
            </p>

            <.form
              for={@google_form}
              id="setup-google-form"
              phx-change="validate_google"
              phx-submit="connect_google"
              class="space-y-3"
            >
              <.input
                field={@google_form[:email]}
                type="email"
                label="Google email"
                autocomplete="off"
              />
              <.input field={@google_form[:client_id]} label="OAuth client ID" autocomplete="off" />
              <.input
                field={@google_form[:client_secret]}
                type="password"
                label="OAuth client secret"
                autocomplete="off"
              />
              <input
                type="hidden"
                name="google_account[scopes]"
                value={GoogleOAuthCore.default_scope_string()}
              />
              <input type="hidden" name="google_account[default_query]" value={@google_default_query} />
              <button type="submit" class={button_outline()}>Save Google account</button>
            </.form>

            <div :if={@google_auth_url} class="space-y-2 border-t-2 border-base-content/15 pt-4">
              <button type="button" phx-click="open_google_sign_in" class={button_primary()}>
                Open Google sign-in
              </button>
              <p class="break-words font-mono text-xs text-base-content/60">{@google_auth_url}</p>
            </div>

            <p
              :if={@google_note}
              class="rounded-sm border-2 border-primary/40 bg-primary/10 px-3 py-2 text-sm"
            >
              {@google_note}
            </p>

            <p :if={@google_accounts != []} class="text-sm text-base-content/70">
              Connected: {Enum.map_join(@google_accounts, ", ", & &1.email)}
            </p>
          </div>
          <.step_nav can_back={true} skip_label="Skip" />
        </div>

        <div :if={@step == :provider} class="space-y-5">
          <div class="ic-panel space-y-4 p-6">
            <h2 class="font-display text-xl font-black uppercase tracking-tight">AI model</h2>
            <p class="text-sm leading-7 text-base-content/80">
              Configure a provider so chat and analysis work. The first provider you add becomes active.
            </p>

            <.form
              for={@provider_form}
              id="setup-provider-form"
              phx-change="validate_provider"
              phx-submit="add_provider"
              class="space-y-3"
            >
              <.input
                field={@provider_form[:type]}
                type="select"
                label="Provider"
                options={@provider_types}
              />
              <.input field={@provider_form[:model]} label="Model" />
              <.input
                field={@provider_form[:api_key]}
                type="password"
                label="API key"
                autocomplete="off"
              />
              <button type="submit" class={button_outline()}>Save provider</button>
            </.form>

            <p
              :if={@provider_note}
              class="rounded-sm border-2 border-primary/40 bg-primary/10 px-3 py-2 text-sm"
            >
              {@provider_note}
            </p>

            <p :if={@providers != []} class="text-sm text-base-content/70">
              Configured: {Enum.map_join(@providers, ", ", & &1.name)}
            </p>
          </div>
          <.step_nav can_back={true} skip_label="Skip" />
        </div>

        <div :if={@step == :done} class="space-y-5">
          <div class="ic-panel space-y-4 p-6">
            <h2 class="font-display text-xl font-black uppercase tracking-tight">
              {if @status.complete?, do: "You're all set", else: "Almost there"}
            </h2>
            <p class="text-sm leading-7 text-base-content/80">
              {@status.completed} of {@status.total} steps complete. You can finish now and pick up
              anything you skipped later from the Settings tab.
            </p>
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
          </div>
          <div class="flex justify-between">
            <button type="button" phx-click="back" class={button_ghost()}>Back</button>
            <button type="button" phx-click="finish" class={button_primary()}>Finish setup</button>
          </div>
        </div>
      </section>
    </Layouts.app>
    """
  end

  # --- Step bar / nav components -----------------------------------------

  attr :step, :atom, required: true

  defp step_bar(assigns) do
    assigns = assign(assigns, :bar, @step_bar)

    ~H"""
    <ol class="flex flex-wrap gap-2 font-mono text-xs uppercase tracking-wide">
      <li
        :for={{key, label} <- @bar}
        class={[
          "rounded-sm border-2 px-3 py-1",
          if(key == @step,
            do: "border-primary bg-primary/15 text-primary",
            else: "border-base-content/20 text-base-content/55"
          )
        ]}
      >
        {label}
      </li>
    </ol>
    """
  end

  attr :can_back, :boolean, default: true
  attr :skip_label, :string, default: "Skip"

  defp step_nav(assigns) do
    ~H"""
    <div class="flex justify-between">
      <button type="button" phx-click="back" disabled={not @can_back} class={button_ghost()}>
        Back
      </button>
      <button type="button" phx-click="next" class={button_primary()}>{@skip_label} →</button>
    </div>
    """
  end

  defp button_primary,
    do:
      "rounded bg-primary px-4 py-2 text-sm font-semibold text-primary-content transition hover:opacity-85"

  defp button_outline,
    do:
      "rounded border-2 border-base-content/30 px-4 py-2 text-sm font-semibold transition hover:bg-base-200"

  defp button_ghost,
    do:
      "rounded px-4 py-2 text-sm font-semibold text-base-content/70 transition hover:bg-base-200"

  # --- Helpers ------------------------------------------------------------

  defp to_step(step) when is_binary(step) do
    Enum.find(@steps, :intro, &(Atom.to_string(&1) == step))
  end

  defp advance(current, delta) do
    idx = Enum.find_index(@steps, &(&1 == current)) || 0
    next = idx + delta

    cond do
      next < 0 -> List.first(@steps)
      next >= length(@steps) -> List.last(@steps)
      true -> Enum.at(@steps, next)
    end
  end

  defp assign_status(socket), do: assign(socket, :status, Setup.status())

  defp load_workspace(socket) do
    socket
    |> assign(:workspace_root, Artifact.workspace_root())
    |> assign(:workspace_subdirs, Artifact.workspace_subdirs())
    |> assign(:google_default_query, @google_default_query)
  end

  defp load_google_accounts(socket) do
    assign(socket, :google_accounts, Google.list_account_summaries())
  end

  defp load_providers(socket) do
    assign(socket, :providers, Providers.list_providers())
  end

  defp assign_google_form(socket) do
    changeset =
      GoogleAccount.changeset(%GoogleAccount{}, %{
        "scopes" => GoogleOAuthCore.default_scope_string(),
        "default_query" => @google_default_query,
        "enabled" => true
      })

    assign(socket, :google_form, to_form(changeset, as: :google_account))
  end

  defp assign_provider_form(socket) do
    changeset =
      Provider.changeset(%Provider{}, %{
        type: "anthropic",
        model: default_model("anthropic"),
        priority: 100
      })

    assign(socket, :provider_form, to_form(changeset, as: :provider))
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

  defp fill_provider_defaults(params) do
    type = Map.get(params, "type", "anthropic")
    model = blank_to_default(Map.get(params, "model"), default_model(type))
    name = blank_to_default(Map.get(params, "name"), provider_label(type))

    params
    |> Map.put("model", model)
    |> Map.put("name", name)
    |> Map.put("priority", "100")
  end

  defp provider_label(type) do
    Enum.find_value(@provider_types, type, fn {label, value} -> value == type && label end)
  end

  defp default_model("anthropic"), do: "claude-sonnet-4-6"
  defp default_model("gemini"), do: "gemini-2.0-flash"
  defp default_model("openai"), do: "gpt-4o"
  defp default_model("ollama"), do: "llama3"
  defp default_model(_type), do: ""

  defp blank_to_default(nil, default), do: default
  defp blank_to_default("", default), do: default
  defp blank_to_default(value, _default), do: value
end
