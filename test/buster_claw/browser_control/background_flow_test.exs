defmodule BusterClaw.BrowserControl.BackgroundFlowTest do
  @moduledoc """
  A full flow on the background engine with stubbed CDP + scope-gate surfaces:
  the tab step vocabulary runs unchanged, the scope frozen from the flow's own
  navigate hosts still enforces its payment gate, and the report is
  FlowRunner's.
  """
  use ExUnit.Case, async: true

  alias BusterClaw.Browser.FlowRunner
  alias BusterClaw.BrowserControl.BackgroundFlow
  alias BusterClaw.BrowserControl.Scope

  # Scope-gated navigation stub with the real authorize decision (pure — no
  # Sentinel write, so the test stays async).
  defmodule StubNav do
    def navigate(_session, %Scope{} = scope, url) do
      case Scope.authorize(scope, {:navigate, url}) do
        {:ok, origin} -> {:ok, origin}
        halt -> halt
      end
    end
  end

  # A scripted page. Order matters: specific JS markers first, and the
  # `includes(` marker (text/url wait conditions) never matches so wait
  # budgets can expire.
  defmodule StubSession do
    def command(_session, "Runtime.evaluate", %{"expression" => js}) do
      value =
        cond do
          js =~ "readyState" -> true
          js =~ "el.click()" -> %{"matched" => true, "clicked" => "Go"}
          js =~ "count: matches.length" -> %{"count" => 2, "matches" => []}
          js =~ "includes(" -> false
          true -> %{"url" => "https://shop.com/x", "title" => "Shop", "text" => "hello world"}
        end

      {:ok, %{"result" => %{"value" => value}}}
    end
  end

  defp opts,
    do: [session: :stub, session_mod: StubSession, navigate_mod: StubNav, wait_poll_ms: 1]

  test "derive_scope freezes the flow's own navigate hosts; no host refuses" do
    steps = [
      %{"action" => "navigate", "url" => "https://shop.com/a"},
      %{"action" => "navigate", "url" => "https://news.example.org/b"}
    ]

    assert {:ok, scope} = BackgroundFlow.derive_scope(steps)
    assert Scope.host_allowed?(scope, "shop.com")
    assert Scope.host_allowed?(scope, "news.example.org")
    refute Scope.host_allowed?(scope, "evil.com")

    assert {:error, :no_navigable_host} =
             BackgroundFlow.derive_scope([%{"action" => "wait", "until" => "navigation"}])
  end

  test "the tab vocabulary runs end to end on the engine and passes" do
    steps = [
      %{"action" => "navigate", "url" => "https://shop.com/products"},
      %{"action" => "wait", "until" => "navigation"},
      %{"action" => "click", "text" => "Go"},
      %{"action" => "extract"},
      %{"action" => "assert", "kind" => "text", "value" => "hello"},
      %{"action" => "assert", "kind" => "url_contains", "value" => "shop.com"},
      %{"action" => "assert", "kind" => "selector", "value" => ".price"}
    ]

    assert {:ok, report} = BackgroundFlow.run(steps, opts())
    assert report.status == "passed"
    assert length(report.steps) == 7
    assert Enum.all?(report.steps, &(&1.status == "passed"))
  end

  test "a payment page halts the flow — the scope's payment gate holds on the engine" do
    steps = [
      %{"action" => "navigate", "url" => "https://shop.com/a"},
      %{"action" => "navigate", "url" => "https://shop.com/checkout"}
    ]

    assert {:ok, report} = BackgroundFlow.run(steps, opts())
    assert report.status == "failed"
    assert report.failed_step == 2
    assert List.last(report.steps).detail.error =~ "payment_stop"
  end

  test "an undeclared host halts as out_of_scope through the gate" do
    scope = Scope.new("background flow", ["shop.com"])

    assert {:halt, :out_of_scope, _meta} =
             StubNav.navigate(:stub, scope, "https://evil.com/lure")
  end

  test "a failed wait and a failed assert are step failures, tab-classify rules" do
    steps = [
      %{"action" => "navigate", "url" => "https://shop.com/"},
      %{"action" => "wait", "until" => "text", "value" => "never-there", "timeout_ms" => 2},
      %{"action" => "assert", "kind" => "text", "value" => "hello"}
    ]

    assert {:ok, report} = BackgroundFlow.run(steps, opts())
    assert report.status == "failed"
    assert report.failed_step == 2
    assert List.last(report.steps).detail.matched == false
  end

  test "wait with a missing value and unknown assert kinds are typed step failures" do
    steps = [
      %{"action" => "navigate", "url" => "https://shop.com/"},
      %{"action" => "wait", "until" => "selector"}
    ]

    assert {:ok, %{status: "failed", failed_step: 2}} = BackgroundFlow.run(steps, opts())

    steps = [
      %{"action" => "navigate", "url" => "https://shop.com/"},
      %{"action" => "assert", "kind" => "smell", "value" => "roses"}
    ]

    assert {:ok, %{status: "failed", failed_step: 2}} = BackgroundFlow.run(steps, opts())
  end

  test "flow validation still gates: empty flows and unknown actions refuse up front" do
    assert {:error, :empty_flow} = BackgroundFlow.run([], opts())

    assert {:error, {:bad_step, 1, {:unknown_action, "hover"}}} =
             BackgroundFlow.run([%{"action" => "hover"}], opts())

    # The vocabulary is FlowRunner's — one validator for both engines.
    assert FlowRunner.actions() == ~w(navigate wait click fill extract assert find_elements)
  end
end
