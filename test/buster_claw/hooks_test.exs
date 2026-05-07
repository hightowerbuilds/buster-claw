defmodule BusterClaw.HooksTest do
  use BusterClaw.DataCase

  alias BusterClaw.Hooks

  setup do
    Req.Test.verify_on_exit!()
    :ok
  end

  test "executes shell hooks and records bounded output" do
    assert {:ok, hook} =
             Hooks.create_hook(%{
               name: "shell-ok",
               event: "post_ingest",
               type: "shell",
               target: "printf ok"
             })

    assert {:ok, run} = Hooks.test_hook(hook)
    assert run.success
    assert run.stdout == "ok"
    assert run.status_code == 0
    assert run.payload == %{"test" => true}
  end

  test "records failing shell hooks" do
    assert {:ok, hook} =
             Hooks.create_hook(%{
               name: "shell-fail",
               event: "on_error",
               type: "shell",
               target: "printf nope && exit 3"
             })

    assert {:ok, run} = Hooks.test_hook(hook)
    refute run.success
    assert run.status_code == 3
    assert run.error == "Shell hook exited with 3"
    assert run.stdout == "nope"
  end

  test "executes webhook hooks through Req test stubs" do
    Req.Test.stub(BusterClaw.HookHTTP, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert body =~ "webhook-ok"
      Req.Test.json(conn, %{received: true})
    end)

    assert {:ok, hook} =
             Hooks.create_hook(%{
               name: "webhook-ok",
               event: "post_report",
               type: "webhook",
               target: "https://example.com/hook"
             })

    assert {:ok, run} =
             Hooks.test_hook(hook,
               payload: %{"report_id" => 123},
               req_options: [plug: {Req.Test, BusterClaw.HookHTTP}]
             )

    assert run.success
    assert run.status_code == 200
    assert run.stdout =~ "received"
  end

  test "execute_event only runs enabled hooks for the event" do
    assert {:ok, enabled} =
             Hooks.create_hook(%{
               name: "enabled",
               event: "pre_ingest",
               type: "shell",
               target: "printf enabled"
             })

    assert {:ok, disabled} =
             Hooks.create_hook(%{
               name: "disabled",
               event: "pre_ingest",
               type: "shell",
               target: "printf disabled",
               enabled: false
             })

    assert [{:ok, %{hook_id: hook_id, stdout: "enabled"}}] = Hooks.execute_event("pre_ingest")
    assert hook_id == enabled.id
    assert Hooks.list_hooks() == [disabled, enabled]
  end
end
