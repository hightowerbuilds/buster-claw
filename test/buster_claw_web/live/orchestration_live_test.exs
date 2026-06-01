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

  test "creates a GWS sync action via the wizard", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/orchestration")

    # Pick GWS action (auto-advances to Brief; gmail_sync is the default action).
    view |> element(~s|button[phx-value-type="gws"]|) |> render_click()
    render_hook(view, "wizard_change", %{"gws_query" => "newer_than:7d", "gws_limit" => "5"})
    # Brief -> Schedule (once default) -> Review.
    view |> element(~s|button[phx-click="wizard_next"]|) |> render_click()
    view |> element(~s|button[phx-click="wizard_next"]|) |> render_click()
    render_hook(view, "wizard_change", %{"name" => "Daily Gmail sync"})
    html = view |> element(~s|button[phx-click="wizard_create"]|) |> render_click()

    assert html =~ "Task added."

    assert [task] = Orchestration.list_tasks()
    assert task.name == "Daily Gmail sync"
    assert task.type == "pipeline"
    assert task.command == "gmail_sync"
    assert task.params["query"] == "newer_than:7d"
    assert task.params["limit"] == 5
  end

  test "creates a gmail_send action with confirm_send pre-authorized", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/orchestration")

    view |> element(~s|button[phx-value-type="gws"]|) |> render_click()

    render_hook(view, "wizard_change", %{
      "gws_action" => "gmail_send",
      "gws_to" => "ops@example.com",
      "gws_subject" => "Nightly report",
      "gws_body" => "See the workspace."
    })

    view |> element(~s|button[phx-click="wizard_next"]|) |> render_click()
    view |> element(~s|button[phx-click="wizard_next"]|) |> render_click()
    render_hook(view, "wizard_change", %{"name" => "Send nightly report"})
    view |> element(~s|button[phx-click="wizard_create"]|) |> render_click()

    assert [task] = Orchestration.list_tasks()
    assert task.type == "pipeline"
    assert task.command == "gmail_send"
    assert task.params["confirm_send"] == true
    assert task.params["to"] == "ops@example.com"
    assert task.params["subject"] == "Nightly report"
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
