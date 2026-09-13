defmodule BusterClaw.DutyTest do
  # async: false — writes the STOP file and the trusted-senders policy under a
  # per-test workspace root, which is global app env.
  use BusterClaw.DataCase, async: false

  alias BusterClaw.{Dispatch, Duty, Google, Orchestration, Sentinel, TrustedSenders}

  setup do
    tmp = Path.join(System.tmp_dir!(), "bc_duty_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(tmp, "memory"))
    prev_ws = Application.get_env(:buster_claw, :workspace_root)
    Application.put_env(:buster_claw, :workspace_root, tmp)

    on_exit(fn ->
      if prev_ws,
        do: Application.put_env(:buster_claw, :workspace_root, prev_ws),
        else: Application.delete_env(:buster_claw, :workspace_root)

      File.rm_rf(tmp)
    end)

    :ok
  end

  defp healthy_account! do
    {:ok, account} =
      Google.create_account(%{
        "email" => "me@example.com",
        "client_id" => "id",
        "client_secret" => "secret",
        "refresh_token" => "refresh"
      })

    account
  end

  describe "readiness/1" do
    test "a fresh install is blocked three ways, in fix order" do
      assert %{ready?: false, blockers: blockers} = Duty.readiness(agent_cli?: false)
      assert Enum.map(blockers, & &1.key) == [:agent, :email, :senders]
      assert Enum.all?(blockers, &String.starts_with?(&1.href, "/"))
    end

    test "a connected account with no trusted sender is still blocked — nothing would be enqueued" do
      healthy_account!()
      assert %{ready?: false, blockers: [%{key: :senders}]} = Duty.readiness(agent_cli?: true)
    end

    test "an account that needs reconnecting does not count" do
      account = healthy_account!()
      Google.mark_reconnect_needed(Google.get_account!(account.id))
      {:ok, _} = TrustedSenders.add_entry("boss@example.com")

      assert %{ready?: false, blockers: [%{key: :email}]} = Duty.readiness(agent_cli?: true)
    end

    test "ready when every check passes" do
      healthy_account!()
      {:ok, _} = TrustedSenders.add_entry("boss@example.com")
      assert %{ready?: true, blockers: []} = Duty.readiness(agent_cli?: true)
    end
  end

  describe "go_on_duty/2" do
    test "refuses with the blockers rather than starting an empty shift" do
      assert {:error, {:not_ready, [%{key: :agent} | _]}} =
               Duty.go_on_duty(:dock, agent_cli?: false)

      refute Orchestration.shift_active?()
    end

    test "starts an unattended shift, clears a latched STOP, and lands on the Security feed" do
      healthy_account!()
      {:ok, _} = TrustedSenders.add_entry("boss@example.com")
      Orchestration.engage_kill_switch()

      assert {:ok, shift} = Duty.go_on_duty(:dock, agent_cli?: true)
      assert shift.unattended
      assert Orchestration.shift_active?()
      refute Orchestration.kill_switch_engaged?()

      assert Enum.any?(Sentinel.list_events(), fn e ->
               to_string(e.category) == "command_invoke" and
                 e.message =~ "started by the operator (dock)"
             end)
    end
  end

  describe "stand_down/1" do
    test "latches STOP first, then stops the shift" do
      {:ok, _} = Orchestration.start_shift(unattended: true)
      assert {:ok, _} = Duty.stand_down(:dock)
      assert Orchestration.kill_switch_engaged?()
      refute Orchestration.shift_active?()
    end

    test "with nothing running it still latches, and says so" do
      assert {:ok, :latched} = Duty.stand_down(:duty_page)
      assert Orchestration.kill_switch_engaged?()
    end
  end

  describe "the queue counts" do
    test "count_open counts queued, claimed and running; count_queued only queued" do
      assert Dispatch.count_open() == 0
      {:ok, a} = Dispatch.enqueue(%{source: "gmail", subject: "a", dedupe_key: "a"})
      {:ok, b} = Dispatch.enqueue(%{source: "gmail", subject: "b", dedupe_key: "b"})
      {:ok, _} = Dispatch.update_item(b, %{status: "running"})
      {:ok, _} = Dispatch.update_item(a, %{status: "queued"})

      assert Dispatch.count_open() == 2
      assert Dispatch.count_queued() == 1

      {:ok, _} = Dispatch.update_item(b, %{status: "done"})
      assert Dispatch.count_open() == 1
    end
  end
end
