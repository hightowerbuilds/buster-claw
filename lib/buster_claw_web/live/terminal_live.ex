defmodule BusterClawWeb.TerminalLive do
  @moduledoc """
  Terminal tab. The view is just a host for xterm.js (the `TerminalView` JS
  hook); the shell runs in a PTY in the Tauri Rust backend, streamed over IPC.
  Works in the desktop app; in a plain browser the hook shows a notice.
  """
  use BusterClawWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, :page_title, "Terminal")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <section class="space-y-4">
        <div>
          <p class="text-sm font-semibold uppercase tracking-wide text-base-content/60">
            Shell
          </p>
          <h1 class="text-4xl font-semibold tracking-normal">Terminal</h1>
          <p class="mt-2 text-base text-base-content/70">
            A live shell running in a PTY, rendered with xterm.js.
          </p>
        </div>

        <div
          id="terminal-root"
          phx-hook="TerminalView"
          phx-update="ignore"
          class="h-[70vh] overflow-hidden rounded-lg border border-base-300 bg-[#1e1e2e] p-2 shadow-sm"
        >
        </div>
      </section>
    </Layouts.app>
    """
  end
end
