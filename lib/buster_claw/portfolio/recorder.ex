defmodule BusterClaw.Portfolio.Recorder do
  @moduledoc """
  The daily portfolio recorder (PORTFOLIO_HISTORY_ROADMAP Phase 1).

  Opening the Trading tab is not a schedule. Phase 0 records whenever you happen
  to look, which leaves the series full of holes on the days you didn't — and
  because Robinhood keeps no value history, a hole is permanent. This process
  closes them: once per trading day, after the close, it runs stage 1 and files
  the reading itself.

  Modeled on the other supervised pumps (`Notifications.Scheduler`,
  `Orchestration.Uptime`): config-gated in `application.ex`, off in tests,
  crash-safe, and it **arms a timer to the next moment rather than polling hot**
  — a daily job has no business waking every minute.

  ## Discipline

  - **Trading days only.** `MarketCalendar` decides; weekends and exchange
    holidays are skipped entirely rather than recorded as duplicates of the
    prior close.
  - **After the close.** Fires at #{16}:30 Eastern, half an hour past the bell,
    so the reading reflects a settled closing value rather than a mid-session
    quote.
  - **Once per day.** If any reading already exists for today — because you
    opened the tab — the pump does nothing. It fills gaps; it does not compete.
  - **Never a placeholder.** A failed run logs and waits for tomorrow. Writing a
    guess to avoid a gap would be the one unrecoverable mistake.
  - **Self-healing clock.** The timer is capped at `@max_idle_ms`, so a laptop
    that sleeps through the fire moment re-checks on wake instead of waiting a
    full day.

  Each run is a real agent run against a flaky remote (~28s, cents). Once daily
  is the whole budget; there is no retry loop, on purpose.
  """
  use GenServer

  require Logger

  alias BusterClaw.MarketCalendar
  alias BusterClaw.MarketData
  alias BusterClaw.Portfolio
  alias BusterClaw.Trading

  # Half an hour after the 4pm ET bell.
  @fire_time ~T[16:30:00]
  # Never sleep longer than this, so a suspended machine self-heals on wake.
  @max_idle_ms 30 * 60 * 1000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "Force an immediate evaluation (tests / manual nudge)."
  def tick_now(server \\ __MODULE__), do: send(server, :tick)

  @impl true
  def init(opts) do
    state = %{
      fire_time: Keyword.get(opts, :fire_time, @fire_time),
      autostart: Keyword.get(opts, :autostart, true)
    }

    # A tick on boot is the catch-up path: an app opened at 8pm on a trading day
    # it never saw records that day immediately rather than losing it.
    if state.autostart, do: send(self(), :tick)
    {:ok, state}
  end

  @impl true
  def handle_info(:tick, state) do
    run_if_due(state)
    {:noreply, state, {:continue, :rearm}}
  end

  @impl true
  def handle_continue(:rearm, state) do
    Process.send_after(self(), :tick, sleep_ms(state))
    {:noreply, state}
  end

  # Two independent duties per trading day, each with its own already-done
  # latch: file the balance reading, and run the market-data sweep
  # (TRADING_TAB_ROADMAP Phase 1). Independent because either can be satisfied
  # without the other — opening the Trading tab records balances but fetches no
  # bars, and neither duty may re-fire on the ~30-minute self-heal ticks that
  # follow.
  defp run_if_due(state) do
    today = MarketCalendar.today()

    if MarketCalendar.trading_day?(today) and past_fire_time?(state, today) do
      unless Portfolio.recorded_on?(today), do: record_today(today)
      unless MarketData.attempted_on?(today), do: sweep_market_data(today)
      unless MarketData.benchmark_attempted_on?(today), do: backfill_one_benchmark(today)
    end

    :ok
  rescue
    error ->
      # A bad tick is logged, never fatal — the supervisor restarting this
      # process would only make it try the same thing again immediately.
      Logger.warning("Portfolio.Recorder: tick failed: #{inspect(error)}")
      :ok
  end

  defp record_today(today) do
    Logger.info("Portfolio.Recorder: recording #{today}")

    case Trading.fetch_account_snapshot() do
      {:ok, snapshot} ->
        case Portfolio.record(snapshot, day: today, source: "daily_pump") do
          {:ok, count} ->
            Logger.info("Portfolio.Recorder: recorded #{count} account(s) for #{today}")

          {:error, reason} ->
            Logger.warning(
              "Portfolio.Recorder: nothing recorded for #{today}: #{inspect(reason)}"
            )
        end

      {:error, reason} ->
        # No placeholder row. Tomorrow's tick tries again; today stays a gap,
        # which the chart draws honestly.
        Logger.warning("Portfolio.Recorder: fetch failed for #{today}: #{inspect(reason)}")
    end
  end

  defp sweep_market_data(today) do
    Logger.info("Portfolio.Recorder: market sweep for #{today}")

    case MarketData.refresh(today) do
      {:ok, %{symbols: symbols, bars: bars}} ->
        Logger.info("Portfolio.Recorder: cached #{bars} bar(s) for #{length(symbols)} symbol(s)")

      {:error, reason} ->
        # No placeholder rows. The attempt is latched, so tomorrow retries;
        # today's sparklines simply stay a day older.
        Logger.warning("Portfolio.Recorder: market sweep failed: #{inspect(reason)}")
    end
  end

  # ONE benchmark per DAY, on purpose, and latched like the other two duties.
  #
  # Four symbols × a year each is four agent runs; doing them together would turn
  # a routine tick into a multi-minute burst, and each run is independently
  # ~1-in-6 flaky. Filling over four days costs nothing — nobody is waiting on
  # it — while a failure simply retries tomorrow.
  #
  # The latch is not optional. `benchmarks_needing_backfill/0` reads the shortfall
  # from the data, which self-limits on *success* but not on *failure*: without
  # the latch, a benchmark the broker cannot return would re-spend a
  # minutes-long blocking run on every ~30-minute self-heal tick, all day. Same
  # reasoning, and the same per-attempt semantics, as the sweep's own latch.
  defp backfill_one_benchmark(today) do
    case MarketData.symbols_needing_backfill() do
      [] ->
        :ok

      [symbol | _rest] ->
        MarketData.mark_benchmark_attempt(today)
        Logger.info("Portfolio.Recorder: backfilling benchmark #{symbol}")

        case MarketData.backfill_benchmark(symbol, today) do
          {:ok, %{bars: bars}} ->
            Logger.info("Portfolio.Recorder: cached #{bars} bar(s) for #{symbol}")
            MarketData.record_backfill_outcome(symbol, {:ok, bars}, today)
            observe_backfill(symbol, "cached #{bars} bar(s)", %{bars: bars}, :info)

          {:error, reason} ->
            Logger.warning(
              "Portfolio.Recorder: benchmark #{symbol} backfill failed: #{inspect(reason)}"
            )

            MarketData.record_backfill_outcome(symbol, {:error, reason}, today)

            observe_backfill(
              symbol,
              "backfill failed",
              %{reason: inspect(reason)},
              :warning
            )
        end
    end
  end

  # A daily job that fails only into `Logger` is indistinguishable from one that
  # works — which is exactly what happened on 08-04, when a single failed attempt
  # was read as a broken feature by three readers at once. Each attempt is worth
  # ~$0.57 of model time, so its outcome belongs on the durable trail beside
  # every other run this app spends money on.
  defp observe_backfill(symbol, message, meta, severity) do
    BusterClaw.Sentinel.observe(
      :command_invoke,
      "Benchmark #{symbol}: #{message}",
      Map.merge(meta, %{source: "market_data_backfill", symbol: symbol}),
      severity: severity
    )
  rescue
    # Observability must never be the thing that breaks the recorder's tick.
    _error -> :ok
  end

  defp past_fire_time?(state, today) do
    case fire_moment(state, today) do
      nil -> false
      moment -> DateTime.compare(MarketCalendar.now(), moment) != :lt
    end
  end

  # Milliseconds until the next fire moment, floored at one second (never a busy
  # loop) and capped at @max_idle_ms (so a slept-through moment self-heals).
  defp sleep_ms(state) do
    now = MarketCalendar.now()

    case next_fire_moment(state, DateTime.to_date(now)) do
      nil ->
        @max_idle_ms

      moment ->
        moment
        |> DateTime.diff(now, :millisecond)
        |> max(1_000)
        |> min(@max_idle_ms)
    end
  end

  # Today's fire moment if it is still ahead of us and today trades; otherwise
  # the next trading day's.
  defp next_fire_moment(state, today) do
    now = MarketCalendar.now()

    todays =
      if MarketCalendar.trading_day?(today), do: fire_moment(state, today), else: nil

    if todays && DateTime.compare(now, todays) == :lt do
      todays
    else
      case next_trading_day(today) do
        nil -> nil
        day -> fire_moment(state, day)
      end
    end
  end

  defp next_trading_day(from) do
    # Bounded: the longest run of consecutive non-trading days is a holiday
    # weekend, so ten is generous and guarantees termination.
    Enum.find_value(1..10, fn offset ->
      day = Date.add(from, offset)
      if MarketCalendar.trading_day?(day), do: day
    end)
  end

  defp fire_moment(state, %Date{} = day) do
    case DateTime.new(day, state.fire_time, MarketCalendar.zone()) do
      {:ok, moment} -> moment
      # A DST gap or ambiguity at 16:30 doesn't occur (transitions are at 2am),
      # but an unresolvable zone must degrade to "not due" rather than crash.
      _other -> nil
    end
  end
end
