defmodule BusterClawWeb.DutyLiveTest do
  # async: false — shifts and the STOP file are global state, and the sticky dock
  # child reads both.
  use BusterClawWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias BusterClaw.Orchestration

  setup do
    on_exit(&Orchestration.clear_kill_switch/0)
  end

  # The gate `G-30` closes. Before 08-16 the answer to "how do I stop it" was a
  # command typed into a terminal, in an app whose wizard promises no terminal
  # knowledge is needed.
  test "the brake is absent when nothing is running", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/calendar")

    duty = find_live_child(view, "bc-duty-dock")
    assert duty, "expected the sticky bc-duty-dock child"

    html = render(duty)
    refute html =~ "Stand down"
    refute html =~ "On duty"
  end

  test "a running shift shows the brake on every page", %{conn: conn} do
    {:ok, _shift} = Orchestration.start_shift()

    # Deliberately not the homepage: the whole reason this is a sticky child is
    # that a shift started elsewhere must still be visible and stoppable here.
    {:ok, view, _html} = live(conn, ~p"/terminal")
    html = view |> find_live_child("bc-duty-dock") |> render()

    assert html =~ "On duty"
    assert html =~ "Stand down"
  end

  test "an unattended shift says it is working on its own", %{conn: conn} do
    {:ok, _shift} = Orchestration.start_shift(unattended: true)

    {:ok, view, _html} = live(conn, ~p"/calendar")
    html = view |> find_live_child("bc-duty-dock") |> render()

    # "Working on its own" is a claim only the Dispatcher-driven shift earns; an
    # attended one is a human at a terminal working the same queue.
    assert html =~ "working on its own"
  end

  test "the limit is stated beside the button, not hidden in a tooltip", %{conn: conn} do
    {:ok, _shift} = Orchestration.start_shift(unattended: true)

    {:ok, view, _html} = live(conn, ~p"/calendar")
    html = view |> find_live_child("bc-duty-dock") |> render()

    # `stand_down` closes the door on new work at once, but the Dispatcher
    # monitors a running run rather than killing it — nothing in this app cancels
    # a headless run mid-flight. A brake that overstates its reach is worse than
    # one that names its limit, so the sentence must be on the surface.
    assert html =~ "Stops new work at once"
    assert html =~ "a run in progress finishes"
  end

  test "Stand down stops the shift, latches the brake, and clears the control", %{conn: conn} do
    {:ok, _shift} = Orchestration.start_shift(unattended: true)

    {:ok, view, _html} = live(conn, ~p"/calendar")
    duty = find_live_child(view, "bc-duty-dock")

    duty |> element("#bc-duty-stand-down") |> render_click()

    refute Orchestration.shift_active?()
    assert Orchestration.kill_switch_engaged?()

    # The control removes itself: with nothing running there is nothing to stop,
    # and a brake left on screen saying "idle" is how the eye learns to skip it.
    refute render(duty) =~ "Stand down"
  end

  test "the brake carries no confirmation gate, and that is deliberate", %{conn: conn} do
    {:ok, _shift} = Orchestration.start_shift()

    {:ok, view, _html} = live(conn, ~p"/calendar")
    html = view |> find_live_child("bc-duty-dock") |> render()

    # `data-claw-confirm` is the house idiom for destructive controls and this
    # opts out on purpose: an emergency brake that asks "are you sure" adds
    # friction at the one moment friction is most expensive. If someone adds a
    # confirmation later this fails, and the argument is in `DutyLive`'s
    # moduledoc for them to argue with.
    refute html =~ "data-claw-confirm"
  end

  test "a shift started elsewhere appears without a reload", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/calendar")
    duty = find_live_child(view, "bc-duty-dock")
    refute render(duty) =~ "Stand down"

    # The reason this is a nested LiveView at all: an app layout renders once at
    # mount and is never part of a later diff, so a shift begun from the CLI or
    # from an agent while the operator sits on another page would otherwise stay
    # invisible until they navigated.
    {:ok, _shift} = Orchestration.start_shift()

    assert render(duty) =~ "Stand down"
  end
end
