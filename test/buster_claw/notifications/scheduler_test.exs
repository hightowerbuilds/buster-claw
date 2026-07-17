defmodule BusterClaw.Notifications.SchedulerTest do
  use BusterClaw.DataCase

  alias BusterClaw.Notifications
  alias BusterClaw.Notifications.Scheduler

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)

  test "fires a due notification and broadcasts it" do
    Notifications.subscribe()
    pid = start_supervised!({Scheduler, name: nil, subscribe: true, max_idle_ms: 50})

    {:ok, _armed} =
      Notifications.create_notification(%{
        "kind" => "alarm",
        "label" => "ping",
        "fire_at" => DateTime.add(now(), -5, :second)
      })

    # Arming happens off the :changed broadcast; nudge for determinism.
    Scheduler.tick_now(pid)

    assert_receive {:notification_fired, %{label: "ping"}}, 1000
  end

  test "leaves a future notification armed" do
    Notifications.subscribe()
    pid = start_supervised!({Scheduler, name: nil, subscribe: true, max_idle_ms: 50})

    {:ok, future} =
      Notifications.create_notification(%{
        "kind" => "alarm",
        "label" => "later",
        "fire_at" => DateTime.add(now(), 3600, :second)
      })

    Scheduler.tick_now(pid)

    refute_receive {:notification_fired, _}, 200
    assert Notifications.get_notification(future.id).status == "pending"
  end
end
