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

  alias BusterClaw.DataState
  alias BusterClaw.MarketCalendar
  alias BusterClaw.MarketData.Bar
  alias BusterClaw.Repo
  alias BusterClaw.Settings
  alias BusterClaw.Trading

  @quotes_key "market_quotes_snapshot"
  @attempt_key "market_data_attempted_on"
  @benchmark_attempt_key "benchmark_backfill_attempted_on"
  @quotes_stale_min 15
  # First fill reaches back ~90 days (the roadmap's closes tier); daily top-ups
  # re-fetch a few days of overlap so a failed day self-heals.
  @first_fill_days 90
  @topup_overlap_days 5

  # Benchmarks cached regardless of what the operator holds, so Chart Build can
  # draw the market itself. ETFs, not index symbols — see `benchmark_symbols/0`.
  @benchmark_symbols ~w(SPY QQQ DIA IWM)
  # A trading year is ~252 sessions. Backfill triggers below this, and the slack
  # stops a benchmark that is a few sessions short from re-spending a run daily.
  @benchmark_target_bars 240
  # How far back a benchmark backfill reaches. Calendar days, so ~252 sessions.
  @benchmark_backfill_days 370

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

  @doc "True when a benchmark backfill was already attempted on `day`."
  def benchmark_attempted_on?(%Date{} = day),
    do: Settings.get(@benchmark_attempt_key) == Date.to_iso8601(day)

  @doc """
  Latch a benchmark backfill attempt for `day`.

  Per *attempt*, like the sweep and for the same reason: the Recorder re-ticks
  roughly every 30 minutes after the close, and a backfill is a real agent run
  of up to a few minutes. Latching on success alone would re-spend that run on
  every tick of a day the fetch kept failing.
  """
  def mark_benchmark_attempt(%Date{} = day),
    do: Settings.put(@benchmark_attempt_key, Date.to_iso8601(day))

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
            interval: "day",
            close_cents: round(bar.close * 100)
          })
          |> Repo.insert(
            # Replace the close only: chart-tier OHLC on the same row survives.
            on_conflict: {:replace, [:close_cents, :updated_at]},
            conflict_target: [:symbol, :bar_on, :interval]
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
      |> where([b], b.symbol == ^symbol and b.interval == "day")
      |> order_by([b], asc: b.bar_on)

    case days do
      nil ->
        Repo.all(query)

      days when is_integer(days) ->
        # Trailing window: newest N, re-sorted ascending for drawing.
        Bar
        |> where([b], b.symbol == ^symbol and b.interval == "day")
        |> order_by([b], desc: b.bar_on)
        |> limit(^days)
        |> Repo.all()
        |> Enum.reverse()
    end
  end

  @doc """
  The benchmark symbols this app keeps a year of history for, whether or not the
  operator holds them.

  They exist so Chart Build can answer "chart the S&P 500 for a year" from cache
  instead of not at all. ETFs rather than index symbols on purpose: `SPY` and
  friends are equities, so they come through `get_equity_historicals`, which is
  already in the read allowlist — reading the indices themselves would mean
  adding `get_index_historicals` to that list, which is a broader broker surface
  bought for a rounding difference in tracking.
  """
  def benchmark_symbols, do: @benchmark_symbols

  @doc """
  Benchmarks missing a usable year of daily bars.

  `@benchmark_target_bars` is deliberately under a full 252-day trading year:
  a benchmark that is a handful of sessions short is not worth re-spending an
  agent run on, and without slack this would refetch every single day forever.
  """
  def benchmarks_needing_backfill do
    Enum.filter(@benchmark_symbols, fn symbol ->
      length(bars(symbol)) < @benchmark_target_bars
    end)
  end

  @doc """
  Fetch and store a year of daily bars for ONE benchmark. Returns
  `{:ok, %{symbol: s, bars: n}}` or `{:error, reason}`.

  Uses the chart tier (`Trading.fetch_symbol_bars/3`) rather than the sweep,
  because a year is ~252 rows for a single symbol and that is exactly the
  payload the chart tier was sized for — the sweep carries every held symbol at
  once and would blow its transcription budget on a window this wide.

  Writes through the same `store_bars/1` upsert, so a benchmark that later
  appears in the daily sweep tops up normally rather than forking a second path.
  """
  def backfill_benchmark(symbol, day \\ MarketCalendar.today()) when is_binary(symbol) do
    start = Date.add(day, -@benchmark_backfill_days)

    case Trading.fetch_symbol_bars(symbol, start, "day") do
      {:ok, %{bars: bars}} when bars != [] ->
        {written, _symbols} = store_bars(%{symbol => Enum.map(bars, &to_close/1)})
        {:ok, %{symbol: symbol, bars: written}}

      {:ok, _empty} ->
        {:error, {:no_bars, symbol}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # The chart tier returns OHLCV; the benchmark cache only needs the close, and
  # `store_bars/1` is the closes-tier writer. OHLC on an existing row survives
  # its upsert, so nothing is lost by coming in through this door.
  defp to_close(%{bar_on: bar_on, close: close}), do: %{bar_on: bar_on, close: close}

  @doc """
  Symbols Chart Build can actually draw from cache: benchmarks first (they are
  the ones a person names without checking), then everything else held.
  """
  def chartable_symbols do
    cached = known_symbols()
    benchmarks = Enum.filter(@benchmark_symbols, &(&1 in cached))
    benchmarks ++ Enum.sort(cached -- benchmarks)
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
    |> where([b], b.interval == "day")
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
  # Chart tier (TRADING_TAB_ROADMAP Phase 4)
  # ---------------------------------------------------------------------------

  @doc """
  Store chart-tier OHLCV rows for one symbol+interval. Full-row upsert — unlike
  the closes tier this REPLACES OHLC, because these rows are the fresher truth
  for every field.
  """
  def store_ohlc(symbol, interval, rows)
      when is_binary(symbol) and interval in ["day", "week"] and is_list(rows) do
    Enum.count(rows, fn row ->
      result =
        %Bar{}
        |> Bar.changeset(%{
          symbol: symbol,
          bar_on: row.bar_on,
          interval: interval,
          open_cents: round(row.open * 100),
          high_cents: round(row.high * 100),
          low_cents: round(row.low * 100),
          close_cents: round(row.close * 100),
          volume: row.volume
        })
        |> Repo.insert(
          on_conflict:
            {:replace, [:open_cents, :high_cents, :low_cents, :close_cents, :volume, :updated_at]},
          conflict_target: [:symbol, :bar_on, :interval]
        )

      case result do
        {:ok, _bar} ->
          true

        {:error, changeset} ->
          Logger.warning(
            "MarketData: refusing OHLC #{symbol} #{row.bar_on}: #{inspect(changeset.errors)}"
          )

          false
      end
    end)
  end

  @doc "Bars for a symbol chart: one interval, from a start date, oldest first."
  def chart_bars(symbol, interval, %Date{} = from)
      when is_binary(symbol) and interval in ["day", "week"] do
    Bar
    |> where([b], b.symbol == ^symbol and b.interval == ^interval and b.bar_on >= ^from)
    |> order_by([b], asc: b.bar_on)
    |> Repo.all()
  end

  @doc """
  True when cached bars can draw candles for the window without a fetch:
  full-OHLC rows exist reaching back to (near) `from` and forward to (near) the
  latest trading day. "Near" is a few days of slack at the old end — a symbol
  younger than the window can never cover it exactly — and an interval's width
  at the new end.
  """
  def chart_coverage?(symbol, interval, %Date{} = from, %Date{} = today) do
    edges =
      Bar
      |> where([b], b.symbol == ^symbol and b.interval == ^interval)
      |> where([b], not is_nil(b.open_cents) and b.bar_on >= ^from)
      |> select([b], {min(b.bar_on), max(b.bar_on), count(b.id)})
      |> Repo.one()

    case edges do
      {%Date{} = oldest, %Date{} = newest, count} when count > 1 ->
        target_end = MarketCalendar.latest_trading_day(today)

        # One trading day of lag is tolerated at the new end: the API doesn't
        # materialize today's daily bar until well after the close (measured
        # twice, 07-28), and without this allowance a freshly-fetched chart
        # reads as uncovered all evening — every candle toggle would re-spend a
        # ~2-minute agent run to learn nothing new.
        acceptable_end =
          case interval do
            "day" -> MarketCalendar.latest_trading_day(Date.add(target_end, -1))
            "week" -> Date.add(target_end, -7)
          end

        Date.diff(oldest, from) <= 7 and Date.compare(newest, acceptable_end) != :lt

      _other ->
        false
    end
  end

  # ---------------------------------------------------------------------------
  # Quotes blob
  # ---------------------------------------------------------------------------

  @doc "Cache the sweep's quotes + indexes + earnings with an app-side stamp."
  def store_quotes(%{quotes: quotes, indexes: indexes} = parsed) do
    Settings.put(
      @quotes_key,
      Jason.encode!(%{
        "quotes" => quotes,
        "indexes" => indexes,
        "earnings" => Map.get(parsed, :earnings, []),
        "fetched_at" => DateTime.utc_now() |> DateTime.to_iso8601()
      })
    )
  end

  @doc """
  Upcoming earnings for held symbols (TRADING_TAB_ROADMAP Phase 5), from the
  sweep's cached calendar: `[%{symbol, date: Date, timing: "am"|"pm"|nil}]`,
  soonest first, today's report included — a report happening TODAY is the one
  you most want on screen. Past dates are dropped rather than displayed stale.
  """
  def upcoming_earnings(%Date{} = today) do
    case earnings_summary(today) do
      {:ok, %{earnings: earnings}} -> earnings
      :none -> []
    end
  end

  @doc "Explicit freshness/availability state for the cached earnings calendar."
  def earnings_state(%Date{} = today) do
    with {:ok, blob} <- cached_quotes(),
         rows when is_list(rows) <- blob["earnings"],
         {:ok, fetched_at, _} <- DateTime.from_iso8601(blob["fetched_at"] || "") do
      earnings =
        rows
        |> Enum.filter(&is_map/1)
        |> Enum.map(fn row ->
          case Date.from_iso8601(to_string(row["date"] || "")) do
            {:ok, date} -> %{symbol: row["symbol"], date: date, timing: row["timing"]}
            _error -> nil
          end
        end)
        |> Enum.reject(&is_nil/1)
        |> Enum.filter(&(Date.compare(&1.date, today) != :lt))
        |> Enum.sort_by(& &1.date, Date)

      cached_list_state(earnings, quotes_stale?(blob), fetched_at, :earnings)
    else
      _ -> DataState.unavailable(:unreadable_cache, source: :earnings)
    end
  end

  @doc """
  Upcoming earnings plus the cache state that makes an empty list meaningful.

  `:none` means the sweep has never produced a readable earnings payload.
  `{:ok, ...}` means the list is known (possibly empty) and carries its age.
  """
  def earnings_summary(%Date{} = today) do
    case earnings_state(today) do
      %DataState{status: status, data: earnings, as_of: fetched_at}
      when status in [:fresh, :stale, :confirmed_empty] ->
        {:ok, %{earnings: earnings, fetched_at: fetched_at, stale?: status == :stale}}

      %DataState{} ->
        :none
    end
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

  @doc """
  The hero row's index chips (TRADING_TAB_ROADMAP Phase 2):
  `{:ok, %{indexes: [...], fetched_at: DateTime, stale?: bool}}` or `:none`.

  Day change per index is the given `change_pct` when the tool provided one, or
  OUR division over `price` and `prev_close` when it provided those — two
  tool-sourced numbers and our arithmetic, never the model's (the 07-28 live
  sweep returned `change_pct: null` for both indexes). Neither available →
  nil, and the chip renders a written "—", not a zero.
  """
  def index_summary do
    with {:ok, blob} <- cached_quotes(),
         [_ | _] = indexes <- blob["indexes"],
         {:ok, fetched_at, _} <- DateTime.from_iso8601(blob["fetched_at"] || "") do
      {:ok,
       %{
         indexes: Enum.map(indexes, &index_chip/1),
         fetched_at: fetched_at,
         stale?: quotes_stale?(blob)
       }}
    else
      _ -> :none
    end
  end

  @doc "Explicit freshness/availability state for the cached market indexes."
  def index_state do
    with {:ok, blob} <- cached_quotes(),
         indexes when is_list(indexes) <- blob["indexes"],
         {:ok, fetched_at, _} <- DateTime.from_iso8601(blob["fetched_at"] || "") do
      indexes
      |> Enum.filter(&is_map/1)
      |> Enum.map(&index_chip/1)
      |> cached_list_state(quotes_stale?(blob), fetched_at, :indexes)
    else
      _ -> DataState.unavailable(:unreadable_cache, source: :indexes)
    end
  end

  defp index_chip(row) do
    %{
      label: index_label(row),
      price: row["price"],
      change_pct: change_pct_of(row)
    }
  end

  # Given by the tool, or our division over two tool-sourced numbers, or nil.
  # Shared by index chips and equity quotes: the honesty rule is the same.
  defp change_pct_of(row), do: row["change_pct"] || derived_change_pct(row)

  defp index_label(row) do
    case row["name"] do
      name when is_binary(name) and name != "" -> name
      _other -> row["symbol"]
    end
  end

  defp derived_change_pct(%{"price" => price, "prev_close" => prev})
       when is_number(price) and is_number(prev) and prev > 0,
       do: (price / prev - 1) * 100

  defp derived_change_pct(_row), do: nil

  @doc """
  One symbol's cached quote (TRADING_TAB_ROADMAP Phase 3):
  `%{price: number, change_pct: number | nil}` or nil. Same change derivation
  as the index chips — the tool's own figure, else our division over price and
  prev_close, else nil.
  """
  def quote_for(symbol) when is_binary(symbol) do
    with {:ok, blob} <- cached_quotes(),
         %{} = row <- Enum.find(List.wrap(blob["quotes"]), &(&1["symbol"] == symbol)),
         price when is_number(price) <- row["price"] do
      %{price: price, change_pct: change_pct_of(row)}
    else
      _ -> nil
    end
  end

  @doc "One symbol's display price with explicit freshness and source."
  def price_state_for(symbol) when is_binary(symbol) do
    with {:ok, blob} <- cached_quotes(),
         %{} = row <- Enum.find(List.wrap(blob["quotes"]), &(&1["symbol"] == symbol)),
         price when is_number(price) <- row["price"],
         {:ok, at, _} <- DateTime.from_iso8601(blob["fetched_at"] || "") do
      DataState.cached(
        %{price_cents: round(price * 100), change_pct: change_pct_of(row)},
        quotes_stale?(blob),
        as_of: at,
        source: :quotes
      )
    else
      _ ->
        case latest_close(symbol) do
          nil ->
            DataState.unavailable(:no_price, source: :daily_close)

          close ->
            DataState.cached(
              %{price_cents: close.close_cents, change_pct: nil},
              Date.compare(
                close.bar_on,
                MarketCalendar.latest_trading_day(MarketCalendar.today())
              ) == :lt,
              as_of: close.bar_on,
              source: :daily_close
            )
        end
    end
  end

  @doc "A symbol's newest cached close, `%{bar_on: Date, close_cents: integer}` or nil."
  def latest_close(symbol) when is_binary(symbol) do
    Bar
    |> where([b], b.symbol == ^symbol and b.interval == "day")
    |> order_by([b], desc: b.bar_on)
    |> limit(1)
    |> Repo.one()
    |> case do
      nil -> nil
      bar -> %{bar_on: bar.bar_on, close_cents: bar.close_cents}
    end
  end

  @doc """
  What "current prices" means right now, for the panel's as-of line:
  `{:quotes, DateTime}` when a quotes blob exists, else `{:bars, Date}` from
  the newest close, else `:none`. One line for the whole panel — per-row
  staleness would be noise.
  """
  def prices_as_of do
    with {:ok, blob} <- cached_quotes(),
         {:ok, at, _} <- DateTime.from_iso8601(blob["fetched_at"] || "") do
      {:quotes, at}
    else
      _ ->
        case latest_bar_on() do
          nil -> :none
          day -> {:bars, day}
        end
    end
  end

  @doc "Explicit freshness/availability state for prices used by the positions panel."
  def prices_state do
    with {:ok, blob} <- cached_quotes(),
         [_ | _] <- List.wrap(blob["quotes"]),
         {:ok, at, _} <- DateTime.from_iso8601(blob["fetched_at"] || "") do
      DataState.cached({:quotes, at}, quotes_stale?(blob), as_of: at, source: :quotes)
    else
      _ ->
        case latest_bar_on() do
          nil ->
            DataState.unavailable(:no_prices, source: :daily_close)

          day ->
            DataState.cached(
              {:bars, day},
              not fresh?(MarketCalendar.today()),
              as_of: day,
              source: :daily_close
            )
        end
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

  defp cached_list_state([], false, fetched_at, source),
    do: DataState.confirmed_empty(as_of: fetched_at, source: source)

  defp cached_list_state(rows, stale?, fetched_at, source),
    do: DataState.cached(rows, stale?, as_of: fetched_at, source: source)
end
