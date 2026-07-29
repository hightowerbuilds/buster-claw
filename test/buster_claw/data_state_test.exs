defmodule BusterClaw.DataStateTest do
  use ExUnit.Case, async: true

  alias BusterClaw.DataState

  test "cached data carries its status, timestamp, and source" do
    at = ~U[2026-07-27 18:00:00Z]

    assert %DataState{status: :fresh, data: [1], as_of: ^at, source: :quotes} =
             DataState.cached([1], false, as_of: at, source: :quotes)

    assert %DataState{status: :stale, data: [1], as_of: ^at} =
             DataState.cached([1], true, as_of: at)
  end

  test "confirmed empty is distinct from unavailable" do
    assert %DataState{status: :confirmed_empty, data: []} = DataState.confirmed_empty()

    assert %DataState{status: :unavailable, reason: :not_fetched} =
             DataState.unavailable(:not_fetched)
  end
end
