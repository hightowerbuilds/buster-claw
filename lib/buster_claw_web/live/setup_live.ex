defmodule BusterClawWeb.SetupLive do
  @moduledoc """
  First-run onboarding. A hyper-minimal flow that takes a new user from launch
  to doing remote agentic work through their email in four dotted steps:

    1. Workspace — confirm the folder the assistant works in.
    2. Tools — place the `buster-claw` launcher and install Claude Code.
    3. Google — connect Gmail/Calendar (the one allowed bit of friction).
    4. Go live — open the terminal and start watching the inbox.

  Step completion is computed from real state via `BusterClaw.Setup.status/0`,
  so the dots reflect what's actually done. Reuses existing contexts rather than
  reimplementing flows: `BusterClaw.Google` + `BusterClawWeb.GoogleOAuth` for
  GWS, `BusterClaw.TerminalWorkspace` to open the terminal, and
  `BusterClaw.TrustedSenders` to trust the user's own address on connect.
  """
  use BusterClawWeb, :live_view

  alias BusterClaw.Google
  alias BusterClaw.Google.Account, as: GoogleAccount
  alias BusterClaw.Google.OAuth, as: GoogleOAuthCore
  alias BusterClaw.Library.Artifact
  alias BusterClaw.Settings
  alias BusterClaw.Setup
  alias BusterClaw.SystemBrowser
  alias BusterClaw.TerminalWorkspace
  alias BusterClaw.TrustedSenders
  alias BusterClaw.WorkspaceCLI
  alias BusterClawWeb.ErrorFormatter
  alias BusterClawWeb.GoogleOAuth

  @steps [:welcome, :workspace, :tools, :google, :live]
  # The four steps shown as dots (welcome is the explainer landing, not a dot).
  @dot_steps [:workspace, :tools, :google, :live]
  @claude_install_command "brew install --cask claude-code"
  @google_default_query "newer_than:7d"

  @impl true
  def mount(_params, _session, socket) do
    # Best-effort: make sure the workspace launcher exists so the Tools step can
    # show it ready without the user doing anything.
    WorkspaceCLI.ensure()

    {:ok,
     socket
     |> assign(:page_title, "Set up Buster Claw")
     |> assign(:step, :welcome)
     |> assign(:workspace_note, nil)
     |> assign(:tools_note, nil)
     |> assign(:google_auth_url, nil)
     |> assign(:google_note, nil)
     |> assign(:google_default_query, @google_default_query)
     |> assign_status()
     |> load_workspace()
     |> load_tools()
     |> load_google_accounts()
     |> assign_google_form()}
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

  def handle_event("skip_for_now", _params, socket) do
    # Let the user into the app without finishing. The home screen keeps a
    # "Finish setup" nudge (driven by Setup.status) until every step is done.
    Settings.mark_onboarding_complete()
    {:noreply, push_navigate(socket, to: ~p"/")}
  end

  # --- Workspace ----------------------------------------------------------

  def handle_event("confirm_workspace", _params, socket) do
    Setup.confirm_workspace()

    {:noreply,
     socket
     |> assign(:workspace_note, "Saved — this is your assistant's folder.")
     |> assign_status()}
  end

  # --- Tools --------------------------------------------------------------

  def handle_event("install_claude", _params, socket) do
    # Drop the user into a terminal with the installer pre-typed (they press
    # enter). Falls back to a copyable command in the UI if the terminal can't
    # be reached.
    case TerminalWorkspace.request_open(%{
           "role" => "agent-setup",
           "label" => "Install Claude Code"
         }) do
      {:ok, _request} ->
        {:noreply, push_navigate(socket, to: ~p"/terminal")}

      {:error, _reason} ->
        {:noreply,
         assign(
           socket,
           :tools_note,
           "Open the Terminal tab and run the command above, then press Re-check."
         )}
    end
  end

  def handle_event("recheck_tools", _params, socket) do
    {:noreply,
     socket
     |> assign(:tools_note, nil)
     |> load_tools()
     |> assign_status()}
  end

  # --- Google Workspace ---------------------------------------------------

  def handle_event("validate_google", %{"google_account" => params}, socket) do
    changeset =
      %GoogleAccount{}
      |> Google.change_account(put_google_defaults(params))
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :google_form, to_form(changeset, as: :google_account))}
  end

  def handle_event("connect_google", %{"google_account" => params}, socket) do
    case Google.upsert_account(put_google_defaults(params)) do
      {:ok, account} ->
        # Trust the user's own address out of the box, so an email to yourself
        # produces a real Dispatch item the moment you go live.
        trust_own_address(account)

        {:noreply,
         socket
         |> assign(:google_auth_url, GoogleOAuth.authorization_url(account))
         |> assign(:google_note, "Saved. Open Google sign-in to finish — you'll do this once.")
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

  # --- Go live ------------------------------------------------------------

  def handle_event("go_live", _params, socket) do
    Setup.mark_went_live()
    Settings.mark_onboarding_complete()
    TerminalWorkspace.request_open_mailman()
    {:noreply, push_navigate(socket, to: ~p"/terminal")}
  end

  # --- Render -------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <section id="setup-wizard" class="mx-auto max-w-2xl space-y-8">
        <div class="flex items-center justify-between border-b-2 border-base-content/20 pb-5">
          <p class="ic-eyebrow">Getting started</p>
          <button type="button" phx-click="skip_for_now" class={button_ghost()}>
            Skip for now
          </button>
        </div>

        <.step_dots :if={@step != :welcome} steps={@status.steps} current={@step} />

        <%!-- Welcome --%>
        <div :if={@step == :welcome} class="space-y-6">
          <div class="ic-panel space-y-4 p-6">
            <h1 class="font-display text-3xl font-black uppercase tracking-tight">
              Your assistant, reachable by email
            </h1>
            <p class="text-sm leading-7 text-base-content/80">
              Buster Claw is a personal assistant you reach any time — just email it. While your
              shift is open, your trusted contacts can email it too, and it gets to work: reading
              mail, browsing the web, handling tasks, and replying for you.
            </p>
            <ul class="space-y-2 text-sm leading-7 text-base-content/80">
              <li>Email it like a person — it reads and replies.</li>
              <li>It acts for you across Gmail, Calendar, the web, and your tools.</li>
              <li>You stay in control — trusted contacts only, full audit, instant kill switch.</li>
            </ul>
            <p class="text-sm leading-7 text-base-content/60">
              Everything runs on your machine. Four quick steps and you're live.
            </p>
          </div>
          <div class="flex justify-end">
            <button type="button" phx-click="next" class={button_primary()}>Get started</button>
          </div>
        </div>

        <%!-- Step 1 · Workspace --%>
        <div :if={@step == :workspace} class="space-y-6">
          <div class="ic-panel space-y-4 p-6">
            <h2 class="font-display text-xl font-black uppercase tracking-tight">Pick your folder</h2>
            <p class="text-sm leading-7 text-base-content/80">
              This is where your assistant keeps its files. You can move it later.
            </p>

            <div>
              <p class="ic-eyebrow">Folder</p>
              <p class="mt-1 break-words font-mono text-sm">{@workspace_root}</p>
            </div>

            <p
              :if={@workspace_note}
              class="rounded-sm border-2 border-primary/40 bg-primary/10 px-3 py-2 text-sm"
            >
              {@workspace_note}
            </p>

            <div class="flex flex-wrap items-center gap-3">
              <button type="button" phx-click="confirm_workspace" class={button_outline()}>
                Use this folder
              </button>
              <.link navigate={~p"/workspace"} class="text-sm text-primary underline">
                Change…
              </.link>
            </div>
          </div>
          <.step_nav />
        </div>

        <%!-- Step 2 · Tools --%>
        <div :if={@step == :tools} class="space-y-6">
          <div class="ic-panel space-y-5 p-6">
            <h2 class="font-display text-xl font-black uppercase tracking-tight">
              Get the tools ready
            </h2>
            <p class="text-sm leading-7 text-base-content/80">
              Your assistant runs as Claude Code. We'll set it up — no terminal knowledge needed.
            </p>

            <.tool_row ready={@launcher_ready} label="Buster Claw" detail="ready to go" />

            <div class="space-y-3">
              <.tool_row
                ready={@claude_ready}
                label="Claude Code"
                detail={if @claude_ready, do: "installed", else: "not installed yet"}
              />

              <div :if={not @claude_ready} class="space-y-3 pl-7">
                <p class="text-sm leading-6 text-base-content/70">
                  Install it once. We'll open a terminal with the command ready — press enter to run
                  it, then come back and Re-check.
                </p>
                <pre class="overflow-x-auto rounded-sm border-2 border-base-content/20 bg-base-200 px-3 py-2 font-mono text-xs">{@claude_install_command}</pre>
                <div class="flex flex-wrap gap-3">
                  <button type="button" phx-click="install_claude" class={button_primary()}>
                    Install Claude Code
                  </button>
                  <button type="button" phx-click="recheck_tools" class={button_outline()}>
                    Re-check
                  </button>
                </div>
              </div>
            </div>

            <p
              :if={@tools_note}
              class="rounded-sm border-2 border-primary/40 bg-primary/10 px-3 py-2 text-sm"
            >
              {@tools_note}
            </p>
          </div>
          <.step_nav />
        </div>

        <%!-- Step 3 · Google --%>
        <div :if={@step == :google} class="space-y-6">
          <div class="ic-panel space-y-4 p-6">
            <h2 class="font-display text-xl font-black uppercase tracking-tight">
              Connect your Google Workspace
            </h2>
            <p class="text-sm leading-7 text-base-content/80">
              Buster Claw manages your Google Workspace on your behalf — Gmail, Calendar, Drive,
              Docs, Sheets, Slides, Contacts and Tasks. Connecting is a one-time Google step; the
              consent screen will list each of these permissions, so approve them all to give your
              agent full access. Once it's done, emails from you are trusted automatically.
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
          <.step_nav />
        </div>

        <%!-- Step 4 · Go live --%>
        <div :if={@step == :live} class="space-y-6">
          <div class="ic-panel space-y-4 p-6">
            <h2 class="font-display text-xl font-black uppercase tracking-tight">Start working</h2>
            <p class="text-sm leading-7 text-base-content/80">
              You're ready. Open the terminal and press enter — your assistant starts watching your
              inbox. Email yourself a task to try it.
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

            <div class="flex flex-wrap gap-3 pt-1">
              <button type="button" phx-click="go_live" class={button_primary()}>
                Open terminal &amp; go live
              </button>
            </div>
          </div>
          <div class="flex justify-start">
            <button type="button" phx-click="back" class={button_ghost()}>Back</button>
          </div>
        </div>
      </section>
    </Layouts.app>
    """
  end

  # --- Dots / nav / row components ----------------------------------------

  attr :steps, :list, required: true
  attr :current, :atom, required: true

  defp step_dots(assigns) do
    assigns = assign(assigns, :order, @dot_steps)

    ~H"""
    <ol class="flex items-start justify-between gap-2">
      <li :for={s <- @steps} class="flex flex-1 flex-col items-center gap-2 text-center">
        <button
          type="button"
          phx-click="goto"
          phx-value-step={s.key}
          class={[
            "flex size-7 items-center justify-center rounded-full border-2 transition",
            dot_classes(s, @current)
          ]}
        >
          <.icon :if={s.complete} name="hero-check-mini" class="size-4" />
        </button>
        <span class={[
          "font-mono text-[0.65rem] uppercase tracking-wide",
          if(s.key == @current, do: "text-primary", else: "text-base-content/55")
        ]}>
          {s.label}
        </span>
      </li>
    </ol>
    """
  end

  # Filled = complete; ringed = current; muted = not yet.
  defp dot_classes(%{complete: true}, _current),
    do: "border-success bg-success text-success-content"

  defp dot_classes(%{key: key}, current) when key == current,
    do: "border-primary bg-primary/15 text-primary"

  defp dot_classes(_step, _current), do: "border-base-content/25 text-base-content/40"

  defp step_nav(assigns) do
    ~H"""
    <div class="flex justify-between">
      <button type="button" phx-click="back" class={button_ghost()}>Back</button>
      <button type="button" phx-click="next" class={button_primary()}>Next →</button>
    </div>
    """
  end

  attr :ready, :boolean, required: true
  attr :label, :string, required: true
  attr :detail, :string, required: true

  defp tool_row(assigns) do
    ~H"""
    <div class="flex items-center gap-2">
      <.icon
        name={if @ready, do: "hero-check-circle-solid", else: "hero-arrow-down-circle"}
        class={["size-5 shrink-0", if(@ready, do: "text-success", else: "text-base-content/40")]}
      />
      <span class="text-sm font-semibold">{@label}</span>
      <span class="text-sm text-base-content/60">— {@detail}</span>
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
    Enum.find(@steps, :welcome, &(Atom.to_string(&1) == step))
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
    assign(socket, :workspace_root, Artifact.workspace_root())
  end

  defp load_tools(socket) do
    socket
    |> assign(:launcher_ready, File.exists?(WorkspaceCLI.launcher_path()))
    |> assign(:claude_ready, Setup.agent_cli_available?())
    |> assign(:claude_install_command, @claude_install_command)
  end

  defp load_google_accounts(socket) do
    assign(socket, :google_accounts, Google.list_account_summaries())
  end

  defp assign_google_form(socket) do
    changeset =
      Google.change_account(%GoogleAccount{}, %{
        "scopes" => GoogleOAuthCore.default_scope_string(),
        "default_query" => @google_default_query,
        "enabled" => true
      })

    assign(socket, :google_form, to_form(changeset, as: :google_account))
  end

  # Best-effort: trust the connected account's own address so a test email to
  # yourself reaches the Dispatch queue immediately. Never blocks the connect.
  defp trust_own_address(%{email: email}) when is_binary(email) and email != "" do
    TrustedSenders.add_entry(email)
  rescue
    _ -> :ok
  end

  defp trust_own_address(_account), do: :ok

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

  defp blank_to_default(nil, default), do: default
  defp blank_to_default("", default), do: default
  defp blank_to_default(value, _default), do: value
end
