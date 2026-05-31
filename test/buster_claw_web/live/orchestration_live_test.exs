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

  test "creates a pipeline task via the form", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/orchestration")

    html =
      view
      |> form("#task-form", task: %{name: "Nightly noop", type: "pipeline", command: "noop"})
      |> render_submit()

    assert html =~ "Nightly noop"
    assert html =~ "Task added."
    assert [%{name: "Nightly noop", type: "pipeline", command: "noop"}] = Orchestration.list_tasks()
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
