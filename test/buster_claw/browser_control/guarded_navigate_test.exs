defmodule BusterClaw.BrowserControl.GuardedNavigateTest do
  @moduledoc """
  The gate is load-bearing: `BrowserControl.navigate/3` runs `Scope.guard/2`
  first, and a haltable URL never reaches the session. The composition is proven
  with a recording session double (no browser) so "never navigated" is exact;
  the real engine integration is in `GuardedNavigateLiveTest`.
  """
  use BusterClaw.DataCase, async: false

  alias BusterClaw.BrowserControl
  alias BusterClaw.BrowserControl.Scope

  # Records every navigate it is asked to perform, standing in for Session.
  defmodule RecordingSession do
    use Agent
    def start_link, do: Agent.start_link(fn -> [] end)
    def navigate(pid, url), do: Agent.update(pid, &[url | &1]) && :ok
    def urls(pid), do: Agent.get(pid, &Enum.reverse(&1))
  end

  # The exact composition BrowserControl.navigate/3 uses, with an injectable
  # session so the assertion "the browser was never touched" is precise.
  defp guarded(scope, url, rec) do
    case Scope.guard(scope, {:navigate, url}) do
      {:ok, origin} -> RecordingSession.navigate(rec, url) && {:ok, origin}
      halt -> halt
    end
  end

  setup do
    {:ok, rec} = RecordingSession.start_link()
    {:ok, rec: rec, scope: Scope.new("buy paper", ["example.com"], id: "gn")}
  end

  test "an allowed URL is navigated exactly once", %{rec: rec, scope: scope} do
    assert {:ok, origin} = guarded(scope, "https://example.com/products", rec)
    assert origin.host == "example.com"
    assert RecordingSession.urls(rec) == ["https://example.com/products"]
  end

  test "an out-of-scope URL is halted before any navigation", %{rec: rec, scope: scope} do
    assert {:halt, :out_of_scope, _} = guarded(scope, "https://evil.com/", rec)
    assert RecordingSession.urls(rec) == []
  end

  test "a payment URL is halted before any navigation", %{rec: rec, scope: scope} do
    assert {:halt, :payment_stop, _} = guarded(scope, "https://example.com/checkout", rec)
    assert RecordingSession.urls(rec) == []
  end

  test "the facade demands a real Scope struct — no bypass with a bare map" do
    # Launder through a runtime value so the static type checker doesn't flag the
    # deliberately-wrong argument; the guard must still reject it at runtime.
    not_a_scope = Enum.random([%{not: :a_scope}])

    assert_raise FunctionClauseError, fn ->
      BrowserControl.navigate(self(), not_a_scope, "https://example.com/")
    end
  end
end
