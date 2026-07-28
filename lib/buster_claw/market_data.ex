defmodule BusterClaw.MarketData do
  @moduledoc """
  The market-data cache (TRADING_TAB_ROADMAP Phase 1): daily closes per held
  symbol in `symbol_bars`, plus a quotes/indexes blob in Settings.

  A cache of the API's truth, not a ledger of ours — the philosophical opposite
  of `BusterClaw.Portfolio`. A lost portfolio reading is gone forever; a lost
  bar is one tool call away. So this module optimizes for a different thing:
  every sparkline, day-change figure, and (later) symbol chart renders from
  SQLite with **zero agent runs on tab open**. The daily Recorder is the pump.

  ## Refresh discipline

  One attempt per market day, latched in Settings by *attempt* rather than by
  success — the Recorder re-ticks every ~30 minutes after the close, and a
  data-freshness guard alone would re-spend a real agent run on every tick of a
  day the fetch kept failing. A failed sweep waits for tomorrow, exactly like a
  failed balance recording.

  ## Upsert rule worth stating

  The closes tier re-writes `close_cents` only. The chart tier (Phase 4) fills
  OHLC/volume onto the same rows; a closes refresh that replaced whole rows
  would null out chart data every night.
  """
  import Ecto.Query

  require Logger

  alias BusterClaw.MarketCalendar
  alias BusterClaw.MarketData.Bar
  alias BusterClaw.Repo
  alias BusterClaw.Settings
  alias BusterClaw.Trading

  @quotes_key "market_quotes_snapshot"
  @attempt_key "market_data_attempted_on"
  @quotes_stale_min 15
  # First fill reaches back ~90 days (the roadmap's closes tier); daily top-ups
  # re-fetch a few days of overlap so a failed day self-heals.
  @first_fill_days 90
  @topup_overlap_days 5

  # ---------------------------------------------------------------------------
  # Refresh (the Recorder's second duty)
  # ---------------------------------------------------------------------------

  @doc """
  Run the daily market sweep: discover held symbols, store their closes, cache
  quotes. Returns `{:ok, %{symbols: [...], bars: n}}` or `{:error, reason}`.

  Marks the attempt BEFORE fetching — see the moduledoc for why the latch is
  per-attempt, not per-success.
  """
  def refresh(day \\ MarketCalendar.today()) do
    mark_attempt(day)

    case Trading.fetch_market_data(refresh_start(day)) do
      {:ok, parsed} ->
        {bars, symbols} = store_bars(parsed.closes)
        store_quotes(parsed)

        if parsed.errors != [],
          do: Logger.warning("MarketData: partial sweep: #{inspect(parsed.errors)}")

        if parsed.skipped != [],
          do:
            Logger.warning(
              "MarketData: symbols skipped (over batch cap): #{inspect(parsed.skipped)}"
            )

        {:ok, %{symbols: symbols, bars: bars}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "True when a sweep was already attempted on `day`."
  def attempted_on?(%Date{} = day), do: Settings.get(@attempt_key) == Date.to_iso8601(day)

  @doc "Latch a sweep attempt for `day`."
  def mark_attempt(%Date{} = day), do: Settings.put(@attempt_key, Date.to_iso8601(day))

  @doc """
  Where the next fetch should start: ~#{@first_fill_days} days back on an empty
  cache, else a few days before the newest bar (overlap heals a failed day).
  """
  def refresh_start(%Date{} = day) do
    case latest_bar_on() do
      nil -> Date.add(day, -@first_fill_days)
      newest -> Date.add(newest, -@topup_overlap_days)
    end
  end

  # ---------------------------------------------------------------------------
  # Bars
  # ---------------------------------------------------------------------------

  @doc """
  Store a parsed closes map (`Trading.parse_market_data/1` shape). Returns
  `{bars_written, symbols}`. Cents conversion happens here, once; rows the
  changeset refuses are logged and skipped, never persisted half-right.
  """
  def store_bars(closes) when is_map(closes) do
    written =
      for {symbol, bars} <- closes, bar <- bars, reduce: 0 do
        acc ->
          %Bar{}
          |> Bar.changeset(%{
            symbol: symbol,
            bar_on: bar.bar_on,
            close_cents: round(bar.close * 100)
          })
          |> Repo.insert(
            # Replace the close only: chart-tier OHLC on the same row survives.
            on_conflict: {:replace, [:close_cents, :updated_at]},
            conflict_target: [:symbol, :bar_on]
          )
          |> case do
            {:ok, _bar} ->
              acc + 1

            {:error, changeset} ->
              Logger.warning(
                "MarketData: refusing bar #{symbol} #{bar.bar_on}: #{inspect(changeset.errors)}"
              )

              acc
          end
      end

    {written, closes |> Map.keys() |> Enum.sort()}
  end

  @doc "A symbol's bars, oldest first, optionally only the trailing `days`."
  def bars(symbol, days \\ nil) when is_binary(symbol) do
    query =
      Bar
      |> where([b], b.symbol == ^symbol)
      |> order_by([b], asc: b.bar_on)

    case days do
      nil ->
        Repo.all(query)

      days when is_integer(days) ->
        # Trailing window: newest N, re-sorted ascending for drawing.
        Bar
        |> where([b], b.symbol == ^symbol)
        |> order_by([b], desc: b.bar_on)
        |> limit(^days)
        |> Repo.all()
        |> Enum.reverse()
    end
  end

  @doc "Symbols with any cached bars, sorted."
  def known_symbols do
    Bar
    |> select([b], b.symbol)
    |> distinct(true)
    |> Repo.all()
    |> Enum.sort()
  end

  @doc "The newest bar date across all symbols, or nil."
  def latest_bar_on do
    Bar
    |> select([b], max(b.bar_on))
    |> Repo.one()
  end

  @doc """
  True when the cache holds a close for the most recent trading day — what
  "up to date" means for daily bars.
  """
  def fresh?(%Date{} = day) do
    case latest_bar_on() do
      nil -> false
      newest -> Date.compare(newest, MarketCalendar.latest_trading_day(day)) != :lt
    end
  end

  # ---------------------------------------------------------------------------
  # Quotes blob
  # ---------------------------------------------------------------------------

  @doc "Cache the sweep's quotes + indexes with an app-side stamp."
  def store_quotes(%{quotes: quotes, indexes: indexes}) do
    Settings.put(
      @quotes_key,
      Jason.encode!(%{
        "quotes" => quotes,
        "indexes" => indexes,
        "fetched_at" => DateTime.utc_now() |> DateTime.to_iso8601()
      })
    )
  end

  @doc "The cached quotes blob, `{:ok, map} | :none`."
  def cached_quotes do
    with raw when is_binary(raw) <- Settings.get(@quotes_key),
         {:ok, %{"fetched_at" => _} = blob} <- Jason.decode(raw) do
      {:ok, blob}
    else
      _ -> :none
    end
  end

  @doc "True when the quotes blob is missing a stamp or older than #{@quotes_stale_min} minutes."
  def quotes_stale?(%{"fetched_at" => stamp}) when is_binary(stamp) do
    case DateTime.from_iso8601(stamp) do
      {:ok, at, _} -> DateTime.diff(DateTime.utc_now(), at, :minute) >= @quotes_stale_min
      _ -> true
    end
  end

  def quotes_stale?(_blob), do: true
end
