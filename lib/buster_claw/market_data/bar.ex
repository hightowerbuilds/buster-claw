defmodule BusterClaw.MarketData.Bar do
  @moduledoc """
  One symbol's price bar for one market day (TRADING_TAB_ROADMAP Phase 1).

  `close_cents` is always present; OHLC and volume are null on closes-tier rows
  and filled when the chart tier (Phase 4) fetches the same day in full. A
  price of zero or less is refused — a symbol cannot close at nothing, and a
  zero would draw a cliff into every sparkline that touches it.
  """
  use Ecto.Schema

  import Ecto.Changeset

  # Uppercase ticker, optionally dotted (BRK.B) or suffixed — tight enough to
  # refuse prose the model might emit where a symbol belongs.
  @symbol_re ~r/\A[A-Z][A-Z0-9.]{0,9}\z/

  @intervals ~w(day week)

  schema "symbol_bars" do
    field :symbol, :string
    field :bar_on, :date
    field :interval, :string, default: "day"
    field :close_cents, :integer
    field :open_cents, :integer
    field :high_cents, :integer
    field :low_cents, :integer
    field :volume, :integer

    timestamps(type: :utc_datetime)
  end

  def changeset(bar, attrs) do
    bar
    |> cast(attrs, [
      :symbol,
      :bar_on,
      :interval,
      :close_cents,
      :open_cents,
      :high_cents,
      :low_cents,
      :volume
    ])
    |> validate_required([:symbol, :bar_on, :close_cents])
    |> validate_format(:symbol, @symbol_re)
    |> validate_inclusion(:interval, @intervals)
    |> validate_number(:close_cents, greater_than: 0)
    |> unique_constraint([:symbol, :bar_on, :interval])
  end
end
