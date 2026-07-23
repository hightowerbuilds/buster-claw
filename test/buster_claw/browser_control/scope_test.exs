defmodule BusterClaw.BrowserControl.ScopeTest do
  @moduledoc """
  The frozen-scope gate — pure policy, no browser, no DB. The Sentinel-emitting
  `guard/2` is covered in `ScopeGuardTest` where a sandbox is available.
  """
  use ExUnit.Case, async: true

  alias BusterClaw.BrowserControl.Scope

  defp scope(domains, opts \\ []) do
    Scope.new(Keyword.get(opts, :intent, "buy printer paper"), domains, id: "scope_test")
  end

  describe "new/3" do
    test "normalizes domains: downcase, strip scheme/dot/path, dedup, drop empties" do
      s = scope(["HTTPS://Shop.Example.com/cart", ".example.com", "example.com", "  ", "b.org/"])
      assert s.allowed_domains == ["shop.example.com", "example.com", "b.org"]
    end

    test "freezes intent verbatim and carries an id" do
      s = scope(["example.com"], intent: "the literal task")
      assert s.intent == "the literal task"
      assert s.id == "scope_test"
    end

    test "an empty allowlist denies everything (safe default)" do
      s = scope([])
      assert {:halt, :out_of_scope, _} = Scope.authorize(s, {:navigate, "https://example.com/"})
    end
  end

  describe "navigation allowlist" do
    test "an allowed domain passes and returns its origin" do
      s = scope(["example.com"])

      assert {:ok, origin} = Scope.authorize(s, {:navigate, "https://example.com/products"})
      assert origin.host == "example.com"
      assert origin.scope_id == "scope_test"
      assert origin.intent == "buy printer paper"
    end

    test "subdomains of an allowed domain are in scope" do
      s = scope(["example.com"])
      assert {:ok, _} = Scope.authorize(s, {:navigate, "https://shop.example.com/x"})
      assert {:ok, _} = Scope.authorize(s, {:navigate, "https://a.b.example.com/x"})
    end

    test "a domain not on the list halts" do
      s = scope(["example.com"])

      assert {:halt, :out_of_scope, meta} =
               Scope.authorize(s, {:navigate, "https://other.com/"})

      assert meta.host == "other.com"
    end

    test "suffix lookalikes never pass (the classic spoof)" do
      s = scope(["example.com"])

      for bad <- [
            "https://evil-example.com/",
            "https://example.com.evil.com/",
            "https://notexample.com/",
            "https://example.co/"
          ] do
        assert {:halt, :out_of_scope, _} = Scope.authorize(s, {:navigate, bad}),
               "should halt: #{bad}"
      end
    end
  end

  describe "payment hard stop" do
    test "a payment host halts even when its base domain is allowlisted" do
      s = scope(["stripe.com", "example.com"])

      assert {:halt, :payment_stop, meta} =
               Scope.authorize(s, {:navigate, "https://checkout.stripe.com/pay/abc"})

      assert meta.host == "checkout.stripe.com"
    end

    test "a checkout path on an allowed host halts" do
      s = scope(["example.com"])

      for pay <- [
            "https://example.com/checkout",
            "https://example.com/cart/payment",
            "https://example.com/billing/pay?x=1",
            "https://example.com/place-order"
          ] do
        assert {:halt, :payment_stop, _} = Scope.authorize(s, {:navigate, pay}),
               "should stop: #{pay}"
      end
    end

    test "payment stop wins over out-of-scope (fires first)" do
      s = scope(["example.com"])
      # paypal is neither allowed nor should it matter — payment gate catches it.
      assert {:halt, :payment_stop, _} =
               Scope.authorize(s, {:navigate, "https://www.paypal.com/checkout"})
    end

    test "ordinary product/cart-view paths are not payment pages" do
      s = scope(["example.com"])
      assert {:ok, _} = Scope.authorize(s, {:navigate, "https://example.com/cart"})
      assert {:ok, _} = Scope.authorize(s, {:navigate, "https://example.com/products/paper"})
    end
  end

  describe "malformed input" do
    test "unparseable or hostless URLs halt as :bad_url" do
      s = scope(["example.com"])

      for bad <- ["not a url", "/relative/path", "https:///nohost", ""] do
        assert {:halt, :bad_url, _} = Scope.authorize(s, {:navigate, bad}), "bad: #{inspect(bad)}"
      end
    end

    test "non-http schemes are rejected (no javascript:/file:/data:)" do
      s = scope(["example.com"])

      for bad <- ["javascript:alert(1)", "file:///etc/passwd", "data:text/html,x"] do
        assert {:halt, :bad_url, _} = Scope.authorize(s, {:navigate, bad}), "scheme: #{bad}"
      end
    end
  end

  describe "act actions" do
    test "an in-scope act carries the action name in its origin" do
      s = scope(["example.com"])

      assert {:ok, origin} =
               Scope.authorize(s, {:act, :click, "https://example.com/products"})

      assert origin.action == :click
    end

    test "acting on an out-of-scope page halts" do
      s = scope(["example.com"])
      assert {:halt, :out_of_scope, _} = Scope.authorize(s, {:act, :fill, "https://evil.com/"})
    end

    test "acting on a payment page halts regardless of action" do
      s = scope(["example.com"])

      assert {:halt, :payment_stop, _} =
               Scope.authorize(s, {:act, :click, "https://example.com/checkout"})
    end
  end

  describe "purity — the property that makes 'page content can't widen scope' true" do
    test "authorize is deterministic for identical inputs" do
      s = scope(["example.com"])
      a = Scope.authorize(s, {:navigate, "https://other.com/"})
      b = Scope.authorize(s, {:navigate, "https://other.com/"})
      assert a == b
    end

    test "authorize never mutates the scope" do
      s = scope(["example.com"])
      _ = Scope.authorize(s, {:navigate, "https://example.com/"})
      _ = Scope.authorize(s, {:navigate, "https://evil.com/"})
      assert s.allowed_domains == ["example.com"]
    end

    test "there is no mutator on the public API" do
      # Structural guarantee: page content cannot widen a scope because no
      # function accepts content and returns a widened scope. If someone adds
      # add_domain/widen later, this fails and forces a deliberate review.
      exported = Scope.__info__(:functions) |> Keyword.keys() |> Enum.uniq()
      refute :add_domain in exported
      refute :widen in exported
      refute :allow in exported
    end
  end
end
