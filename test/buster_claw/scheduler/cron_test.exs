defmodule BusterClaw.Scheduler.CronTest do
  use ExUnit.Case, async: true

  alias BusterClaw.Scheduler.Cron

  test "computes the next run for common aliases" do
    assert {:ok, ~U[2026-05-26 11:00:00Z]} =
             Cron.next_run("@hourly", ~U[2026-05-26 10:15:30Z])

    assert {:ok, ~U[2026-05-27 00:00:00Z]} =
             Cron.next_run("@daily", ~U[2026-05-26 23:59:00Z])
  end

  test "supports lists, ranges, and steps" do
    assert {:ok, ~U[2026-05-26 09:15:00Z]} =
             Cron.next_run("*/15 9-17 * * 1-5", ~U[2026-05-26 09:01:00Z])

    assert {:ok, ~U[2026-05-26 17:45:00Z]} =
             Cron.next_run("15,45 9-17 * * 1-5", ~U[2026-05-26 17:16:00Z])
  end

  test "uses cron day-of-month or day-of-week matching semantics" do
    assert {:ok, ~U[2026-05-31 08:00:00Z]} =
             Cron.next_run("0 8 1 * 0", ~U[2026-05-30 08:00:00Z])

    assert {:ok, ~U[2026-06-01 08:00:00Z]} =
             Cron.next_run("0 8 1 * *", ~U[2026-05-31 08:00:00Z])
  end

  test "rejects unsupported or malformed expressions" do
    refute Cron.valid?("@reboot")
    refute Cron.valid?("not a cron")
    assert {:error, :invalid_cron} = Cron.next_run("99 * * * *", ~U[2026-05-26 09:00:00Z])
  end
end
