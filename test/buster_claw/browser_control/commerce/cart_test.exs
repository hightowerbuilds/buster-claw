defmodule BusterClaw.BrowserControl.Commerce.CartTest do
  use ExUnit.Case, async: true

  alias BusterClaw.BrowserControl.Commerce.Cart

  test "a new cart is empty" do
    assert Cart.empty?(Cart.new())
    assert Cart.total_cents(Cart.new()) == 0
  end

  test "adding items accumulates lines, quantities, and total" do
    {:ok, cart} = Cart.add_item(Cart.new(), "Printer paper", 1299, 2)
    {:ok, cart} = Cart.add_item(cart, "Stapler", 899)

    refute Cart.empty?(cart)
    assert Cart.line_count(cart) == 2
    assert Cart.item_count(cart) == 3
    assert Cart.total_cents(cart) == 1299 * 2 + 899
  end

  test "rejects nonsense items so the ledger can't inherit them" do
    assert {:error, :invalid_item} = Cart.add_item(Cart.new(), "free?", -1)
    assert {:error, :invalid_item} = Cart.add_item(Cart.new(), "zero qty", 100, 0)
  end

  test "summary gives a human/model-facing description and formatted total" do
    {:ok, cart} = Cart.add_item(Cart.new(), "Printer paper", 1299, 2)
    {:ok, cart} = Cart.add_item(cart, "Stapler", 899)

    s = Cart.summary(cart)
    assert s.total_cents == 3497
    assert s.total == "$34.97"
    assert s.lines =~ "2× Printer paper ($12.99)"
    assert s.lines =~ "1× Stapler ($8.99)"
    assert s.line_count == 2
    assert s.item_count == 3
  end

  test "format_cents handles currencies and zero padding" do
    assert Cart.format_cents(1999) == "$19.99"
    assert Cart.format_cents(5) == "$0.05"
    assert Cart.format_cents(100) == "$1.00"
    assert Cart.format_cents(1250, "GBP") == "£12.50"
    assert Cart.format_cents(999, "EUR") == "€9.99"
  end
end
