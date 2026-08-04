defmodule BusterClaw.Portfolio.RecorderTest do
  # async: false — the recorder runs in its own process and needs the shared
  # sandbox connection, and the tests move the global :local_today seam.
  use BusterClaw.DataCase, async: false

  alias BusterClaw.Portfolio
  alias BusterClaw.Portfolio.Recorder

  # A trading day comfortably in the past, so the real clock is always past its
  # 16:30 ET fire moment.
  @past_trading_day ~D[2026-07-27]
  @saturday ~D[2026-07-25]
  @holiday ~D[2026-07-03]

  setup do
    prev_today = Application.get_env(:buster_claw, :local_today)
    prev_fetcher = Application.get_env(:buster_claw, :trading_snapshot_fetcher)
    prev_market = Application.get_env(:buster_claw, :trading_market_data_fetcher)
    prev_bars = Application.get_env(:buster_claw, :trading_bars_fetcher)

    # The Recorder's second duty (the market sweep) fires on any un-attempted
    # trading day; without a stub every balance test here would spawn a REAL
    # agent run for it.
    Application.put_env(:buster_claw, :trading_market_data_fetcher, fn _start ->
      {:ok, %{closes: %{}, quotes: [], indexes: [], skipped: [], errors: []}}
    end)

    # And its third (the benchmark backfill), for exactly the same reason —
    # unstubbed it BLOCKS the recorder on a real agent run, so `:sys.get_state`
    # times out and every test in this file fails on a symptom that names none
    # of this.
    Application.put_env(:buster_claw, :trading_bars_fetcher, fn _symbol, _start, _interval ->
      {:ok, %{bars: []}}
    end)

    on_exit(fn ->
      Application.put_env(:buster_claw, :local_today, prev_today)
      Application.put_env(:buster_claw, :trading_snapshot_fetcher, prev_fetcher)
      Application.put_env(:buster_claw, :trading_market_data_fetcher, prev_market)
      Application.put_env(:buster_claw, :trading_bars_fetcher, prev_bars)
    end)

    :ok
  end

  defp stub_fetcher(result) do
    test_pid = self()

    Application.put_env(:buster_claw, :trading_snapshot_fetcher, fn ->
      send(test_pid, :fetch_called)
      result
    end)
  end

  defp snapshot do
    %{
      "accounts" => [
        %{"id" => "••••6587", "last4" => "6587", "label" => "Agentic", "value" => 102.24},
        %{"id" => "••••8262", "last4" => "8262", "label" => "Roth IRA", "value" => 211.99}
      ],
      "fetched_at" => "2026-07-27T00:00:00Z"
    }
  end

  # Start a recorder that does NOT autostart, then tick it deliberately, so each
  # test controls exactly one evaluation. The default registered name is safe:
  # start_supervised tears its instance down between tests, so only one is ever
  # running.
  defp start_recorder do
    start_supervised!({Recorder, autostart: false})
  end

  defp tick_and_settle(pid) do
    Recorder.tick_now(pid)
    # Two round-trips: the tick itself, then the :rearm continue.
    _ = :sys.get_state(pid)
    _ = :sys.get_state(pid)
  end

  test "records a trading day that has no reading yet" do
    Application.put_env(:buster_claw, :local_today, @past_trading_day)
    stub_fetcher({:ok, snapshot()})

    pid = start_recorder()
    tick_and_settle(pid)

    assert_receive :fetch_called
    rows = Portfolio.all_snapshots()
    assert length(rows) == 2
    assert Enum.all?(rows, &(&1.captured_on == @past_trading_day))
    # The source distinguishes a pumped day from one you happened to look at.
    assert Enum.all?(rows, &(&1.source == "daily_pump"))
  end

  test "does nothing on a Saturday" do
    Application.put_env(:buster_claw, :local_today, @saturday)
    stub_fetcher({:ok, snapshot()})

    pid = start_recorder()
    tick_and_settle(pid)

    refute_receive :fetch_called, 50
    assert Portfolio.all_snapshots() == []
  end

  test "does nothing on an observed market holiday" do
    Application.put_env(:buster_claw, :local_today, @holiday)
    stub_fetcher({:ok, snapshot()})

    pid = start_recorder()
    tick_and_settle(pid)

    refute_receive :fetch_called, 50
    assert Portfolio.all_snapshots() == []
  end

  test "does not compete with a reading the Trading tab already filed" do
    Application.put_env(:buster_claw, :local_today, @past_trading_day)

    # The tab recorded first.
    {:ok, 2} = Portfolio.record(snapshot(), day: @past_trading_day, source: "tab_open")

    stub_fetcher({:ok, snapshot()})
    pid = start_recorder()
    tick_and_settle(pid)

    # No agent run was spent, and the tab's rows are untouched.
    refute_receive :fetch_called, 50
    assert Enum.all?(Portfolio.all_snapshots(), &(&1.source == "tab_open"))
  end

  test "does not fire before the day's close" do
    # Today, evaluated against the real clock. Before 16:30 ET this must not
    # fire; after it, it may — so the assertion is conditional on the actual
    # moment rather than pretending the clock is fixed.
    today = BusterClaw.MarketCalendar.today()
    Application.put_env(:buster_claw, :local_today, today)
    stub_fetcher({:ok, snapshot()})

    now = BusterClaw.MarketCalendar.now()
    before_close? = now.hour < 16 or (now.hour == 16 and now.minute < 30)

    pid = start_recorder()
    tick_and_settle(pid)

    if BusterClaw.MarketCalendar.trading_day?(today) and not before_close? do
      assert_receive :fetch_called
    else
      refute_receive :fetch_called, 50
      assert Portfolio.all_snapshots() == []
    end
  end

  test "a failed fetch writes no placeholder row" do
    Application.put_env(:buster_claw, :local_today, @past_trading_day)
    stub_fetcher({:error, {:robinhood, "not authenticated"}})

    pid = start_recorder()
    tick_and_settle(pid)

    assert_receive :fetch_called
    # A gap is recoverable; a guessed row is not.
    assert Portfolio.all_snapshots() == []
  end

  test "a fetch that raises does not take the recorder down" do
    Application.put_env(:buster_claw, :local_today, @past_trading_day)

    Application.put_env(:buster_claw, :trading_snapshot_fetcher, fn ->
      raise "boom"
    end)

    pid = start_recorder()
    tick_and_settle(pid)

    assert Process.alive?(pid)
    assert Portfolio.all_snapshots() == []
  end

  test "it re-arms after every tick, so one bad day doesn't stop the pump" do
    Application.put_env(:buster_claw, :local_today, @saturday)
    stub_fetcher({:ok, snapshot()})

    pid = start_recorder()
    tick_and_settle(pid)
    assert Process.alive?(pid)

    # A second tick still evaluates cleanly, and a trading day now records.
    Application.put_env(:buster_claw, :local_today, @past_trading_day)
    tick_and_settle(pid)

    assert_receive :fetch_called
    assert length(Portfolio.all_snapshots()) == 2
  end

  describe "the market sweep duty" do
    defp stub_market(result) do
      test_pid = self()

      Application.put_env(:buster_claw, :trading_market_data_fetcher, fn start ->
        send(test_pid, {:sweep_called, start})
        result
      end)
    end

    defp market_parsed(closes) do
      %{closes: closes, quotes: [], indexes: [], skipped: [], errors: []}
    end

    test "sweeps after recording, and bars land in the cache" do
      Application.put_env(:buster_claw, :local_today, @past_trading_day)
      stub_fetcher({:ok, snapshot()})

      stub_market({:ok, market_parsed(%{"GOOGL" => [%{bar_on: ~D[2026-07-24], close: 347.52}]})})

      pid = start_recorder()
      tick_and_settle(pid)

      assert_receive {:sweep_called, _start}
      assert BusterClaw.MarketData.known_symbols() == ["GOOGL"]
    end

    test "sweeps even when the tab already recorded today's balances" do
      Application.put_env(:buster_claw, :local_today, @past_trading_day)
      {:ok, 2} = Portfolio.record(snapshot(), day: @past_trading_day, source: "tab_open")
      stub_fetcher({:ok, snapshot()})
      stub_market({:ok, market_parsed(%{})})

      pid = start_recorder()
      tick_and_settle(pid)

      # Balances were satisfied by the tab; the sweep is an independent duty.
      refute_receive :fetch_called, 50
      assert_receive {:sweep_called, _start}
    end

    test "the attempt latch stops a second sweep the same day" do
      Application.put_env(:buster_claw, :local_today, @past_trading_day)
      stub_fetcher({:ok, snapshot()})
      stub_market({:ok, market_parsed(%{})})

      pid = start_recorder()
      tick_and_settle(pid)
      assert_receive {:sweep_called, _start}

      tick_and_settle(pid)
      refute_receive {:sweep_called, _start}, 50
    end

    test "no sweep on a weekend" do
      Application.put_env(:buster_claw, :local_today, @saturday)
      stub_fetcher({:ok, snapshot()})
      stub_market({:ok, market_parsed(%{})})

      pid = start_recorder()
      tick_and_settle(pid)

      refute_receive {:sweep_called, _start}, 50
    end

    test "a failed sweep writes no bars and does not take the recorder down" do
      Application.put_env(:buster_claw, :local_today, @past_trading_day)
      stub_fetcher({:ok, snapshot()})
      stub_market({:error, {:robinhood, "down"}})

      pid = start_recorder()
      tick_and_settle(pid)

      assert_receive {:sweep_called, _start}
      assert Process.alive?(pid)
      assert BusterClaw.MarketData.known_symbols() == []
    end
  end

  test "the autostart path ticks on boot — the catch-up for a day opened late" do
    Application.put_env(:buster_claw, :local_today, @past_trading_day)
    stub_fetcher({:ok, snapshot()})

    start_supervised!(Recorder)

    assert_receive :fetch_called, 1_000
  end

  describe "the benchmark backfill duty" do
    test "fills one benchmark, and the latch stops a second attempt the same day" do
      # The latch is the point. `benchmarks_needing_backfill/0` self-limits on
      # SUCCESS, but a benchmark the broker cannot return would otherwise
      # re-spend a minutes-long blocking run on every ~30-minute self-heal tick.
      test_pid = self()

      Application.put_env(:buster_claw, :trading_bars_fetcher, fn symbol, _start, _interval ->
        send(test_pid, {:bars_called, symbol})

        {:ok,
         %{
           bars:
             for i <- 1..245 do
               %{
                 bar_on: Date.add(~D[2025-01-01], i),
                 open: 400.0,
                 high: 400.0,
                 low: 400.0,
                 close: 400.0 + i,
                 volume: 1
               }
             end
         }}
      end)

      Application.put_env(:buster_claw, :local_today, @past_trading_day)
      stub_fetcher({:error, :nope})

      pid = start_recorder()
      tick_and_settle(pid)

      assert_received {:bars_called, "SPY"}
      assert length(BusterClaw.MarketData.bars("SPY")) == 245

      # Second tick, same day: no further run, even though QQQ still needs one.
      tick_and_settle(pid)
      refute_received {:bars_called, _symbol}
      assert "QQQ" in BusterClaw.MarketData.benchmarks_needing_backfill()
    end

    test "a failing backfill still latches, so it cannot burn a run every tick" do
      test_pid = self()

      Application.put_env(:buster_claw, :trading_bars_fetcher, fn symbol, _start, _interval ->
        send(test_pid, {:bars_called, symbol})
        {:error, :robinhood_down}
      end)

      Application.put_env(:buster_claw, :local_today, @past_trading_day)
      stub_fetcher({:error, :nope})

      pid = start_recorder()
      tick_and_settle(pid)
      assert_received {:bars_called, "SPY"}

      tick_and_settle(pid)
      refute_received {:bars_called, _symbol}
      # Nothing written, so tomorrow tries again — the same posture as a failed
      # sweep or a failed balance reading.
      assert BusterClaw.MarketData.bars("SPY") == []
    end

    test "a failing backfill does not take the recorder down with it" do
      Application.put_env(:buster_claw, :trading_bars_fetcher, fn _s, _start, _i ->
        raise "kaboom"
      end)

      Application.put_env(:buster_claw, :local_today, @past_trading_day)
      stub_fetcher({:error, :nope})

      pid = start_recorder()
      tick_and_settle(pid)

      assert Process.alive?(pid)
    end
  end
end
