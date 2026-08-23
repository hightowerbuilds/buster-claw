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

  # Two kinds of view are let through, and conflating them is what broke this.
  #
  # DESTINATIONS — reachable during onboarding because the wizard sends you
  # there: the wizard itself (so it never redirects to itself) and the terminal
  # (the final onboarding step and the Claude Code install step both open it
  # before onboarding is marked complete).
  @allowed_destinations [
    BusterClawWeb.SetupLive,
    BusterClawWeb.TerminalLive
  ]

  # STICKY CHILDREN — app-wide LiveViews the layouts `live_render` on every
  # page. These are not destinations and are not optional: **a child LiveView
  # cannot redirect.** LiveView raises "cannot redirect from a child LiveView",
  # which is a 500 on whatever page mounted it. The root LiveView carries this
  # same hook and does the redirecting for the whole page, so letting the
  # children through costs nothing.
  #
  # On 08-23 this list was THREE entries short — `SoundBoardLive`, `DutyLive`
  # and `MusicPlayerLive` — so EVERY first launch served a 500 on `/setup` and
  # the app could not be onboarded at all. It shipped in 0.1.0 and was found by
  # installing the DMG on a real machine, not by the suite.
  #
  # Reading the layouts by hand found only `SoundBoardLive`. The other two were
  # found by the lockstep test the moment it was written, which is the argument
  # for writing it: a finding produced by reading is a lower bound.
  #
  # Two things kept it hidden. The tests reached the gate through `live/2`,
  # which connects the LiveView directly and never renders the root layout that
  # mounts the children; and the gate is off in the test env, so the branch only
  # runs where a test opts in. There is no runtime property that separates a
  # statically-rendered child from a statically-rendered root — measured, both
  # carry `parent_pid: nil` — so this cannot become a rule and has to stay a
  # list.
  #
  # `require_onboarding_test.exs` therefore reads the layouts and fails if any
  # `live_render(..., sticky: true)` names a module missing from here. Adding a
  # fifth sticky child now breaks the suite instead of the product.
  @sticky_children [
    BusterClawWeb.NotifyLive,
    BusterClawWeb.SoundBoardLive,
    BusterClawWeb.DockLive,
    BusterClawWeb.DockNavLive,
    BusterClawWeb.DutyLive,
    BusterClawWeb.MusicPlayerLive
  ]

  @allowed_views @allowed_destinations ++ @sticky_children

  @doc "Views that never redirect to /setup. Read by the lockstep test."
  def allowed_views, do: @allowed_views

  @doc "The sticky app-wide children the layouts render. Read by the lockstep test."
  def sticky_children, do: @sticky_children

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
