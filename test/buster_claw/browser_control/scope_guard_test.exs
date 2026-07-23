defmodule BusterClaw.BrowserControl.ScopeGuardTest do
  @moduledoc """
  `Scope.guard/2` — the Sentinel-emitting wrapper. A halt must surface on the
  security feed so an injected action is visible as an action with no legitimate
  cause; an allow must stay silent.
  """
  use BusterClaw.DataCase, async: false

  alias BusterClaw.BrowserControl.Scope
  alias BusterClaw.Sentinel

  setup do
    Phoenix.PubSub.subscribe(BusterClaw.PubSub, Sentinel.topic())
    :ok
  end

  defp scope, do: Scope.new("buy printer paper", ["example.com"], id: "guard_test")

  test "an out-of-scope halt records a critical security_block event" do
    assert {:halt, :out_of_scope, _} =
             Scope.guard(scope(), {:navigate, "https://evil.com/transfer"})

    assert_receive {:security_event, event}, 1_000
    assert event.category == "security_block"
    assert event.severity == "critical"
    assert event.message =~ "scope halt (out_of_scope)"
  end

  test "a payment halt is recorded too" do
    assert {:halt, :payment_stop, _} =
             Scope.guard(scope(), {:navigate, "https://example.com/checkout"})

    assert_receive {:security_event, event}, 1_000
    assert event.message =~ "payment_stop"
  end

  test "an allowed action emits no security event" do
    assert {:ok, _origin} = Scope.guard(scope(), {:navigate, "https://example.com/products"})
    refute_receive {:security_event, _}, 200
  end

  test "the recorded event carries the frozen scope id and intent" do
    Scope.guard(scope(), {:navigate, "https://evil.com/"})
    assert_receive {:security_event, event}, 1_000
    assert event.metadata["scope_id"] == "guard_test"
    assert event.metadata["intent"] == "buy printer paper"
  end
end
