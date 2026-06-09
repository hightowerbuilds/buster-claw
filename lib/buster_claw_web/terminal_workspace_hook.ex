defmodule BusterClawWeb.TerminalWorkspaceHook do
  @moduledoc """
  Top-level LiveView bridge for terminal workspace requests.

  Connected shell views subscribe to `BusterClaw.TerminalWorkspace` and push
  `bc:open_terminal` events to the browser. Embedded split-pane children skip
  the subscription because only the outer shell owns the tab strip.
  """

  alias BusterClaw.TerminalWorkspace

  def on_mount(:default, _params, session, socket) do
    socket =
      if Phoenix.LiveView.connected?(socket) and session["embedded"] != true do
        TerminalWorkspace.subscribe()

        TerminalWorkspace.drain_pending()
        |> Enum.reduce(socket, &push_terminal_event/2)
      else
        socket
      end

    socket =
      Phoenix.LiveView.attach_hook(socket, :terminal_workspace, :handle_info, fn
        {:terminal_workspace, {:open, request}}, socket ->
          TerminalWorkspace.ack(request.id)
          {:halt, push_terminal_event(request, socket)}

        _message, socket ->
          {:cont, socket}
      end)

    {:cont, socket}
  end

  defp push_terminal_event(request, socket) do
    Phoenix.LiveView.push_event(socket, "bc:open_terminal", request)
  end
end
