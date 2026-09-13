defmodule BusterClaw.MailmanTest do
  # async: false — the STOP file and the journal live under a per-test
  # workspace root, which is global app env.
  use BusterClaw.DataCase, async: false

  alias BusterClaw.{Google, Journal, Mailman, Orchestration}

  setup do
    tmp = Path.join(System.tmp_dir!(), "bc_mailman_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    prev_ws = Application.get_env(:buster_claw, :workspace_root)
    Application.put_env(:buster_claw, :workspace_root, tmp)

    on_exit(fn ->
      if prev_ws,
        do: Application.put_env(:buster_claw, :workspace_root, prev_ws),
        else: Application.delete_env(:buster_claw, :workspace_root)

      File.rm_rf(tmp)
    end)

    %{tmp: tmp}
  end

  defp account!(email, attrs \\ %{}) do
    {:ok, account} =
      Google.create_account(
        Map.merge(
          %{
            "email" => email,
            "client_id" => "id",
            "client_secret" => "s",
            "refresh_token" => "r"
          },
          attrs
        )
      )

    account
  end

  # A sync that reports which account it was asked about, without touching Gmail.
  defp recording_sync(test_pid) do
    fn account ->
      send(test_pid, {:synced, account.email})
      {:ok, %{}}
    end
  end

  defp state(test_pid),
    do: %{interval_ms: 60_000, sync: recording_sync(test_pid), announced_shift: nil}

  test "does nothing with no shift" do
    account!("me@example.com")
    Mailman.tick(state(self()))
    refute_receive {:synced, _}
  end

  test "does nothing on an ATTENDED shift — that one is worked by the terminal agent" do
    account!("me@example.com")
    {:ok, _} = Orchestration.start_shift(unattended: false)
    Mailman.tick(state(self()))
    refute_receive {:synced, _}
  end

  test "does nothing while the kill switch is latched" do
    account!("me@example.com")
    {:ok, _} = Orchestration.start_shift(unattended: true)
    Orchestration.engage_kill_switch()
    Mailman.tick(state(self()))
    refute_receive {:synced, _}
  end

  test "syncs each healthy account on an unattended shift, and skips the unhealthy one" do
    account!("me@example.com")
    account!("also@example.com")
    sick = account!("sick@example.com")
    Google.mark_reconnect_needed(Google.get_account!(sick.id))

    {:ok, _} = Orchestration.start_shift(unattended: true)
    Mailman.tick(state(self()))

    assert_receive {:synced, "also@example.com"}
    assert_receive {:synced, "me@example.com"}
    refute_receive {:synced, "sick@example.com"}
  end

  test "announces the watch in the journal once per shift, not once per tick" do
    account!("me@example.com")
    {:ok, shift} = Orchestration.start_shift(unattended: true)

    state = Mailman.tick(state(self()))
    assert state.announced_shift == shift.id
    state = Mailman.tick(state)
    assert state.announced_shift == shift.id

    %{body: today} = Journal.get(Journal.today_name())
    assert length(Regex.scan(~r/Mailman: watching Gmail/, today)) == 1
  end

  test "a failing sync is logged and does not stop the others" do
    account!("a@example.com")
    account!("b@example.com")
    {:ok, _} = Orchestration.start_shift(unattended: true)
    test_pid = self()

    sync = fn account ->
      send(test_pid, {:synced, account.email})
      if account.email == "a@example.com", do: {:error, :boom}, else: {:ok, %{}}
    end

    Mailman.tick(%{interval_ms: 60_000, sync: sync, announced_shift: nil})
    assert_receive {:synced, "a@example.com"}
    assert_receive {:synced, "b@example.com"}
  end

  test "the ticker is supervised and can be nudged" do
    account!("me@example.com")
    {:ok, _} = Orchestration.start_shift(unattended: true)

    pid =
      start_supervised!(
        {Mailman, name: :mailman_test, autostart: false, sync: recording_sync(self())}
      )

    Mailman.tick_now(pid)
    assert_receive {:synced, "me@example.com"}
  end
end
