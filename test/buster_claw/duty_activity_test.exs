defmodule BusterClaw.DutyActivityTest do
  use BusterClaw.DataCase

  alias BusterClaw.{DutyActivity, Sentinel}

  test "older records stay in the archive and outside the current shift feed" do
    {:ok, old} = Sentinel.observe(:command_invoke, "Earlier shift", %{})
    start = DateTime.add(old.inserted_at, 60, :second)
    assert DutyActivity.list(%{started_at: start}) == []
    assert Enum.any?(Sentinel.list_events(), &(&1.id == old.id))
  end
end
