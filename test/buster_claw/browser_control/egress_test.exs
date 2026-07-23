defmodule BusterClaw.BrowserControl.EgressTest do
  use ExUnit.Case, async: true

  alias BusterClaw.BrowserControl.Egress
  alias BusterClaw.BrowserControl.Egress.Snapshot

  defp snap do
    %Snapshot{
      title: "Checkout — Acme",
      headings: ["Your order"],
      elements: [%{role: "textbox", label: "Card number"}, %{role: "button", label: "Pay"}],
      text: "Total $19.99. Saved card ends 4242424242424242. Thanks!"
    }
  end

  describe "level: full" do
    test "sends title + headings + elements + redacted text, and reports it" do
      {payload, report} = Egress.prepare("shop.example.com", snap())

      assert payload.title == "Checkout — Acme"
      assert payload.text =~ "⟨redacted:card⟩"
      refute payload.text =~ "4242"
      assert report.level == :full
      assert report.redactions.card == 1
      assert report.bytes_in > 0
      # NB: a typed placeholder (⟨redacted:card⟩, 19 bytes) is longer than a
      # 16-digit card, so :full redaction can marginally GROW the payload. The
      # receipt is an honest measure, not a guarantee of shrinkage — the
      # reduction property belongs to structure_only/never, asserted below.
      assert report.bytes_out > 0
    end
  end

  describe "level: structure_only" do
    test "drops free text but keeps title and elements" do
      # Force structure_only via an override (example.com isn't sensitive).
      {payload, report} =
        Egress.prepare("shop.example.com", snap(), overrides: [{"example.com", :structure_only}])

      assert report.level == :structure_only
      refute Map.has_key?(payload, :text)
      assert payload.title == "Checkout — Acme"
      assert length(payload.elements) == 2
      # Structure leaves; the free-text card number never does.
      refute inspect(payload) =~ "4242"
    end

    test "a sensitive host gets structure_only without an override" do
      {_payload, report} = Egress.prepare("secure.chase.com", snap())
      assert report.level == :structure_only
    end

    test "dropping free text genuinely sends fewer bytes than :full" do
      {_p_full, full} = Egress.prepare("shop.example.com", snap())

      {_p_struct, struct} =
        Egress.prepare("shop.example.com", snap(), overrides: [{"example.com", :structure_only}])

      assert struct.bytes_out < full.bytes_out
    end
  end

  describe "level: never" do
    test "sends nothing but a withheld marker" do
      {payload, report} =
        Egress.prepare("shop.example.com", snap(), overrides: [{"shop.example.com", :never}])

      assert report.level == :never
      assert payload.withheld == true
      refute inspect(payload) =~ "4242"
      refute inspect(payload) =~ "Acme"
    end
  end

  describe "the receipt" do
    test "secrets_resolved is carried onto the report" do
      {_p, report} = Egress.prepare("shop.example.com", snap(), secrets_resolved: 3)
      assert report.secrets_resolved == 3
    end

    test "summarize/1 folds a run into the '17 steps, 41KB, 6 redacted' line" do
      {_p1, r1} = Egress.prepare("shop.example.com", snap(), secrets_resolved: 1)
      {_p2, r2} = Egress.prepare("secure.chase.com", snap())

      s = Egress.summarize([r1, r2])
      assert s.steps == 2
      assert s.bytes_out == r1.bytes_out + r2.bytes_out
      assert s.redactions.card == r1.redactions.card + r2.redactions.card
      assert s.secrets_resolved == 1
      assert s.levels[:full] == 1
      assert s.levels[:structure_only] == 1
    end
  end

  test "re-exports the secret-ref helpers" do
    assert {:ok, "hi bob"} =
             Egress.resolve_secrets("hi $secret.who", fn "who" -> {:ok, "bob"} end)

    assert Egress.mask_secrets("hi $secret.who") == "hi ⟨secret:who⟩"
  end
end
