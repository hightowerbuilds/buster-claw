defmodule BusterClawWeb.RequireOnboarding do
  @moduledoc """
  LiveView `on_mount` hook that gates the main app behind first-run setup.

  When onboarding has not been completed, any mounted LiveView (other than the
  setup wizard itself) redirects to `/setup`, so the wizard auto-launches on
  first run. Once `BusterClaw.Settings.onboarding_completed?/0` is true the hook
  is a no-op and every route is reachable as normal.

  The setup view is let through unconditionally so the wizard is reachable and
  never redirects to itself. The terminal view is also let through: the final
  onboarding step (and the Claude Code install step) opens `/terminal` before
  onboarding is marked complete, so gating it would bounce the user back.
  """

  import Phoenix.LiveView, only: [push_navigate: 2]

  # Views reachable during onboarding (before it is marked complete).
  @allowed_views [BusterClawWeb.SetupLive, BusterClawWeb.TerminalLive]

  def on_mount(:default, _params, _session, socket) do
    cond do
      not gate_enabled?() ->
        {:cont, socket}

      BusterClaw.Settings.onboarding_completed?() ->
        {:cont, socket}

      socket.view in @allowed_views ->
        {:cont, socket}

      true ->
        {:halt, push_navigate(socket, to: "/setup")}
    end
  end

  # The gate is on by default (dev/prod); disabled in the test env so the broad
  # LiveView suite isn't forced through onboarding. The first-run tests flip it
  # on explicitly.
  defp gate_enabled?, do: Application.get_env(:buster_claw, :onboarding_gate, true)
end
