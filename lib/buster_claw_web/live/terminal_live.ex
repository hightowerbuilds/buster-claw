defmodule BusterClawWeb.TerminalLive do
  @moduledoc """
  Terminal tab. The view is just a host for xterm.js (the `TerminalView` JS
  hook); the shell runs in a PTY in the Tauri Rust backend, streamed over IPC.
  Works in the desktop app; in a plain browser the hook shows a notice.

  No page header — the terminal fills its tab (flush with the tab bar) and, in a
  split pane, sits flush against the partition.
  """
  use BusterClawWeb, :live_view

  alias BusterClaw.Library.Artifact

  @impl true
  def mount(params, session, socket) do
    terminal_session_key = terminal_session_key(params, session)
    terminal_label = terminal_label(params, session, terminal_session_key)
    startup_profile = startup_profile(params, session)
    startup_submit = startup_submit(params, session)
    dom_id = "terminal-root-#{System.unique_integer([:positive])}"

    if connected?(socket) do
      Phoenix.PubSub.subscribe(BusterClaw.PubSub, BusterClaw.Appearance.topic())
    end

    {:ok,
     socket
     |> assign(:page_title, terminal_label)
     |> assign(:terminal_background_url, BusterClaw.Appearance.terminal_background_url())
     |> assign(:terminal_session_key, terminal_session_key)
     |> assign(:terminal_label, terminal_label)
     |> assign(:startup_profile, startup_profile)
     |> assign(:startup_command, startup_command(startup_profile))
     |> assign(:startup_submit, startup_submit)
     |> assign(:terminal_commands_open, false)
     |> assign(:terminal_command_roles, BusterClaw.TerminalCommands.roles())
     |> assign(
       :terminal_path,
       terminal_path(terminal_session_key, terminal_label, startup_profile)
     )
     |> assign(:embedded?, BusterClawWeb.ChromeHook.embedded?())
     |> assign(:cwd, Artifact.workspace_root())
     |> assign(:dom_id, dom_id)
     |> assign(:toolbar_id, "#{dom_id}-toolbar")
     |> assign(:status_id, "#{dom_id}-status")
     |> assign(:commands_button_id, "#{dom_id}-commands")
     |> assign(:commands_menu_id, "#{dom_id}-commands-menu")
     |> assign(:commands_title_id, "#{dom_id}-commands-title")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <section
        id={"#{@dom_id}-session"}
        data-terminal-session-shell
        data-terminal-embedded={to_string(@embedded?)}
        data-terminal-bg-active={to_string(@terminal_background_url != nil)}
        class={[
          "relative flex min-h-0 flex-col overflow-hidden",
          if(@embedded? and @terminal_background_url, do: "bg-transparent", else: "bg-base-100"),
          if(@embedded?, do: "h-full", else: "ic-panel -mt-6 h-[calc(100dvh-8rem)]")
        ]}
      >
        <div
          id={@toolbar_id}
          data-terminal-toolbar
          data-session-key={@terminal_session_key}
          data-terminal-label={@terminal_label}
          data-terminal-path={@terminal_path}
          data-startup-profile={@startup_profile}
          class={
            [
              "flex min-h-11 items-center gap-3 border-b border-base-300 py-2 pl-3",
              # Embedded in a split, leave room at the right for the pane-close button.
              if(@embedded?, do: "pr-12", else: "pr-3")
            ]
          }
        >
          <div class="flex min-w-0 flex-1 items-center gap-2">
            <.icon name="hero-command-line" class="size-4 shrink-0 text-primary" />
            <div class="min-w-0">
              <div class="truncate text-sm font-semibold leading-tight">{@terminal_label}</div>
              <div class="mt-0.5 flex min-w-0 items-center gap-2">
                <span
                  id={@status_id}
                  data-terminal-status
                  class="inline-flex shrink-0 rounded-sm bg-base-200 px-1.5 py-0.5 font-mono text-[0.65rem] font-semibold uppercase leading-none text-base-content/55"
                >
                  Connecting
                </span>
                <code
                  data-terminal-key
                  class="hidden truncate font-mono text-[0.68rem] text-base-content/45 sm:block"
                >
                  {@terminal_session_key}
                </code>
              </div>
            </div>
          </div>

          <div class="flex shrink-0 items-center gap-1">
            <button
              id={"#{@dom_id}-split"}
              type="button"
              data-terminal-action="split"
              data-split-side="right"
              title="Split terminal"
              aria-label="Split terminal"
              class={toolbar_button_class()}
            >
              <.icon name="hero-plus" class="size-4" />
            </button>
            <button
              id={"#{@dom_id}-copy-key"}
              type="button"
              data-terminal-action="copy-key"
              title="Copy session key"
              aria-label="Copy session key"
              class={toolbar_button_class()}
            >
              <.icon name="hero-clipboard-document" class="size-4" />
            </button>
            <button
              id={@commands_button_id}
              type="button"
              data-terminal-commands-button
              title="Command cheat sheet"
              aria-label="Show command cheat sheet"
              aria-haspopup="menu"
              aria-controls={@commands_menu_id}
              aria-expanded={to_string(@terminal_commands_open)}
              phx-click="toggle_terminal_commands"
              class="inline-flex shrink-0 items-center gap-1.5 rounded-sm px-2 py-1 font-mono text-xs uppercase tracking-wide text-base-content/60 transition hover:bg-base-content/10 hover:text-primary"
            >
              <.icon name="hero-command-line" class="size-4" />
              <span>cmd-list</span>
            </button>
          </div>
        </div>

        <div
          id={@dom_id}
          phx-hook="TerminalView"
          phx-update="ignore"
          data-cwd={@cwd}
          data-session-key={@terminal_session_key}
          data-terminal-label={@terminal_label}
          data-terminal-path={@terminal_path}
          data-startup-profile={@startup_profile}
          data-startup-command={@startup_command}
          data-startup-submit={to_string(@startup_submit)}
          data-toolbar-id={@toolbar_id}
          data-status-id={@status_id}
          data-terminal-embedded={to_string(@embedded?)}
          data-terminal-bg-active={to_string(@terminal_background_url != nil)}
          data-terminal-bg-source={terminal_background_source(@terminal_background_url, @embedded?)}
          data-terminal-bg-image={terminal_host_background(@terminal_background_url, @embedded?)}
          class={[
            "min-h-0 flex-1 overflow-hidden",
            if(@terminal_background_url, do: "bg-transparent", else: "bg-base-100"),
            if(@embedded?, do: "h-full", else: "p-2")
          ]}
        >
        </div>

        <.terminal_commands_panel
          :if={@terminal_commands_open}
          id={@commands_menu_id}
          title_id={@commands_title_id}
          terminal_id={@dom_id}
          roles={@terminal_command_roles}
        />
      </section>
    </Layouts.app>
    """
  end

  attr :id, :string, required: true
  attr :title_id, :string, required: true
  attr :terminal_id, :string, required: true
  attr :roles, :list, required: true

  defp terminal_commands_panel(assigns) do
    ~H"""
    <div
      id={@id}
      data-terminal-commands-menu
      role="menu"
      aria-labelledby={@title_id}
      phx-click-away="close_terminal_commands"
      phx-window-keydown="close_terminal_commands"
      phx-key="escape"
      class="absolute right-3 top-14 z-50 w-[min(25rem,calc(100%-1.5rem))] overflow-hidden rounded-sm border-2 border-base-content/25 bg-base-100 text-base-content shadow-[6px_6px_0_0_color-mix(in_oklab,black_35%,transparent)]"
    >
      <header class="flex items-center justify-between gap-3 border-b-2 border-base-content/20 px-4 py-3">
        <div>
          <p class="ic-eyebrow">Terminal</p>
          <h2 id={@title_id} class="font-display text-lg font-black uppercase">
            Commands
          </h2>
        </div>
        <button
          id={"#{@terminal_id}-commands-close"}
          type="button"
          data-terminal-commands-close
          aria-label="Close commands menu"
          phx-click="close_terminal_commands"
          class="grid size-8 place-items-center rounded-sm text-base-content/60 transition hover:bg-base-content/10 hover:text-primary"
        >
          <.icon name="hero-x-mark" class="size-4" />
        </button>
      </header>

      <div class="max-h-[min(28rem,calc(100dvh-10rem))] overflow-y-auto p-3">
        <details
          :for={role <- @roles}
          id={"#{@terminal_id}-command-role-#{role.key}"}
          data-terminal-command-role={role.key}
          open={length(@roles) == 1}
          class="group rounded-sm border border-base-300 bg-base-200/45"
        >
          <summary
            id={"#{@terminal_id}-command-role-summary-#{role.key}"}
            class="flex cursor-pointer list-none items-center justify-between gap-3 px-3 py-3 text-sm font-semibold transition hover:text-primary"
          >
            <span class="flex min-w-0 items-center gap-2">
              <.icon name="hero-identification" class="size-4 shrink-0 text-primary" />
              <span class="truncate">{role.label}</span>
            </span>
            <.icon name="hero-chevron-right" class="size-4 shrink-0 transition group-open:rotate-90" />
          </summary>

          <div
            id={"#{@terminal_id}-command-list-#{role.key}"}
            class="space-y-2 border-t border-base-300 p-2"
          >
            <article
              :for={command <- role.commands}
              id={"#{@terminal_id}-command-#{role.key}-#{command.key}"}
              data-terminal-command={command.key}
              class="rounded-sm border border-base-300 bg-base-100 p-3"
            >
              <div class="flex items-start justify-between gap-3">
                <div class="min-w-0">
                  <h3 class="text-sm font-semibold">{command.label}</h3>
                  <p class="mt-1 text-xs leading-5 text-base-content/60">
                    {command.description}
                  </p>
                </div>
                <button
                  id={"#{@terminal_id}-command-copy-#{role.key}-#{command.key}"}
                  type="button"
                  data-terminal-command-copy={command.command}
                  class="inline-flex shrink-0 items-center gap-1.5 rounded-sm border border-base-content/20 px-2 py-1 font-mono text-[0.68rem] font-semibold uppercase tracking-wide text-base-content/65 transition hover:border-primary hover:text-primary"
                >
                  <.icon name="hero-clipboard-document" class="size-3.5" />
                  <span data-terminal-command-copy-label>Copy</span>
                </button>
              </div>
              <code class="mt-3 block overflow-x-auto rounded-sm bg-base-200 px-2 py-1.5 font-mono text-xs text-base-content/75">
                {command.command}
              </code>
            </article>
          </div>
        </details>
      </div>
    </div>
    """
  end

  @impl true
  def handle_event("toggle_terminal_commands", _params, socket) do
    {:noreply, update(socket, :terminal_commands_open, &(!&1))}
  end

  def handle_event("close_terminal_commands", _params, socket) do
    {:noreply, assign(socket, :terminal_commands_open, false)}
  end

  @impl true
  def handle_info({:terminal_background, url}, socket) do
    embedded? = socket.assigns.embedded?

    {:noreply,
     socket
     |> assign(:terminal_background_url, url)
     |> push_event("terminal-background", %{
       active: url != nil,
       source: terminal_background_source(url, embedded?),
       image: terminal_host_background(url, embedded?)
     })}
  end

  # Every terminal paints the background on its own host (the xterm canvas only
  # reveals its host's background, not ancestors). The JS anchors the image to
  # the viewport (`background-attachment: fixed`), so two joined terminals reveal
  # adjacent slices of the same picture — one continuous image across the split.
  defp terminal_host_background(url, _embedded?) when is_binary(url), do: url
  defp terminal_host_background(_url, _embedded?), do: ""

  defp terminal_background_source(nil, _embedded?), do: "none"
  defp terminal_background_source(_url, _embedded?), do: "host"

  defp terminal_session_key(params, session) do
    params
    |> param_value("session")
    |> Kernel.||(session["terminal_session_key"])
    |> sanitize_session_key()
  end

  defp terminal_label(params, session, session_key) do
    label =
      params
      |> param_value("label")
      |> Kernel.||(session["terminal_label"])
      |> present()

    label || label_from_session_key(session_key)
  end

  defp startup_profile(params, session) do
    params
    |> param_value("startup_profile")
    |> Kernel.||(session["startup_profile"])
    |> sanitize_startup_profile()
  end

  # Accept any profile that resolves to a command in the TerminalCommands
  # catalog (mailman, agent-setup, …); reject anything else.
  defp sanitize_startup_profile(value) when is_binary(value) do
    if BusterClaw.TerminalCommands.startup_command(value), do: value, else: nil
  end

  defp sanitize_startup_profile(_value), do: nil

  # Whether the startup command should be auto-run (newline appended) on open.
  # Defaults to true; the onboarding/prefill path passes `startup_submit=false`
  # so the command is typed but left for the user to press enter.
  defp startup_submit(params, session) do
    raw =
      params
      |> param_value("startup_submit")
      |> Kernel.||(present(to_string(Map.get(session, "startup_submit", ""))))

    raw not in ["false", "0", "no", "off"]
  end

  defp startup_command(profile), do: BusterClaw.TerminalCommands.startup_command(profile)

  defp param_value(params, key) when is_map(params), do: present(Map.get(params, key))
  defp param_value(_params, _key), do: nil

  defp sanitize_session_key(value) do
    value
    |> present()
    |> case do
      nil -> "main"
      value -> value
    end
    |> String.replace(~r/[^A-Za-z0-9._:-]+/, "-")
    |> String.trim("-")
    |> String.slice(0, 96)
    |> case do
      "" -> "main"
      key -> key
    end
  end

  defp label_from_session_key("main"), do: "Terminal"

  defp label_from_session_key(session_key) do
    session_key
    |> String.replace(~r/[-_.:]+/, " ")
    |> String.trim()
    |> case do
      "" -> "Terminal"
      label -> label
    end
  end

  defp present(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp present(_value), do: nil

  defp terminal_path(session_key, label, startup_profile) do
    query =
      [{"session", session_key}, {"label", label}]
      |> maybe_append_query("startup_profile", startup_profile)

    "/terminal?" <> URI.encode_query(query)
  end

  defp toolbar_button_class do
    "grid size-8 shrink-0 place-items-center rounded-sm text-base-content/60 transition hover:bg-base-content/10 hover:text-primary disabled:cursor-not-allowed disabled:opacity-35"
  end

  defp maybe_append_query(query, _key, nil), do: query
  defp maybe_append_query(query, key, value), do: query ++ [{key, value}]
end
