defmodule BusterClawWeb.AppearanceLive do
  @moduledoc """
  Appearance settings (Settings → Appearance sub-tab). Theme selection is
  applied client-side: the buttons dispatch `phx:set-theme`, which the inline
  script in `root.html.heex` persists to `localStorage["phx:theme"]` and applies
  via the `data-theme` attribute.
  """
  use BusterClawWeb, :live_view

  # Swatch metadata for the terminal-theme picker. The actual xterm palettes
  # live in `assets/js/app.js` (TERM_THEMES); `key` must match. bg/fg/accent are
  # only used to render the preview chip. "industrial" mirrors the app's tokens.
  @terminal_themes [
    %{key: "industrial", label: "Industrial", bg: "#121212", fg: "#f4f1ea", accent: "#ff4d1c"},
    %{key: "dracula", label: "Dracula", bg: "#282a36", fg: "#f8f8f2", accent: "#bd93f9"},
    %{key: "solarized", label: "Solarized", bg: "#002b36", fg: "#839496", accent: "#2aa198"},
    %{key: "nord", label: "Nord", bg: "#2e3440", fg: "#d8dee9", accent: "#88c0d0"},
    %{key: "gruvbox", label: "Gruvbox", bg: "#282828", fg: "#ebdbb2", accent: "#fabd2f"},
    %{key: "monokai", label: "Monokai", bg: "#272822", fg: "#f8f8f2", accent: "#a6e22e"},
    %{key: "tokyo-night", label: "Tokyo Night", bg: "#1a1b26", fg: "#c0caf5", accent: "#7aa2f7"},
    %{key: "light", label: "Light", bg: "#fafafa", fg: "#1a1a1a", accent: "#2563eb"},
    %{key: "matrix", label: "Matrix", bg: "#000000", fg: "#00ff41", accent: "#00ff41"}
  ]

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Appearance")
     |> assign(:terminal_themes, @terminal_themes)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <section class="space-y-6">
        <BusterClawWeb.SettingsTabs.tabs active={:appearance} />

        <section class="ic-panel space-y-4 p-6">
          <h2 class="ic-eyebrow">Theme</h2>
          <p class="max-w-2xl text-sm leading-7 text-base-content/70">
            Choose how Buster Claw looks. <span class="font-semibold">System</span>
            follows your operating system's appearance.
          </p>
          <div class="flex flex-wrap gap-2">
            <button
              type="button"
              phx-click={JS.dispatch("phx:set-theme")}
              data-phx-theme="system"
              class={theme_btn()}
            >
              <.icon name="hero-computer-desktop" class="size-4" /> System
            </button>
            <button
              type="button"
              phx-click={JS.dispatch("phx:set-theme")}
              data-phx-theme="light"
              class={theme_btn()}
            >
              <.icon name="hero-sun" class="size-4" /> Light
            </button>
            <button
              type="button"
              phx-click={JS.dispatch("phx:set-theme")}
              data-phx-theme="dark"
              class={theme_btn()}
            >
              <.icon name="hero-moon" class="size-4" /> Dark
            </button>
          </div>
        </section>

        <section class="ic-panel space-y-4 p-6">
          <h2 class="ic-eyebrow">Terminal theme</h2>
          <p class="max-w-2xl text-sm leading-7 text-base-content/70">
            Color scheme for the in-app terminal — background, text, cursor, and ANSI colors.
            Applies to open terminals immediately.
          </p>
          <div id="terminal-theme-picker" phx-hook="TermThemePicker" class="grid gap-3 sm:grid-cols-2 lg:grid-cols-3">
            <button
              :for={t <- @terminal_themes}
              type="button"
              phx-click={JS.dispatch("bc:set-term-theme")}
              data-term-theme={t.key}
              title={t.label}
              class="group flex items-center gap-3 rounded-lg border-2 border-base-content/20 p-2.5 text-left transition hover:border-primary focus:outline-none"
            >
              <span
                class="flex size-11 shrink-0 flex-col items-start justify-center gap-1 rounded-md px-2 font-mono"
                style={"background:#{t.bg}"}
              >
                <span class="text-xs font-bold leading-none" style={"color:#{t.fg}"}>$ ls</span>
                <span class="h-1.5 w-5 rounded-full" style={"background:#{t.accent}"}></span>
              </span>
              <span class="min-w-0">
                <span class="block text-sm font-semibold">{t.label}</span>
                <span class="block font-mono text-xs text-base-content/55">{t.key}</span>
              </span>
            </button>
          </div>
        </section>
      </section>
    </Layouts.app>
    """
  end

  defp theme_btn,
    do:
      "inline-flex items-center gap-2 rounded border-2 border-base-content/30 px-4 py-2 text-sm font-semibold transition hover:border-primary hover:text-primary"
end
