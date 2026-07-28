defmodule BusterClawWeb.TradingLiveTest do
  # async: false — points the global :workspace_root at a tmp dir and stubs the
  # trading fetcher seams in the app env.
  use BusterClawWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  setup do
    root = Path.join(System.tmp_dir!(), "bc_trading_live_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, "memory"))

    prev = Application.get_env(:buster_claw, :workspace_root)
    Application.put_env(:buster_claw, :workspace_root, root)

    # Force CLI detection so assertions don't depend on the host having
    # `claude` on PATH (CI runners don't).
    prev_cli = Application.get_env(:buster_claw, :agent_cli)
    Application.put_env(:buster_claw, :agent_cli, {:claude, "/usr/local/bin/claude"})

    # Mounting /trading starts an account-snapshot fetch, which would otherwise
    # spawn a REAL claude run from a test. Default seams: errors the panel
    # renders honestly; individual tests override with richer fetchers.
    prev_fetcher = Application.get_env(:buster_claw, :trading_snapshot_fetcher)
    prev_detail = Application.get_env(:buster_claw, :trading_detail_fetcher)

    Application.put_env(:buster_claw, :trading_snapshot_fetcher, fn ->
      {:error, {:robinhood, "disabled in test"}}
    end)

    Application.put_env(:buster_claw, :trading_detail_fetcher, fn _last4 ->
      {:error, {:robinhood, "detail disabled in test"}}
    end)

    on_exit(fn ->
      Application.put_env(:buster_claw, :workspace_root, prev)
      Application.put_env(:buster_claw, :agent_cli, prev_cli)
      Application.put_env(:buster_claw, :trading_snapshot_fetcher, prev_fetcher)
      Application.put_env(:buster_claw, :trading_detail_fetcher, prev_detail)
      File.rm_rf(root)
    end)

    {:ok, root: root}
  end

  describe "the trading dashboard" do
    test "renders the banner, the split, and first-run setup", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/trading")

      # The banner names the write scope: reads span every account, orders one.
      assert html =~ "Real orders execute on the Robinhood agentic account"
      assert html =~ "every other account is read-only"
      assert html =~ "claude mcp login robinhood"
      assert html =~ "#65895"
      # The chat surface renders without the conversation strip.
      assert html =~ ~s(id="home-agent-chat")
      refute html =~ ~s(phx-click="select_chat")
      # The chat/account partition is draggable (parameterized SplitResizer).
      assert html =~ ~s(id="trading-split")
      assert html =~ ~s(phx-hook="SplitResizer")
      assert html =~ ~s(data-resize-var="--trading-left")
      assert html =~ "data-split-divider"
    end

    test "a broadcast message renders live, and the transcript survives a remount",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/trading")

      send(
        view.pid,
        {:agent_chat, "trading", {:message, %{role: :assistant, text: "AAPL $210.11"}}}
      )

      _ = :sys.get_state(view.pid)
      assert render(view) =~ "AAPL $210.11"

      # The durable transcript is what a fresh mount reads back.
      BusterClaw.Agent.Transcript.record("trading", :assistant, "Filled 1 VOO")
      {:ok, _view2, html} = live(conn, ~p"/trading")
      assert html =~ "Filled 1 VOO"
    end

    test "stage 1 puts every account on screen before any holdings exist", %{conn: conn} do
      # Stage 2 is parked so the intermediate state is observable rather than
      # racing past — the whole point of the split is that balances land first.
      # render_async is avoided here on purpose: it would wait on the parked run.
      test_pid = self()

      Application.put_env(:buster_claw, :trading_snapshot_fetcher, fn ->
        {:ok, multi_account_snapshot()}
      end)

      Application.put_env(:buster_claw, :trading_detail_fetcher, fn last4 ->
        send(test_pid, {:detail_requested, last4})
        Process.sleep(:infinity)
      end)

      {:ok, view, html} = live(conn, ~p"/trading")
      assert html =~ "trading-account-card"

      html = render_async(view)

      # The combined view has no single account to detail, so stage 2 never runs
      # — three accounts' holdings would be three agent runs nobody asked for.
      refute_receive {:detail_requested, _}, 50

      # Every account is a chip, and the header carries the combined total
      # (3.38 + 900 + 12.5) — all of it with no holdings fetched yet.
      assert html =~ "Investing"
      assert html =~ "Roth IRA"
      assert html =~ "Crypto"
      assert html =~ "$915.88"
      assert html =~ "$3.38"
      refute html =~ "VOO"

      # Selecting an account is what starts its holdings fetch, and until it
      # lands the panel says so rather than showing an empty list.
      html = render_click(view, "trading_select_account", %{"id" => "••••6587"})
      assert_receive {:detail_requested, "6587"}
      refute_receive {:detail_requested, "4821"}, 50

      assert html =~ "Buying power"
      assert html =~ "Orders execute here"
      assert html =~ "Loading holdings…"
      refute html =~ "VOO"
    end

    test "stage 2 fills in the selected account's holdings", %{conn: conn} do
      stub_trading_fetchers()

      {:ok, view, _html} = live(conn, ~p"/trading")
      html = render_async(view)
      assert html =~ "$915.88"

      render_click(view, "trading_select_account", %{"id" => "••••6587"})
      html = render_async(view)

      assert html =~ "VOO"
      assert html =~ "as of"

      # Allocation bars: the largest position reads full-width; the smaller one
      # is proportional (0.5 / 1.0 = 50%).
      assert html =~ "width: 100.0%"
      assert html =~ "width: 50.0%"

      # Trades: side is WRITTEN (buy), with the status chip class, never
      # color-alone.
      assert html =~ "buy"
      assert html =~ "text-success"
      assert html =~ "filled"

      # Both stages persisted — a cached read has the accounts AND the holdings.
      assert {:ok, %{"accounts" => accounts}} = BusterClaw.Trading.cached_snapshot()
      assert length(accounts) == 3
      assert Enum.any?(accounts, &BusterClaw.Trading.detail_loaded?/1)
    end

    test "an unexplained jump prompts, and marking it as a deposit clears it", %{conn: conn} do
      alias BusterClaw.Portfolio

      # Yesterday the agentic account held $3.38 (the fixture's value); today a
      # $500 transfer landed. Seed yesterday so today's stage-1 reading is a jump.
      {:ok, _} =
        Portfolio.record(
          %{"accounts" => [%{"last4" => "6587", "label" => "Investing", "value" => 3.38}]},
          day: Date.add(BusterClaw.MarketCalendar.today(), -1)
        )

      Application.put_env(:buster_claw, :trading_snapshot_fetcher, fn ->
        snap = multi_account_snapshot()

        accounts =
          Enum.map(snap["accounts"], fn a ->
            if a["last4"] == "6587", do: Map.put(a, "value", 503.38), else: a
          end)

        {:ok, %{snap | "accounts" => accounts}}
      end)

      Application.put_env(:buster_claw, :trading_detail_fetcher, fn last4 ->
        {:ok, detail_for(last4)}
      end)

      {:ok, view, _html} = live(conn, ~p"/trading")
      html = render_async(view)

      assert html =~ "trading-anomaly-prompt"
      assert html =~ "Was that a transfer?"
      assert html =~ "+$500.00"

      # Answer it: a $500 deposit.
      html =
        view
        |> element("#trading-anomaly-prompt form")
        |> render_submit(%{"kind" => "deposit", "amount" => "500.00"})

      refute html =~ "trading-anomaly-prompt"

      # The gain is now the $0 that was actually earned, while the value stands.
      assert [_yesterday, today] = Portfolio.gain_series("6587")
      assert today.gain_cents == 0
      assert today.value_cents == 50_338
    end

    test "answering 'no, the market' clears the prompt without inventing a transfer",
         %{conn: conn} do
      alias BusterClaw.Portfolio

      {:ok, _} =
        Portfolio.record(
          %{"accounts" => [%{"last4" => "6587", "label" => "Investing", "value" => 3.38}]},
          day: Date.add(BusterClaw.MarketCalendar.today(), -1)
        )

      Application.put_env(:buster_claw, :trading_snapshot_fetcher, fn ->
        snap = multi_account_snapshot()

        accounts =
          Enum.map(snap["accounts"], fn a ->
            if a["last4"] == "6587", do: Map.put(a, "value", 503.38), else: a
          end)

        {:ok, %{snap | "accounts" => accounts}}
      end)

      Application.put_env(:buster_claw, :trading_detail_fetcher, fn last4 ->
        {:ok, detail_for(last4)}
      end)

      {:ok, view, _html} = live(conn, ~p"/trading")
      render_async(view)

      html =
        view
        |> element("#trading-anomaly-prompt form")
        |> render_submit(%{"kind" => "not_a_transfer", "amount" => "500.00"})

      refute html =~ "trading-anomaly-prompt"

      # Nothing was subtracted: the move really was performance.
      assert [_, today] = Portfolio.gain_series("6587")
      assert today.gain_cents == 50_000
    end

    test "the chart renders with a range control, a readout, and a table",
         %{conn: conn} do
      alias BusterClaw.Portfolio

      today = BusterClaw.MarketCalendar.today()

      # Two recorded days plus a realized bucket, so the chart has a seam.
      # Inside the default 1M window on purpose — a bucket further back would be
      # correctly trimmed away and there would be no seam to caption.
      Portfolio.store_backfill("6587", [
        %{bucket_on: Date.add(today, -20), realized: 100.0, trades: 4}
      ])

      for {offset, value} <- [{-1, 3.38}, {0, 4.38}] do
        {:ok, _} =
          Portfolio.record(
            %{"accounts" => [%{"last4" => "6587", "label" => "Investing", "value" => value}]},
            day: Date.add(today, offset)
          )
      end

      stub_trading_fetchers()

      {:ok, view, _html} = live(conn, ~p"/trading")
      html = render_async(view)

      assert html =~ ~s(id="portfolio-chart")
      assert html =~ ~s(phx-hook="PortfolioChart")
      # Range control and the disclosed granularity.
      assert html =~ ~s(phx-value-range="1M")
      assert html =~ ~s(phx-value-range="ALL")
      assert html =~ "points"
      # The seam caption, since a realized stretch is present.
      assert html =~ "realized trades only, before recording began"
      # The keyboard path is advertised in the accessible name.
      assert html =~ "Use arrow keys"

      # The table is behind a toggle and lists the same points the line draws.
      refute html =~ ~s(<table)
      html = render_click(view, "trading_toggle_table", %{})
      assert html =~ ~s(<table)
      assert html =~ "Cumulative"
      assert html =~ Date.to_iso8601(today)

      html = render_click(view, "trading_toggle_table", %{})
      refute html =~ ~s(<table)
    end

    test "a marked transfer is disclosed on the chart, not hidden by the math",
         %{conn: conn} do
      alias BusterClaw.Portfolio

      today = BusterClaw.MarketCalendar.today()

      for {offset, value} <- [{-1, 3.38}, {0, 503.38}] do
        {:ok, _} =
          Portfolio.record(
            %{"accounts" => [%{"last4" => "6587", "label" => "Investing", "value" => value}]},
            day: Date.add(today, offset)
          )
      end

      {:ok, _} =
        Portfolio.put_flow(%{
          account_key: "6587",
          occurred_on: today,
          amount_cents: 50_000,
          kind: "deposit",
          source: "manual"
        })

      stub_trading_fetchers()

      {:ok, view, _html} = live(conn, ~p"/trading")
      render_async(view)
      html = render_click(view, "trading_select_account", %{"id" => "••••6587"})

      # Netting the deposit out of the gain makes it invisible in the LINE, so
      # the readout has to say it happened — otherwise the arithmetic is
      # uncheckable.
      assert html =~ "includes a +$500.00 transfer"

      html = render_click(view, "trading_toggle_table", %{})
      assert html =~ "transfer +$500.00"
    end

    test "the hero's day change agrees with the ledger's two most recent readings",
         %{conn: conn} do
      alias BusterClaw.Portfolio

      # Friday -> Monday, with a $500 Monday deposit that must be netted out.
      for {day, value} <- [{~D[2026-07-24], 100.0}, {~D[2026-07-27], 610.0}] do
        {:ok, _} =
          Portfolio.record(
            %{"accounts" => [%{"last4" => "6587", "label" => "Investing", "value" => value}]},
            day: day
          )
      end

      {:ok, _} =
        Portfolio.put_flow(%{
          account_key: "6587",
          occurred_on: ~D[2026-07-27],
          amount_cents: 50_000,
          kind: "deposit",
          source: "manual"
        })

      {:ok, view, _html} = live(conn, ~p"/trading")
      html = render_async(view)

      # The done-when: the hero shows the ledger's math, not the raw delta.
      assert html =~ "+$10.00 (+10.00%)"
      assert html =~ "today"
      refute html =~ "+$510.00"
    end

    test "a lone reading says day change starts tomorrow — never $0.00", %{conn: conn} do
      alias BusterClaw.Portfolio

      {:ok, _} =
        Portfolio.record(
          %{"accounts" => [%{"last4" => "6587", "label" => "Investing", "value" => 100.0}]},
          day: ~D[2026-07-27]
        )

      {:ok, view, _html} = live(conn, ~p"/trading")
      html = render_async(view)

      assert html =~ "First reading 2026-07-27"
      assert html =~ "day change starts with tomorrow"
    end

    test "a recording gap is labeled by its baseline date, not called 'today'",
         %{conn: conn} do
      alias BusterClaw.Portfolio

      for {day, value} <- [{~D[2026-07-20], 100.0}, {~D[2026-07-27], 110.0}] do
        {:ok, _} =
          Portfolio.record(
            %{"accounts" => [%{"last4" => "6587", "label" => "Investing", "value" => value}]},
            day: day
          )
      end

      {:ok, view, _html} = live(conn, ~p"/trading")
      html = render_async(view)

      assert html =~ "+$10.00"
      assert html =~ "since 2026-07-20"
    end

    test "index chips render from the cached sweep, with an as-of and honest dashes",
         %{conn: conn} do
      BusterClaw.MarketData.store_quotes(%{
        quotes: [],
        indexes: [
          %{
            "symbol" => "SPX",
            "name" => "S&P 500",
            "price" => 7413.18,
            "prev_close" => 7400.0,
            "change_pct" => nil
          },
          %{
            "symbol" => "NDX",
            "name" => "",
            "price" => 28_039.21,
            "prev_close" => nil,
            "change_pct" => nil
          }
        ]
      })

      {:ok, view, _html} = live(conn, ~p"/trading")
      html = render_async(view)

      # HEEx escapes the ampersand.
      assert html =~ "S&amp;P 500"
      assert html =~ "7413.18"
      # Derived from prev_close: our division, two tool-sourced numbers.
      assert html =~ "+0.18%"
      # No prev_close and no given change: a written dash, never a zero.
      assert html =~ "NDX"
      assert html =~ "as of"
    end

    test "positions render from the cache with real unrealized P&L and no fetch",
         %{conn: conn} do
      alias BusterClaw.{MarketData, Portfolio}

      # Everything seeded locally; the default fetcher stubs ERROR, so any
      # attempted agent run would surface as a failed refresh — rendering from
      # cache alone is the done-when.
      Portfolio.store_costs("6587", [
        %{symbol: "GOOGL", quantity: 0.25, lots: 2, cost_basis: 69.99}
      ])

      MarketData.store_bars(%{
        "GOOGL" => [
          %{bar_on: ~D[2026-07-23], close: 310.0},
          %{bar_on: ~D[2026-07-24], close: 319.74}
        ]
      })

      MarketData.store_quotes(%{
        quotes: [
          %{
            "symbol" => "GOOGL",
            "name" => nil,
            "price" => 325.13,
            "prev_close" => 320.0,
            "change_pct" => nil
          }
        ],
        indexes: []
      })

      {:ok, view, _html} = live(conn, ~p"/trading")
      html = render_async(view)

      assert html =~ "Positions"
      assert html =~ "GOOGL"
      assert html =~ "0.25 sh"
      # value = 0.25 × $325.13 quote = $81.28; unrealized = 81.28 − 69.99.
      assert html =~ "$81.28"
      assert html =~ "+$11.29"
      assert html =~ "+16.13%"
      # Day change derived from prev_close, our division.
      assert html =~ "+1.60%"
      # The sparkline drew from cached closes.
      assert html =~ "<polyline"
      assert html =~ "prices as of"
    end

    test "a missing cost basis says so — never $0", %{conn: conn} do
      alias BusterClaw.{MarketData, Portfolio}

      Portfolio.store_costs("8262", [%{symbol: "QXO", quantity: 10.0, lots: 0, cost_basis: nil}])
      MarketData.store_bars(%{"QXO" => [%{bar_on: ~D[2026-07-24], close: 13.67}]})

      {:ok, view, _html} = live(conn, ~p"/trading")
      html = render_async(view)

      assert html =~ "QXO"
      # Value still renders (quantity × latest close)...
      assert html =~ "$136.70"
      # ...but the gain is worded as unavailable, not zeroed.
      assert html =~ "cost basis unavailable"
      refute html =~ "+$136.70"
    end

    test "with no cost rows the panel offers Load, sized to the missing accounts",
         %{conn: conn} do
      stub_trading_fetchers()

      {:ok, view, _html} = live(conn, ~p"/trading")
      html = render_async(view)

      # Stage 1 landed (three accounts, crypto excluded from candidacy), no
      # costs stored -> the not-loaded wording names the two eligible accounts.
      # HEEx wraps between the count interpolation and its noun.
      assert html =~ "Cost basis not loaded for 2"
      assert html =~ ~r/2\s+accounts/
      assert html =~ "one agent run per account"
      assert html =~ ~r/>\s*Load\s*</
    end

    test "Load fetches costs for exactly the missing, eligible accounts", %{conn: conn} do
      alias BusterClaw.Portfolio
      test_pid = self()
      stub_trading_fetchers()

      Application.put_env(:buster_claw, :trading_costs_fetcher, fn last4 ->
        send(test_pid, {:costs_fetched, last4})
        {:ok, [%{symbol: "GOOGL", quantity: 0.25, lots: 1, cost_basis: 69.99}]}
      end)

      on_exit(fn -> Application.put_env(:buster_claw, :trading_costs_fetcher, nil) end)

      # One eligible account already has rows; only the other should be fetched.
      Portfolio.store_costs("6587", [%{symbol: "OKYO", quantity: 1.0, lots: 1, cost_basis: 1.51}])

      {:ok, view, _html} = live(conn, ~p"/trading")
      render_async(view)

      render_click(view, "trading_load_costs", %{})
      html = render_async(view)

      assert_receive {:costs_fetched, "4821"}
      # 6587 already had rows; 9013 is crypto (no tax-lot tool). Neither runs.
      refute_receive {:costs_fetched, "6587"}, 50
      refute_receive {:costs_fetched, "9013"}, 50

      assert html =~ "GOOGL"
    end

    test "clicking a position opens its chart, and Portfolio returns to the line",
         %{conn: conn} do
      alias BusterClaw.{MarketData, Portfolio}

      Portfolio.store_costs("6587", [
        %{symbol: "GOOGL", quantity: 0.25, lots: 1, cost_basis: 69.99}
      ])

      MarketData.store_bars(%{
        "GOOGL" => [
          %{bar_on: ~D[2026-07-23], close: 322.10},
          %{bar_on: ~D[2026-07-24], close: 319.74}
        ]
      })

      {:ok, view, _html} = live(conn, ~p"/trading")
      render_async(view)

      # Open the symbol view: line mode renders from cached closes, no fetch —
      # the default fetcher stubs would error loudly if one were attempted.
      html = render_click(view, "trading_view_symbol", %{"symbol" => "GOOGL"})

      assert html =~ "◀ Portfolio"
      assert html =~ ~r/daily\s*·\s*2 bars/
      assert html =~ "<polyline"
      assert html =~ "not zero-based"
      refute html =~ "Gain / loss"

      # And back (the done-when).
      html = render_click(view, "trading_view_portfolio", %{})
      assert html =~ "Gain / loss"
      refute html =~ "◀ Portfolio"
    end

    test "candles fetch full bars once, then render and cache", %{conn: conn} do
      alias BusterClaw.{MarketData, Portfolio}
      test_pid = self()

      Portfolio.store_costs("6587", [
        %{symbol: "GOOGL", quantity: 0.25, lots: 1, cost_basis: 69.99}
      ])

      MarketData.store_bars(%{"GOOGL" => [%{bar_on: ~D[2026-07-24], close: 319.74}]})

      Application.put_env(:buster_claw, :trading_bars_fetcher, fn symbol, start, interval ->
        send(test_pid, {:bars_fetched, symbol, start, interval})

        # Spanning the requested window edge-to-edge, like a real fetch —
        # coverage is what makes the re-toggle below free, and a fixture
        # narrower than its window would (correctly) fail it.
        {:ok,
         [
           %{
             bar_on: Date.add(start, 2),
             open: 315.0,
             high: 323.0,
             low: 314.0,
             close: 322.10,
             volume: 900
           },
           %{
             bar_on:
               BusterClaw.MarketCalendar.latest_trading_day(BusterClaw.MarketCalendar.today()),
             open: 322.0,
             high: 325.5,
             low: 318.0,
             close: 319.74,
             volume: 1_000
           }
         ]}
      end)

      on_exit(fn -> Application.put_env(:buster_claw, :trading_bars_fetcher, nil) end)

      {:ok, view, _html} = live(conn, ~p"/trading")
      render_async(view)
      render_click(view, "trading_view_symbol", %{"symbol" => "GOOGL"})

      html = render_click(view, "trading_symbol_mode", %{"mode" => "candles"})
      assert html =~ "fetching full bars (one agent run)"

      html = render_async(view)
      assert_receive {:bars_fetched, "GOOGL", _start, "day"}

      # Candles drew: wick lines + body rects inside success/error groups.
      assert html =~ "<rect"
      assert html =~ "text-success"
      refute html =~ "fetching full bars"

      # Toggling away and back re-renders from the cache: no second run.
      render_click(view, "trading_symbol_mode", %{"mode" => "line"})
      render_click(view, "trading_symbol_mode", %{"mode" => "candles"})
      refute_receive {:bars_fetched, _, _, _}, 50
    end

    test "5Y asks for weekly bars and says so", %{conn: conn} do
      alias BusterClaw.Portfolio
      test_pid = self()

      Portfolio.store_costs("6587", [
        %{symbol: "GOOGL", quantity: 0.25, lots: 1, cost_basis: 69.99}
      ])

      Application.put_env(:buster_claw, :trading_bars_fetcher, fn symbol, start, interval ->
        send(test_pid, {:bars_fetched, symbol, start, interval})
        {:ok, []}
      end)

      on_exit(fn -> Application.put_env(:buster_claw, :trading_bars_fetcher, nil) end)

      {:ok, view, _html} = live(conn, ~p"/trading")
      render_async(view)
      render_click(view, "trading_view_symbol", %{"symbol" => "GOOGL"})

      html = render_click(view, "trading_symbol_range", %{"range" => "5Y"})
      render_async(view)

      assert_receive {:bars_fetched, "GOOGL", _start, "week"}
      assert html =~ "weekly"
    end

    test "a stage-1 reading lands in the portfolio ledger", %{conn: conn} do
      stub_trading_fetchers()

      {:ok, view, _html} = live(conn, ~p"/trading")
      render_async(view)

      # One row per account, money in cents, keyed by last4.
      rows = BusterClaw.Portfolio.all_snapshots() |> Enum.sort_by(& &1.account_key)
      assert [roth, agentic, crypto] = rows
      assert agentic.account_key == "6587"
      assert agentic.value_cents == 338
      assert roth.value_cents == 90_000
      assert crypto.value_cents == 1_250

      # And the derived total agrees with the header the panel rendered.
      assert [%{value_cents: 91_588}] = BusterClaw.Portfolio.total_series()
    end

    test "a ledger failure never costs the user the panel", %{conn: conn} do
      # Values a model might plausibly emit but the ledger must refuse.
      Application.put_env(:buster_claw, :trading_snapshot_fetcher, fn ->
        snap = multi_account_snapshot()
        broken = Enum.map(snap["accounts"], &Map.put(&1, "value", "not a number"))
        {:ok, %{snap | "accounts" => broken}}
      end)

      {:ok, view, _html} = live(conn, ~p"/trading")
      html = render_async(view)

      # Nothing was recorded...
      assert BusterClaw.Portfolio.all_snapshots() == []
      # ...and the panel is still fully alive.
      assert html =~ "trading-account-card"
      assert html =~ "Investing"
      assert html =~ "Roth IRA"
    end

    test "selecting an account fetches only that account's holdings", %{conn: conn} do
      test_pid = self()
      stub_trading_fetchers()

      Application.put_env(:buster_claw, :trading_detail_fetcher, fn last4 ->
        send(test_pid, {:detail_requested, last4})
        {:ok, detail_for(last4)}
      end)

      {:ok, view, _html} = live(conn, ~p"/trading")
      render_async(view)

      render_click(view, "trading_select_account", %{"id" => "••••4821"})
      html = render_async(view)

      assert_receive {:detail_requested, "4821"}

      # The Roth's numbers are on screen and it is marked unwritable.
      assert html =~ "$900.00"
      assert html =~ "VTI"
      assert html =~ "Read-only to agent"
      refute html =~ "Orders execute here"
    end

    test "re-selecting an account already loaded costs no second run", %{conn: conn} do
      test_pid = self()
      stub_trading_fetchers()

      Application.put_env(:buster_claw, :trading_detail_fetcher, fn last4 ->
        send(test_pid, {:detail_requested, last4})
        {:ok, detail_for(last4)}
      end)

      {:ok, view, _html} = live(conn, ~p"/trading")
      render_async(view)

      render_click(view, "trading_select_account", %{"id" => "••••6587"})
      render_async(view)
      assert_receive {:detail_requested, "6587"}

      render_click(view, "trading_select_account", %{"id" => "••••4821"})
      render_async(view)
      assert_receive {:detail_requested, "4821"}

      # Back to the first account: its holdings are already merged into the
      # snapshot, so nothing should be fetched again.
      html = render_click(view, "trading_select_account", %{"id" => "••••6587"})

      refute_receive {:detail_requested, "6587"}, 50
      assert html =~ "VOO"
      refute html =~ "Loading holdings…"
    end

    test "a crypto account says holdings are unreadable and is never fetched", %{conn: conn} do
      test_pid = self()
      stub_trading_fetchers()

      Application.put_env(:buster_claw, :trading_detail_fetcher, fn last4 ->
        send(test_pid, {:detail_requested, last4})
        {:ok, %{"positions" => [], "orders" => [], "detail_at" => "2026-07-27T00:00:00Z"}}
      end)

      {:ok, view, _html} = live(conn, ~p"/trading")
      render_async(view)

      html = render_click(view, "trading_select_account", %{"id" => "••••9013"})

      # No tool can answer for crypto, so no run is spent asking.
      refute_receive {:detail_requested, "9013"}, 50

      assert html =~ "Holdings unavailable"
      # The distinction that matters: an empty positions list here is a gap in
      # the tool surface, never a claim about the balance.
      refute html =~ "the account is all cash"
      assert html =~ "$12.50"
    end

    test "a failed holdings fetch reports itself without losing the balances",
         %{conn: conn} do
      Application.put_env(:buster_claw, :trading_snapshot_fetcher, fn ->
        {:ok, multi_account_snapshot()}
      end)

      # The stage-2 default seam already fails; balances must survive it.
      {:ok, view, _html} = live(conn, ~p"/trading")
      render_async(view)

      render_click(view, "trading_select_account", %{"id" => "••••6587"})
      html = render_async(view)

      assert html =~ "Holdings failed to load: detail disabled in test"
      # Stage 1's numbers are untouched by stage 2's failure.
      assert html =~ "$3.38"
      assert html =~ "$915.88"
      assert html =~ "Roth IRA"
    end

    test "retrying a failed holdings fetch re-runs stage 2 alone", %{conn: conn} do
      test_pid = self()

      Application.put_env(:buster_claw, :trading_snapshot_fetcher, fn ->
        send(test_pid, :accounts_requested)
        {:ok, multi_account_snapshot()}
      end)

      {:ok, view, _html} = live(conn, ~p"/trading")
      render_async(view)
      assert_receive :accounts_requested

      render_click(view, "trading_select_account", %{"id" => "••••6587"})
      html = render_async(view)
      assert html =~ "Holdings failed to load"

      # Second attempt succeeds.
      Application.put_env(:buster_claw, :trading_detail_fetcher, fn last4 ->
        {:ok, detail_for(last4)}
      end)

      render_click(view, "trading_retry_detail", %{})
      html = render_async(view)

      assert html =~ "VOO"
      refute html =~ "Holdings failed to load"
      # Stage 1 was not re-run: the balances on screen were never in doubt.
      refute_receive :accounts_requested, 50
    end

    test "a selection that vanishes on refresh falls back instead of blanking", %{conn: conn} do
      stub_trading_fetchers()

      {:ok, view, _html} = live(conn, ~p"/trading")
      render_async(view)
      render_click(view, "trading_select_account", %{"id" => "••••9013"})

      # The next refresh returns a snapshot without the crypto account.
      Application.put_env(:buster_claw, :trading_snapshot_fetcher, fn ->
        snap = multi_account_snapshot()
        accounts = Enum.reject(snap["accounts"], &(&1["id"] == "••••9013"))
        {:ok, %{snap | "accounts" => accounts}}
      end)

      render_click(view, "trading_refresh", %{})
      html = render_async(view)

      # Falls back to the agentic account rather than rendering an empty detail.
      assert html =~ "Orders execute here"
      assert html =~ "$3.38"
      refute html =~ "Holdings unavailable"
    end

    test "a failed refresh keeps the last good snapshot visible", %{conn: conn} do
      good = %{
        "accounts" => [
          %{
            "id" => "••••6587",
            "label" => "Investing",
            "agentic" => true,
            "holdings_supported" => true,
            "value" => 42.0,
            "cash" => 42.0,
            "buying_power" => 42.0,
            "positions" => [],
            "orders" => []
          }
        ],
        "fetched_at" => DateTime.utc_now() |> DateTime.to_iso8601()
      }

      BusterClaw.Trading.store_snapshot(good)

      # Force staleness so entering the tab triggers the (failing) fetcher.
      BusterClaw.Trading.store_snapshot(Map.put(good, "fetched_at", "2020-01-01T00:00:00Z"))

      {:ok, view, _html} = live(conn, ~p"/trading")
      html = render_async(view)

      assert html =~ "Refresh failed: disabled in test"
      assert html =~ "$42.00"
    end
  end

  # Stage 1: three accounts covering the cases the panel has to tell apart —
  # the agentic (writable) one, an ordinary read-only one, and a crypto account
  # whose holdings the Robinhood tool surface cannot read at all. No positions
  # or orders here; that is precisely what stage 1 does not fetch.
  defp multi_account_snapshot do
    %{
      "accounts" => [
        %{
          "id" => "••••6587",
          "last4" => "6587",
          "label" => "Investing",
          "agentic" => true,
          "holdings_supported" => true,
          "value" => 3.38,
          "cash" => 2.38,
          "buying_power" => 2.38
        },
        %{
          "id" => "••••4821",
          "last4" => "4821",
          "label" => "Roth IRA",
          "agentic" => false,
          "holdings_supported" => true,
          "value" => 900.0,
          "cash" => 0.0,
          "buying_power" => 0.0
        },
        %{
          "id" => "••••9013",
          "last4" => "9013",
          "label" => "Crypto",
          "agentic" => false,
          "holdings_supported" => false,
          "value" => 12.5,
          "cash" => 0.0,
          "buying_power" => 0.0
        }
      ],
      "fetched_at" => DateTime.utc_now() |> DateTime.to_iso8601()
    }
  end

  # Stage 2, keyed by the last four the panel asks with.
  defp detail_for("6587") do
    %{
      "positions" => [
        %{"symbol" => "VOO", "quantity" => 0.01, "value" => 1.0},
        %{"symbol" => "AAPL", "quantity" => 0.002, "value" => 0.5}
      ],
      "orders" => [
        %{
          "symbol" => "VOO",
          "side" => "buy",
          "quantity" => 0.01,
          "price" => 100.0,
          "state" => "filled",
          "placed_at" => DateTime.utc_now() |> DateTime.to_iso8601()
        }
      ],
      "detail_at" => DateTime.utc_now() |> DateTime.to_iso8601()
    }
  end

  defp detail_for("4821") do
    %{
      "positions" => [%{"symbol" => "VTI", "quantity" => 3.0, "value" => 900.0}],
      "orders" => [],
      "detail_at" => DateTime.utc_now() |> DateTime.to_iso8601()
    }
  end

  # Wire both stages to the fixtures above.
  defp stub_trading_fetchers do
    Application.put_env(:buster_claw, :trading_snapshot_fetcher, fn ->
      {:ok, multi_account_snapshot()}
    end)

    Application.put_env(:buster_claw, :trading_detail_fetcher, fn last4 ->
      {:ok, detail_for(last4)}
    end)
  end
end
