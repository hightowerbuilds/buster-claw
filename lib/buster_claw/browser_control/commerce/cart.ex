defmodule BusterClaw.BrowserControl.Commerce.Cart do
  @moduledoc """
  The cart the agent builds while shopping (BROWSER_ENGINE_ROADMAP Phase 5).

  Pure and money-in-cents — the agent adds line items as it compares and
  chooses, and the total is what the human is shown at the payment handoff. No
  payment credential ever touches this: the cart is the *what*, the human is the
  *pay*.

  Items are `%{name, qty, unit_cents}`; the total is `Σ qty·unit_cents`. `name`
  and any label are the model's text and so are already subject to the egress
  redactor upstream — a cart never stores anything the trajectory couldn't.
  """

  alias BusterClaw.BrowserControl.Commerce.Cart

  defstruct items: [], currency: "USD"

  @type item :: %{name: String.t(), qty: pos_integer(), unit_cents: non_neg_integer()}
  @type t :: %__MODULE__{items: [item()], currency: String.t()}

  @doc "A new empty cart (default USD)."
  def new(currency \\ "USD"), do: %Cart{items: [], currency: currency}

  @doc """
  Add a line item. `qty` defaults to 1; a non-positive qty or negative price is
  rejected as `{:error, :invalid_item}` — a cart can't hold nonsense the ledger
  would later inherit.
  """
  def add_item(%Cart{} = cart, name, unit_cents, qty \\ 1)
      when is_binary(name) and is_integer(unit_cents) and is_integer(qty) do
    if unit_cents < 0 or qty < 1 do
      {:error, :invalid_item}
    else
      {:ok, %{cart | items: cart.items ++ [%{name: name, qty: qty, unit_cents: unit_cents}]}}
    end
  end

  @doc "The total in cents: `Σ qty · unit_cents`."
  def total_cents(%Cart{items: items}) do
    Enum.reduce(items, 0, fn %{qty: q, unit_cents: u}, acc -> acc + q * u end)
  end

  @doc "Line-item count (distinct lines, not summed quantities)."
  def line_count(%Cart{items: items}), do: length(items)

  @doc "Total quantity across all lines."
  def item_count(%Cart{items: items}), do: Enum.reduce(items, 0, &(&1.qty + &2))

  @doc "True for a cart with no lines — nothing to hand off or bill."
  def empty?(%Cart{items: items}), do: items == []

  @doc """
  A human/model-facing summary: a one-line description and the formatted total,
  for the payment-handoff card and the ledger entry's description.
  """
  def summary(%Cart{} = cart) do
    lines =
      Enum.map_join(cart.items, ", ", fn %{name: n, qty: q, unit_cents: u} ->
        "#{q}× #{n} (#{format_cents(u, cart.currency)})"
      end)

    %{
      currency: cart.currency,
      total_cents: total_cents(cart),
      total: format_cents(total_cents(cart), cart.currency),
      lines: lines,
      line_count: line_count(cart),
      item_count: item_count(cart)
    }
  end

  @doc "Format cents as a currency string, e.g. `1999 → \"$19.99\"` (USD)."
  def format_cents(cents, currency \\ "USD") when is_integer(cents) do
    sign = if cents < 0, do: "-", else: ""
    whole = div(abs(cents), 100)
    frac = rem(abs(cents), 100)
    "#{sign}#{symbol(currency)}#{whole}.#{String.pad_leading(Integer.to_string(frac), 2, "0")}"
  end

  defp symbol("USD"), do: "$"
  defp symbol("GBP"), do: "£"
  defp symbol("EUR"), do: "€"
  defp symbol(other), do: other <> " "
end
