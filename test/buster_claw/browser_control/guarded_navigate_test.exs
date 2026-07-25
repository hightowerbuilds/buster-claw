defmodule BusterClaw.BrowserControl.GuardedNavigateTest do
  @moduledoc """
  The gate is load-bearing, and it fires twice: `BrowserControl.navigate/4` runs
  `Scope.guard/2` on the requested URL before the engine sees it, and again on
  the URL the browser actually landed on (Finding 6, 07-25).

  This file used to re-implement the composition locally and assert on the copy —
  which is the same "tested in isolation, not wired to the surface that runs"
  shape that let the 07-25 defects through. It now drives the real function with
  an injected `session_mod`, so what passes here is what ships. The real engine
  integration is in `PoolLiveTest` ("the scope gate holds against a live engine"),
  including a real HTTP redirect.
  """
  use BusterClaw.DataCase, async: false

  alias BusterClaw.BrowserControl
  alias BusterClaw.BrowserControl.Scope

  # Stands in for Session: records navigations and answers `location.href` with
  # a scripted landing, so a redirect is expressible without a browser.
  defmodule FakeSession do
    use Agent

    def start_link(lands_on \\ :as_requested) do
      Agent.start_link(fn -> %{urls: [], lands_on: lands_on} end)
    end

    def navigate(pid, url) do
      Agent.update(pid, &%{&1 | urls: [url | &1.urls]})
      :ok
    end

    # Page.current/2 arrives here as a Runtime.evaluate.
    def command(pid, "Runtime.evaluate", _params) do
      case Agent.get(pid, & &1) do
        %{lands_on: :unreadable} ->
          {:error, :session_gone}

        %{lands_on: :as_requested, urls: [last | _]} ->
          evaluated(%{"url" => last, "title" => "t"})

        %{lands_on: landing} ->
          evaluated(%{"url" => landing, "title" => "t"})
      end
    end

    defp evaluated(value), do: {:ok, %{"result" => %{"value" => value}}}

    def urls(pid), do: Agent.get(pid, &Enum.reverse(&1.urls))
  end

  defp nav(session, scope, url),
    do: BrowserControl.navigate(session, scope, url, session_mod: FakeSession)

  setup do
    {:ok, scope: Scope.new("buy paper", ["example.com"], id: "gn")}
  end

  describe "the pre-navigation gate" do
    setup do
      {:ok, rec} = FakeSession.start_link()
      %{rec: rec}
    end

    test "an allowed URL is navigated exactly once", %{rec: rec, scope: scope} do
      assert {:ok, origin} = nav(rec, scope, "https://example.com/products")
      assert origin.host == "example.com"
      assert FakeSession.urls(rec) == ["https://example.com/products"]
      refute Map.has_key?(origin, :redirected_from)
    end

    test "an out-of-scope URL is halted before any navigation", %{rec: rec, scope: scope} do
      assert {:halt, :out_of_scope, _} = nav(rec, scope, "https://evil.com/")
      assert FakeSession.urls(rec) == []
    end

    test "a payment URL is halted before any navigation", %{rec: rec, scope: scope} do
      assert {:halt, :payment_stop, _} = nav(rec, scope, "https://example.com/checkout")
      assert FakeSession.urls(rec) == []
    end
  end

  describe "the post-navigation gate (Finding 6)" do
    test "a redirect onto a payment page halts, though the request was allowed", %{scope: scope} do
      {:ok, rec} = FakeSession.start_link("https://example.com/checkout/entry/cart")

      assert {:halt, :payment_stop, meta} = nav(rec, scope, "https://example.com/cart")

      # The halt names the landed URL and says it was a redirect — on the feed,
      # this must not read like a direct navigation to checkout.
      assert meta[:url] == "https://example.com/checkout/entry/cart"
      assert meta[:redirected_from] == "https://example.com/cart"
    end

    test "a redirect off the frozen allowlist halts", %{scope: scope} do
      {:ok, rec} = FakeSession.start_link("https://evil.com/collect")

      assert {:halt, :out_of_scope, meta} = nav(rec, scope, "https://example.com/go")
      assert meta[:host] == "evil.com"
      assert meta[:redirected_from] == "https://example.com/go"
    end

    test "an in-scope redirect passes, and the origin describes where we LANDED", %{scope: scope} do
      {:ok, rec} = FakeSession.start_link("https://shop.example.com/products/paper")

      assert {:ok, origin} = nav(rec, scope, "https://example.com/p")

      # This is the egress fix: current_host is set from origin.host, so it has
      # to be the landed host or a :structure_only domain is readable at :full
      # by being redirected to.
      assert origin.host == "shop.example.com"
      assert origin.url == "https://shop.example.com/products/paper"
      assert origin.redirected_from == "https://example.com/p"
    end

    test "an unreadable landing fails CLOSED, not open", %{scope: scope} do
      {:ok, rec} = FakeSession.start_link(:unreadable)

      assert {:halt, :unverified_location, meta} = nav(rec, scope, "https://example.com/p")
      assert meta[:url] == "https://example.com/p"
    end

    test "the halt is recorded on the security feed with its scope and intent", %{scope: scope} do
      {:ok, rec} = FakeSession.start_link("https://evil.com/collect")

      assert {:halt, :out_of_scope, _} = nav(rec, scope, "https://example.com/go")

      block =
        BusterClaw.Sentinel.list_events(limit: 5)
        |> Enum.find(&(&1.category == "security_block"))

      assert block
      assert block.metadata["scope_id"] == "gn"
    end
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
