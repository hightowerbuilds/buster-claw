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

  import BusterClawWeb.Setup.Steps

  @steps [:welcome, :workspace, :tools, :google, :live]
  @claude_install_command "brew install --cask claude-code"
  @google_default_query "newer_than:7d"

  @impl true
  def mount(_params, _session, socket) do
    # Best-effort: make sure the workspace launcher exists so the Tools step can
    # show it ready without the user doing anything.
    WorkspaceCLI.ensure()

    # One-click connect creates the account from the OAuth callback (a plain
    # controller request) — subscribe so this page reflects it live.
    if connected?(socket), do: Google.subscribe()

    {:ok,
     socket
     |> assign(:page_title, "Set up Buster Claw")
     |> assign(:step, :welcome)
     |> assign(:workspace_note, nil)
     |> assign(:tools_note, nil)
     |> assign(:google_auth_url, nil)
     |> assign(:google_note, nil)
     |> assign(:google_default_query, @google_default_query)
     |> assign(:bundled_available, BusterClaw.Google.BundledClient.available?())
     |> assign_status()
     |> load_workspace()
     |> load_tools()
     |> load_google_accounts()
     |> assign_google_form()}
  end

  @impl true
  def handle_info({:google_account_changed, _event, _account}, socket) do
    {:noreply,
     socket
     |> load_google_accounts()
     |> assign_google_form()
     |> assign_status()}
  end

  # Ignore any unexpected message on the subscribed topic rather than crashing.
  def handle_info(_msg, socket), do: {:noreply, socket}

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

  # One-click connect (bundled OAuth client): open the browser immediately;
  # the account row is created by the callback once Google tells us the
  # address, and the google_account_changed broadcast refreshes this view.
  def handle_event("bundled_connect_google", _params, socket) do
    case GoogleOAuth.bundled_authorization_url() do
      {:ok, url} ->
        note =
          case SystemBrowser.open(url) do
            {:ok, :opened} ->
              "Continue in Google — pick your account and approve. " <>
                GoogleOAuth.reconnect_sentence()

            {:error, reason} ->
              "Could not open the browser automatically (#{ErrorFormatter.format(reason)}) — use Open Google sign-in below."
          end

        {:noreply,
         socket
         |> assign(:google_auth_url, url)
         |> assign(:google_note, note)}

      {:error, :bundled_client_unavailable} ->
        {:noreply,
         socket
         |> assign(:bundled_available, false)
         |> assign(
           :google_note,
           "One-click connect isn't available in this build — use the Advanced form with your own OAuth client."
         )}
    end
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
         |> assign(
           :google_note,
           "Saved. Open Google sign-in to finish. " <> GoogleOAuth.reconnect_sentence()
         )
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
    <Layouts.app flash={@flash} socket={@socket}>
      <section id="setup-wizard" class="mx-auto max-w-2xl space-y-8">
        <div class="flex items-center justify-between border-b-2 border-base-content/20 pb-5">
          <p class="ic-eyebrow">Getting started</p>
          <button type="button" phx-click="skip_for_now" class={button_ghost()}>
            Skip for now
          </button>
        </div>

        <.step_dots :if={@step != :welcome} steps={@status.steps} current={@step} />

        <.welcome_step :if={@step == :welcome} />
        <.workspace_step
          :if={@step == :workspace}
          workspace_root={@workspace_root}
          workspace_note={@workspace_note}
        />
        <.tools_step
          :if={@step == :tools}
          launcher_ready={@launcher_ready}
          claude_ready={@claude_ready}
          claude_install_command={@claude_install_command}
          tools_note={@tools_note}
        />
        <.google_step
          :if={@step == :google}
          bundled_available={@bundled_available}
          google_form={@google_form}
          google_default_query={@google_default_query}
          google_auth_url={@google_auth_url}
          google_note={@google_note}
          google_accounts={@google_accounts}
        />
        <.live_step :if={@step == :live} status={@status} />
      </section>
    </Layouts.app>
    """
  end

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
