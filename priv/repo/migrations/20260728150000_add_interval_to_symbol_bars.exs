defmodule BusterClaw.Repo.Migrations.AddIntervalToSymbolBars do
  use Ecto.Migration

  # Phase 4 charts fetch WEEKLY bars for the 5Y range (the ~260-row transcription
  # cap makes daily impossible there). Without an interval column those rows
  # would interleave with daily ones — every sparkline and freshness check would
  # silently mix granularities. The unique key grows the same dimension: a week
  # bar and a day bar can legitimately share a date.
  def change do
    alter table(:symbol_bars) do
      add :interval, :string, null: false, default: "day"
    end

    drop unique_index(:symbol_bars, [:symbol, :bar_on])
    create unique_index(:symbol_bars, [:symbol, :bar_on, :interval])
  end
end
