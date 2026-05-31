defmodule BusterClawWeb.OrchestrationLiveTest do
  use BusterClawWeb.ConnCase

  import Phoenix.LiveViewTest

  alias BusterClaw.Orchestration

  test "renders the schedule page with the section header", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/orchestration")
    assert html =~ "Schedule"
    assert html =~ "New task"
    assert html =~ "No active shift"
  end

  test "creates a pipeline task via the wizard", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/orchestration")

    # Step 1: pick Pipeline (auto-advances to Brief; command defaults to noop).
    view |> element(~s|button[phx-value-type="pipeline"]|) |> render_click()
    # Brief -> Schedule (once is the default).
    view |> element(~s|button[phx-click="wizard_next"]|) |> render_click()
    # Schedule -> Review.
    view |> element(~s|button[phx-click="wizard_next"]|) |> render_click()
    # Name it, then create.
    view |> form(~s|form[phx-change="wizard_change"]|, %{name: "Nightly noop"}) |> render_change()
    html = view |> element(~s|button[phx-click="wizard_create"]|) |> render_click()

    assert html =~ "Task added."
    assert html =~ "Nightly noop"

    assert [%{name: "Nightly noop", type: "pipeline", command: "noop"}] =
             Orchestration.list_tasks()
  end

  test "run_now queues a task immediately", %{conn: conn} do
    {:ok, task} = Orchestration.create_task(%{name: "later", type: "pipeline", command: "noop"})
    {:ok, view, _html} = live(conn, ~p"/orchestration")

    view
    |> element(~s|button[phx-click="run_now"][phx-value-id="#{task.id}"]|)
    |> render_click()

    reloaded = Orchestration.get_task!(task.id)
    assert reloaded.state == "pending"
    assert reloaded.due_at
  end

  test "delete removes a task", %{conn: conn} do
    {:ok, task} = Orchestration.create_task(%{name: "scrap", type: "pipeline", command: "noop"})
    {:ok, view, _html} = live(conn, ~p"/orchestration")

    view
    |> element(~s|button[phx-click="delete"][phx-value-id="#{task.id}"]|)
    |> render_click()

    assert Orchestration.list_tasks() == []
  end
end
