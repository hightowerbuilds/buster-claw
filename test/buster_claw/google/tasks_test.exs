defmodule BusterClaw.Google.TasksTest do
  use BusterClaw.DataCase, async: true

  alias BusterClaw.Google
  alias BusterClaw.Google.Tasks

  @plug [plug: {Req.Test, BusterClaw.GoogleHTTP}]

  setup do
    Req.Test.verify_on_exit!()
    :ok
  end

  test "list_tasklists returns the account's lists" do
    Req.Test.stub(BusterClaw.GoogleHTTP, fn conn ->
      assert conn.request_path == "/tasks/v1/users/@me/lists"
      Req.Test.json(conn, %{"items" => [%{"id" => "list-1", "title" => "My Tasks"}]})
    end)

    assert {:ok, %{tasklists: [%{id: "list-1", title: "My Tasks"}]}} =
             Tasks.list_tasklists(connected_account!(), req_options: @plug)
  end

  test "list_tasks returns the tasks in a list" do
    Req.Test.stub(BusterClaw.GoogleHTTP, fn conn ->
      assert conn.request_path == "/tasks/v1/lists/list-1/tasks"
      assert conn.query_params["showCompleted"] == "true"
      Req.Test.json(conn, %{"items" => [%{"id" => "t-1", "title" => "Ship it", "status" => "needsAction"}]})
    end)

    assert {:ok, %{tasklist_id: "list-1", tasks: [%{id: "t-1", title: "Ship it"}]}} =
             Tasks.list_tasks(connected_account!(), "list-1", req_options: @plug)
  end

  test "create_task posts a new task" do
    Req.Test.stub(BusterClaw.GoogleHTTP, fn conn ->
      assert conn.method == "POST"
      assert conn.request_path == "/tasks/v1/lists/list-1/tasks"
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert Jason.decode!(body) == %{"title" => "Ship it", "notes" => "today"}
      Req.Test.json(conn, %{"id" => "t-1", "title" => "Ship it", "status" => "needsAction"})
    end)

    assert {:ok, %{id: "t-1", title: "Ship it"}} =
             Tasks.create_task(
               connected_account!(),
               "list-1",
               %{"title" => "Ship it", "notes" => "today"},
               req_options: @plug
             )
  end

  test "update_task patches a task" do
    Req.Test.stub(BusterClaw.GoogleHTTP, fn conn ->
      assert conn.method == "PATCH"
      assert conn.request_path == "/tasks/v1/lists/list-1/tasks/t-1"
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert Jason.decode!(body) == %{"status" => "completed"}
      Req.Test.json(conn, %{"id" => "t-1", "status" => "completed"})
    end)

    assert {:ok, %{id: "t-1", status: "completed"}} =
             Tasks.update_task(
               connected_account!(),
               "list-1",
               "t-1",
               %{"status" => "completed"},
               req_options: @plug
             )
  end

  test "delete_task removes a task" do
    Req.Test.stub(BusterClaw.GoogleHTTP, fn conn ->
      assert conn.method == "DELETE"
      assert conn.request_path == "/tasks/v1/lists/list-1/tasks/t-1"
      Plug.Conn.send_resp(conn, 204, "")
    end)

    assert {:ok, %{id: "t-1", tasklist_id: "list-1", deleted: true}} =
             Tasks.delete_task(connected_account!(), "list-1", "t-1", req_options: @plug)
  end

  defp connected_account! do
    {:ok, account} =
      Google.create_account(%{
        "email" => "me@example.com",
        "client_id" => "client-id",
        "client_secret" => "client-secret",
        "refresh_token" => "refresh-token",
        "access_token" => "access-token",
        "access_token_expires_at" => DateTime.utc_now() |> DateTime.add(3600, :second)
      })

    account
  end
end
