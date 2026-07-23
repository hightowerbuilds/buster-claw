defmodule BusterClaw.BrowserControl.Egress.SecretRefTest do
  use ExUnit.Case, async: true

  alias BusterClaw.BrowserControl.Egress.SecretRef

  @store %{
    "shipping_address" => "500 Industrial Way, Portland OR",
    "card_number" => "4242424242424242"
  }
  defp resolver(name), do: ((v = Map.get(@store, name)) && {:ok, v}) || :error

  test "references/1 lists the names without resolving" do
    assert SecretRef.references("fill $secret.shipping_address then $secret.card_number") ==
             ["shipping_address", "card_number"]
  end

  test "resolve/2 swaps references for real values at execution time" do
    assert {:ok, resolved} =
             SecretRef.resolve("ship to $secret.shipping_address", &resolver/1)

    assert resolved == "ship to 500 Industrial Way, Portland OR"
  end

  test "an unknown reference fails the whole resolution — never a half-filled form" do
    assert {:error, {:unknown_secret, "not_a_secret"}} =
             SecretRef.resolve("use $secret.not_a_secret", &resolver/1)
  end

  test "mask/1 keeps the reference token and never the value" do
    masked = SecretRef.mask("card is $secret.card_number here")
    assert masked == "card is ⟨secret:card_number⟩ here"
    refute masked =~ "4242"
  end

  test "the resolved value never appears in the masked (log-safe) form" do
    text = "pay with $secret.card_number"
    {:ok, resolved} = SecretRef.resolve(text, &resolver/1)
    # The value is in the executor's string...
    assert resolved =~ "4242424242424242"
    # ...but the log-safe rendering of the ORIGINAL model output shows only the ref.
    refute SecretRef.mask(text) =~ "4242"
  end

  test "text with no references passes through unchanged" do
    assert {:ok, "just some text"} = SecretRef.resolve("just some text", &resolver/1)
    assert SecretRef.mask("just some text") == "just some text"
    refute SecretRef.ref?("just some text")
  end
end
