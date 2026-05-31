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
  def mount(_params, _session, socket) do
    # Unique id so two terminal panes in one split view don't collide.
    {:ok,
     socket
     |> assign(:page_title, "Terminal")
     |> assign(:embedded?, BusterClawWeb.ChromeHook.embedded?())
     |> assign(:cwd, Artifact.workspace_root())
     |> assign(:dom_id, "terminal-root-#{System.unique_integer([:positive])}")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <section class={if @embedded?, do: "h-full", else: "-mt-8"}>
        <div
          id={@dom_id}
          phx-hook="TerminalView"
          phx-update="ignore"
          data-cwd={@cwd}
          class={[
            "overflow-hidden bg-base-100",
            if(@embedded?,
              do: "h-full",
              else: "ic-panel h-[70vh] p-2"
            )
          ]}
        >
        </div>
      </section>
    </Layouts.app>
    """
  end
end
