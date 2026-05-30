defmodule BusterClawWeb.TerminalLive do
  @moduledoc """
  Terminal tab. The view is just a host for xterm.js (the `TerminalView` JS
  hook); the shell runs in a PTY in the Tauri Rust backend, streamed over IPC.
  Works in the desktop app; in a plain browser the hook shows a notice.

  In a split pane (embedded), the page header is dropped so the pane is just
  the terminal window.
  """
  use BusterClawWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    # Unique id so two terminal panes in one split view don't collide.
    {:ok,
     socket
     |> assign(:page_title, "Terminal")
     |> assign(:embedded?, BusterClawWeb.ChromeHook.embedded?())
     |> assign(:dom_id, "terminal-root-#{System.unique_integer([:positive])}")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <section class={if @embedded?, do: "h-full", else: "space-y-4"}>
        <div :if={not @embedded?}>
          <p class="text-sm font-semibold uppercase tracking-wide text-base-content/60">
            Shell
          </p>
          <h1 class="text-4xl font-semibold tracking-normal">Terminal</h1>
          <p class="mt-2 text-base text-base-content/70">
            A live shell running in a PTY, rendered with xterm.js.
          </p>
        </div>

        <div
          id={@dom_id}
          phx-hook="TerminalView"
          phx-update="ignore"
          class={[
            "overflow-hidden bg-[#1e1e2e]",
            if(@embedded?,
              do: "h-full",
              else: "h-[70vh] rounded-lg border border-base-300 p-2 shadow-sm"
            )
          ]}
        >
        </div>
      </section>
    </Layouts.app>
    """
  end
end
