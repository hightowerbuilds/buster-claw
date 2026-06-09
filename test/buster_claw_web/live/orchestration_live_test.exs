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

  test "schedule lists non-cron tasks above recurring ones", %{conn: conn} do
    {:ok, _recurring} =
      Orchestration.create_task(%{
        name: "AAA recurring",
        type: "pipeline",
        command: "noop",
        cron: "0 9 * * *"
      })

    {:ok, _one_shot} =
      Orchestration.create_task(%{
        name: "ZZZ one-shot",
        type: "pipeline",
        command: "noop",
        due_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })

    {:ok, _view, html} = live(conn, ~p"/orchestration")

    assert html =~ "Recurring"
    # The one-shot renders before the recurring task despite alphabetical order.
    [before_one_shot, _rest] = String.split(html, "ZZZ one-shot", parts: 2)
    refute before_one_shot =~ "AAA recurring"
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

  test "delete is gated behind a confirmation modal", %{conn: conn} do
    {:ok, task} = Orchestration.create_task(%{name: "scrap", type: "pipeline", command: "noop"})
    {:ok, view, _html} = live(conn, ~p"/orchestration")

    # Clicking delete opens the confirm modal but does NOT delete yet.
    html =
      view
      |> element(~s|button[phx-click="confirm_delete"][phx-value-id="#{task.id}"]|)
      |> render_click()

    assert html =~ "Delete task"
    assert html =~ "scrap"
    assert [_task] = Orchestration.list_tasks()

    # Cancel keeps it.
    view |> element(~s|button[phx-click="cancel_delete"]|) |> render_click()
    assert [_task] = Orchestration.list_tasks()

    # Re-open and confirm → gone.
    view
    |> element(~s|button[phx-click="confirm_delete"][phx-value-id="#{task.id}"]|)
    |> render_click()

    view |> element(~s|button[phx-click="delete_confirmed"]|) |> render_click()
    assert Orchestration.list_tasks() == []
  end

  test "edit updates a task's name, schedule and enabled state", %{conn: conn} do
    {:ok, task} =
      Orchestration.create_task(%{name: "old name", type: "pipeline", command: "noop"})

    {:ok, view, _html} = live(conn, ~p"/orchestration")

    html =
      view
      |> element(~s|button[phx-click="edit_task"][phx-value-id="#{task.id}"]|)
      |> render_click()

    assert html =~ "Edit task"

    render_hook(view, "edit_change", %{
      "name" => "new name",
      "schedule" => "recurring",
      "cron" => "0 9 * * *",
      "enabled" => "false"
    })

    view |> element(~s|form[phx-submit="save_edit"]|) |> render_submit()

    reloaded = Orchestration.get_task!(task.id)
    assert reloaded.name == "new name"
    assert reloaded.cron == "0 9 * * *"
    refute reloaded.enabled
  end

  test "edit rejects an invalid cron and keeps the task unchanged", %{conn: conn} do
    {:ok, task} =
      Orchestration.create_task(%{name: "keep", type: "pipeline", command: "noop"})

    {:ok, view, _html} = live(conn, ~p"/orchestration")

    view
    |> element(~s|button[phx-click="edit_task"][phx-value-id="#{task.id}"]|)
    |> render_click()

    render_hook(view, "edit_change", %{
      "name" => "keep",
      "schedule" => "recurring",
      "cron" => "not a cron"
    })

    html = view |> element(~s|form[phx-submit="save_edit"]|) |> render_submit()

    assert html =~ "valid cron"
    assert Orchestration.get_task!(task.id).name == "keep"
  end
end
