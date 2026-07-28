defmodule BusterClaw.TradingTest do
  # async: false — points the global :workspace_root at a tmp dir. DataCase for
  # the Settings-backed snapshot cache.
  use BusterClaw.DataCase, async: false

  alias BusterClaw.Trading

  setup do
    root = Path.join(System.tmp_dir!(), "bc_trading_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)

    prev = Application.get_env(:buster_claw, :workspace_root)
    Application.put_env(:buster_claw, :workspace_root, root)

    on_exit(fn ->
      Application.put_env(:buster_claw, :workspace_root, prev)
      File.rm_rf(root)
    end)

    {:ok, root: root}
  end

  test "seeds the Robinhood MCP config once and never overwrites operator edits", %{root: root} do
    path = Trading.ensure_mcp_config()
    assert path == Path.join([root, "mcp", "robinhood.json"])

    config = path |> File.read!() |> Jason.decode!()
    server = config["mcpServers"]["robinhood"]
    assert server["type"] == "http"
    assert server["url"] == "https://agent.robinhood.com/mcp/trading"

    # Operator edits win: a second call must not clobber the file.
    File.write!(path, ~s({"mcpServers": {"robinhood": {"custom": true}}}\n))
    assert Trading.ensure_mcp_config() == path
    assert File.read!(path) =~ "custom"
  end

  test "chat_opts scope the conversation to exactly the seeded server" do
    opts = Trading.chat_opts()
    extra = Keyword.fetch!(opts, :extra_cli_args)

    assert "--strict-mcp-config" in extra
    assert "--mcp-config" in extra
    assert Enum.any?(extra, &String.ends_with?(&1, "mcp/robinhood.json"))
  end

  test "the system prompt carries the money-truthfulness rules" do
    prompt = Keyword.fetch!(Trading.chat_opts(), :append_system_prompt)

    assert prompt =~ "get_equity_positions"
    assert prompt =~ "never invent prices"
    assert prompt =~ "never simulate"
  end

  test "the system prompt confines orders to the agentic account while reads roam" do
    prompt = Keyword.fetch!(Trading.chat_opts(), :append_system_prompt)

    assert prompt =~ "You may READ any account"
    assert prompt =~ "ONLY on the dedicated Agentic"
    assert prompt =~ "READ-ONLY to you"
    # Naming the other account types matters: the rule has to bind the exact
    # accounts the panel now puts in front of the model.
    assert prompt =~ "Roth IRA"
    assert prompt =~ "Crypto"
  end

  test "stage 1 asks for every account's balances and nothing deeper" do
    prompt = Trading.accounts_prompt()

    assert prompt =~ "get_accounts"
    assert prompt =~ "For EACH account"
    assert prompt =~ "Never merge or omit accounts"
    # The crypto gap is instructed, not left to chance.
    assert prompt =~ "no crypto positions tool"
    # The whole point of the split: stage 1 must not pull holdings.
    assert prompt =~ "Do NOT fetch positions or"
  end

  test "stage 2 identifies its account by last four and stays read-only" do
    prompt = Trading.detail_prompt("6587")

    assert prompt =~ "ENDS IN 6587"
    assert prompt =~ "get_equity_positions"
    assert prompt =~ "get_equity_orders"
    # A read surface must say so: this prompt runs against accounts the agent
    # is otherwise forbidden to touch.
    assert prompt =~ "Read only. Never place, amend, or cancel"
  end

  describe "parse_snapshot/1" do
    test "accepts a multi-account payload and stamps fetched_at app-side" do
      out = ~s({"accounts": [
        {"id": "801666587", "label": "Investing", "agentic": true,
         "value": 100.5, "cash": 50.0, "buying_power": 50.0},
        {"id": "515464821", "label": "Roth IRA", "value": 900.0, "cash": 0.0,
         "buying_power": 0.0}
      ]})

      assert {:ok, snap} = Trading.parse_snapshot(out)
      assert [investing, roth] = snap["accounts"]

      assert investing["label"] == "Investing"
      assert investing["agentic"]

      assert roth["label"] == "Roth IRA"
      # Absent `agentic` is false, never nil — the badge is a safety claim and
      # must not be decided by a missing key.
      refute roth["agentic"]

      assert {:ok, _at, _} = DateTime.from_iso8601(snap["fetched_at"])
    end

    test "stage 1 leaves holdings ABSENT rather than empty" do
      out = ~s({"accounts": [
        {"id": "801666587", "label": "Investing", "value": 1.0, "cash": 1.0,
         "buying_power": 1.0}
      ]})

      assert {:ok, %{"accounts" => [acct]}} = Trading.parse_snapshot(out)

      # `[]` would claim stage 1 looked and found nothing. It never looked.
      refute Map.has_key?(acct, "positions")
      refute Map.has_key?(acct, "orders")
      refute Trading.detail_loaded?(acct)
      assert Trading.needs_detail?(acct)
    end

    test "holdings a model volunteers in stage 1 are discarded, not trusted" do
      # The prompt says not to fetch them; if one arrives anyway it has no
      # detail_at stamp behind it, so it is not a real read.
      out = ~s({"accounts": [
        {"id": "801666587", "label": "Investing", "value": 1.0, "cash": 1.0,
         "buying_power": 1.0,
         "positions": [{"symbol": "GME", "quantity": 999, "value": 99999}]}
      ]})

      assert {:ok, %{"accounts" => [acct]}} = Trading.parse_snapshot(out)
      refute Map.has_key?(acct, "positions")
    end

    test "holdings_supported defaults true and survives an explicit false" do
      out = ~s({"accounts": [
        {"id": "111111111", "label": "Investing", "value": 1.0, "cash": 1.0, "buying_power": 1.0},
        {"id": "222222222", "label": "Crypto", "value": 2.0, "cash": 0.0, "buying_power": 0.0,
         "holdings_supported": false}
      ]})

      assert {:ok, %{"accounts" => [investing, crypto]}} = Trading.parse_snapshot(out)
      assert investing["holdings_supported"]
      refute crypto["holdings_supported"]
    end

    test "a raw account number is masked app-side even though the prompt asked nicely" do
      # Observed 07-27: the model returns the unmasked brokerage number. Only
      # the last four survive, and they must never reach the cache in full.
      out = ~s({"accounts": [
        {"id": "801666587", "label": "Agentic", "value": 1.0, "cash": 1.0, "buying_power": 1.0}
      ]})

      assert {:ok, %{"accounts" => [acct]}} = Trading.parse_snapshot(out)
      assert acct["id"] == "••••6587"
      refute acct["id"] =~ "801666587"
    end

    test "an already-masked id, a short id, and a junk id all stay safe" do
      out = ~s({"accounts": [
        {"id": "8016****6587", "label": "A", "value": 1.0, "cash": 0.0, "buying_power": 0.0},
        {"id": "42", "label": "B", "value": 1.0, "cash": 0.0, "buying_power": 0.0},
        {"id": null, "label": "C", "value": 1.0, "cash": 0.0, "buying_power": 0.0}
      ]})

      assert {:ok, %{"accounts" => [a, b, c]}} = Trading.parse_snapshot(out)
      assert a["id"] == "••••6587"
      assert b["id"] == "••••42"
      assert c["id"] == "account"
    end

    test "accounts sharing their last four still get distinct selection keys" do
      out = ~s({"accounts": [
        {"id": "111116587", "label": "Investing", "value": 1.0, "cash": 0.0, "buying_power": 0.0},
        {"id": "999996587", "label": "Roth IRA", "value": 2.0, "cash": 0.0, "buying_power": 0.0}
      ]})

      assert {:ok, %{"accounts" => [first, second]}} = Trading.parse_snapshot(out)
      assert first["id"] == "••••6587"
      assert second["id"] != first["id"]

      # Both remain reachable — a duplicate key would strand one chip.
      assert Trading.select_account(%{"accounts" => [first, second]}, second["id"])["label"] ==
               "Roth IRA"
    end

    test "tolerates prose/stderr noise around the JSON" do
      out = """
      some warning on stderr
      {"accounts": [{"id": "801666587", "label": "Investing", "value": 100.5,
       "cash": 50.0, "buying_power": 50.0}]}
      trailing chatter
      """

      assert {:ok, %{"accounts" => [acct]}} = Trading.parse_snapshot(out)
      assert acct["label"] == "Investing"
      assert acct["value"] == 100.5
    end

    test "one malformed account is dropped rather than blanking the others" do
      out = ~s({"accounts": [
        "not an account",
        {"id": "515468262", "label": "Roth IRA", "value": 900.0, "cash": 0.0, "buying_power": 0.0}
      ]})

      assert {:ok, %{"accounts" => [acct]}} = Trading.parse_snapshot(out)
      assert acct["label"] == "Roth IRA"
    end

    test "a reported tool failure surfaces as a robinhood error" do
      assert {:error, {:robinhood, msg}} =
               Trading.parse_snapshot(~s({"error": "not authenticated"}))

      assert msg =~ "authenticated"
    end

    test "garbage, empty, and legacy single-account payloads are rejected" do
      assert {:error, :bad_snapshot} = Trading.parse_snapshot("no json here at all")
      assert {:error, :bad_snapshot} = Trading.parse_snapshot(~s({"accounts": []}))
      assert {:error, :bad_snapshot} = Trading.parse_snapshot(~s({"accounts": ["junk"]}))

      # The pre-multi-account shape is not silently half-accepted.
      assert {:error, :bad_snapshot} =
               Trading.parse_snapshot(
                 ~s({"account": "••••6587", "value": 2.38, "cash": 2.38, "buying_power": 2.38})
               )
    end
  end

  describe "parse_symbol_bars/1" do
    test "parses OHLCV rows oldest first, volume optional" do
      out = ~s({"bars": [
        ["2026-07-24", 322.0, 325.5, 318.0, 319.74, 1000000],
        ["2026-07-23", 315.0, 323.0, 314.0, 322.1, null]
      ]})

      assert {:ok, [a, b]} = Trading.parse_symbol_bars(out)
      assert a.bar_on == ~D[2026-07-23]
      assert a.volume == nil
      assert b.close == 319.74
      assert b.volume == 1_000_000
    end

    test "high < low is a transcription tripwire — the row is dropped" do
      out = ~s({"bars": [
        ["2026-07-24", 322.0, 318.0, 325.5, 319.74, 1],
        ["2026-07-23", 315.0, 323.0, 314.0, 322.1, 1]
      ]})

      assert {:ok, [only]} = Trading.parse_symbol_bars(out)
      assert only.bar_on == ~D[2026-07-23]
    end

    test "non-positive prices and bad dates cost their rows" do
      out = ~s({"bars": [
        ["2026-07-24", 0, 325.5, 318.0, 319.74, 1],
        ["not a date", 315.0, 323.0, 314.0, 322.1, 1],
        ["2026-07-22", 315.0, 323.0, 314.0, 322.1, 1]
      ]})

      assert {:ok, [only]} = Trading.parse_symbol_bars(out)
      assert only.bar_on == ~D[2026-07-22]
    end

    test "errors pass through; the prompt is one symbol, one explicit interval" do
      assert {:error, {:robinhood, _}} = Trading.parse_symbol_bars(~s({"error": "no data"}))

      prompt = Trading.symbol_bars_prompt("GOOGL", ~D[2025-07-28], "week")
      assert prompt =~ ~s(EXACTLY ONE symbol: GOOGL)
      assert prompt =~ ~s(interval: "week")
      assert prompt =~ "2025-07-28T00:00:00Z"
      assert prompt =~ "OLDEST FIRST"
      assert prompt =~ ~s("interpolated": true)
      assert prompt =~ "Read only"
    end
  end

  describe "parse_costs/1" do
    test "parses rows, keeping a null basis as nil — never zero" do
      out = ~s({"positions": [
        {"symbol": "GOOGL", "quantity": 0.2014, "lots": 2, "cost_basis": 69.99},
        {"symbol": "QXO", "quantity": 10, "lots": 4, "cost_basis": null}
      ]})

      assert {:ok, [googl, qxo]} = Trading.parse_costs(out)
      assert googl.cost_basis == 69.99
      assert googl.lots == 2
      assert qxo.cost_basis == nil
      assert qxo.quantity == 10.0
    end

    test "bad rows cost themselves, not the fetch" do
      out = ~s({"positions": [
        {"symbol": "not a ticker", "quantity": 1, "cost_basis": 1.0},
        {"symbol": "GOOGL", "quantity": 0, "cost_basis": 1.0},
        {"symbol": "QXO", "quantity": 10, "lots": 4, "cost_basis": 142.0}
      ]})

      assert {:ok, [only]} = Trading.parse_costs(out)
      assert only.symbol == "QXO"
    end

    test "a negative basis is refused into nil, and errors pass through" do
      out = ~s({"positions": [{"symbol": "QXO", "quantity": 1, "cost_basis": -5.0}]})
      assert {:ok, [row]} = Trading.parse_costs(out)
      assert row.cost_basis == nil

      assert {:error, {:robinhood, _}} = Trading.parse_costs(~s({"error": "down"}))
      assert {:error, :bad_snapshot} = Trading.parse_costs("junk")
    end

    test "the prompt demands lot-sourced basis and stays read-only" do
      prompt = Trading.costs_prompt("6587")

      assert prompt =~ "ENDS IN 6587"
      assert prompt =~ "get_equity_tax_lots"
      assert prompt =~ "SUM the open lots"
      # The one wrong answer named explicitly: market value in cost clothing.
      assert prompt =~ "NEVER quantity times the current price"
      assert prompt =~ ~s("cost_basis": null)
      assert prompt =~ "Read only. Never place, amend, or cancel"
    end
  end

  describe "parse_market_data/1" do
    test "parses compact pairs into dated closes, oldest first" do
      out = ~s({"closes": {"GOOGL": [["2026-07-27", 349.0], ["2026-07-24", 347.52]],
        "QXO": [["2026-07-24", 14.26]]},
        "quotes": [{"symbol": "GOOGL", "price": 349.1, "change_pct": 0.4}],
        "indexes": [{"symbol": "SPX", "name": "S&P 500", "price": 6100.0, "change_pct": -0.2}],
        "skipped": []})

      assert {:ok, parsed} = Trading.parse_market_data(out)
      assert [a, b] = parsed.closes["GOOGL"]
      assert a.bar_on == ~D[2026-07-24]
      assert b.close == 349.0
      assert [%{"symbol" => "GOOGL", "price" => 349.1}] = parsed.quotes
      assert [%{"symbol" => "SPX", "name" => "S&P 500"}] = parsed.indexes
    end

    test "a bad pair costs the pair; a bad symbol key costs the symbol" do
      out = ~s({"closes": {
        "GOOGL": [["not a date", 1.0], ["2026-07-24", 347.52], ["2026-07-25", 0]],
        "not a ticker": [["2026-07-24", 1.0]],
        "EMPTY": []
      }})

      assert {:ok, parsed} = Trading.parse_market_data(out)
      # The unparseable date and the zero close are dropped; the real bar stays.
      assert [%{close: 347.52}] = parsed.closes["GOOGL"]
      refute Map.has_key?(parsed.closes, "not a ticker")
      # A symbol with nothing left is dropped whole rather than kept empty.
      refute Map.has_key?(parsed.closes, "EMPTY")
    end

    test "quotes missing a numeric price are dropped, not zeroed" do
      out = ~s({"closes": {}, "quotes": [
        {"symbol": "GOOGL", "price": "unavailable", "change_pct": null},
        {"symbol": "QXO", "price": 14.26, "change_pct": null}
      ]})

      assert {:ok, %{quotes: [only]}} = Trading.parse_market_data(out)
      assert only["symbol"] == "QXO"
      assert only["change_pct"] == nil
    end

    test "earnings ride the sweep: held symbols only, dates validated, timing whitelisted" do
      out = ~s({"closes": {}, "earnings": [
        {"symbol": "GOOGL", "date": "2026-07-31", "timing": "pm"},
        {"symbol": "QXO", "date": "2026-08-05", "timing": "sometime"},
        {"symbol": "not a ticker", "date": "2026-08-01", "timing": "am"},
        {"symbol": "VOO", "date": "not a date", "timing": "am"}
      ]})

      assert {:ok, %{earnings: [googl, qxo]}} = Trading.parse_market_data(out)
      assert googl == %{"symbol" => "GOOGL", "date" => "2026-07-31", "timing" => "pm"}
      # An unknown timing word degrades to nil rather than surviving as prose.
      assert qxo["timing"] == nil
    end

    test "the sweep prompt filters the market-wide calendar to held symbols" do
      prompt = Trading.market_data_prompt(~D[2026-04-29])

      assert prompt =~ "get_earnings_calendar once with days: 31"
      assert prompt =~ "ONLY the entries whose symbol is one of the held symbols"
      assert prompt =~ "an empty list is the correct answer"
    end

    test "prev_close rides along when the tool provides it — day change is computed app-side" do
      # The 07-28 live sweep returned change_pct: null for both indexes; the
      # tool doesn't hand it over. Two tool-sourced numbers and our own division
      # beat trusting the model with arithmetic.
      out = ~s({"closes": {}, "indexes": [
        {"symbol": "SPX", "name": "S&P 500", "price": 7413.18, "prev_close": 7400.0,
         "change_pct": null}
      ]})

      assert {:ok, %{indexes: [spx]}} = Trading.parse_market_data(out)
      assert spx["prev_close"] == 7400.0
      assert spx["change_pct"] == nil
    end

    test "partial failure carries its errors alongside the good sections" do
      out = ~s({"closes": {"GOOGL": [["2026-07-24", 347.52]]}, "quotes": [],
        "indexes": [], "errors": ["index quotes failed"]})

      assert {:ok, parsed} = Trading.parse_market_data(out)
      assert parsed.errors == ["index quotes failed"]
      assert map_size(parsed.closes) == 1
    end

    test "errors and garbage stay distinguishable" do
      assert {:error, {:robinhood, _}} =
               Trading.parse_market_data(~s({"error": "not authenticated"}))

      assert {:error, :bad_snapshot} = Trading.parse_market_data("no json")
    end

    test "the prompt batches, bounds, and stays read-only" do
      prompt = Trading.market_data_prompt(~D[2026-04-29])

      assert prompt =~ "ONCE for ALL held symbols"
      assert prompt =~ "2026-04-29T00:00:00Z"
      assert prompt =~ "[date, close] pairs"
      assert prompt =~ ~s("interpolated": true)
      assert prompt =~ "list the others in \"skipped\""
      assert prompt =~ "Read only. Never place, amend, or cancel"
    end
  end

  describe "parse_detail/1 and merge_detail/3" do
    setup do
      {:ok, snap} =
        Trading.parse_snapshot(~s({"accounts": [
          {"id": "801666587", "label": "Investing", "agentic": true, "value": 100.0,
           "cash": 1.0, "buying_power": 1.0},
          {"id": "515464821", "label": "Roth IRA", "value": 900.0, "cash": 0.0,
           "buying_power": 0.0}
        ]}))

      {:ok, snap: snap}
    end

    test "a stage-2 payload is stamped and normalized" do
      out = ~s({"positions": [{"symbol": "VOO", "quantity": 0.1, "value": 50.5}],
                "orders": [{"symbol": "VOO", "side": "buy", "quantity": 0.1,
                 "price": 500.0, "state": "filled", "placed_at": null}]})

      assert {:ok, detail} = Trading.parse_detail(out)
      assert [%{"symbol" => "VOO"}] = detail["positions"]
      assert [%{"side" => "buy"}] = detail["orders"]
      assert {:ok, _at, _} = DateTime.from_iso8601(detail["detail_at"])
    end

    test "an account with genuinely nothing still counts as read" do
      assert {:ok, detail} = Trading.parse_detail(~s({"positions": [], "orders": []}))
      assert detail["positions"] == []
      # The stamp is what separates "read it, found nothing" from "never asked".
      assert is_binary(detail["detail_at"])
    end

    test "a reported failure and garbage stay distinguishable" do
      assert {:error, {:robinhood, msg}} =
               Trading.parse_detail(~s({"error": "account not found"}))

      assert msg =~ "not found"
      assert {:error, :bad_snapshot} = Trading.parse_detail("no json at all")
    end

    test "merging fills exactly one account and marks it loaded", %{snap: snap} do
      {:ok, detail} = Trading.parse_detail(~s({"positions": [{"symbol": "VOO"}], "orders": []}))

      merged = Trading.merge_detail(snap, "••••6587", detail)
      [investing, roth] = Trading.accounts(merged)

      assert Trading.detail_loaded?(investing)
      assert [%{"symbol" => "VOO"}] = investing["positions"]

      # The sibling is untouched and still wants its own fetch.
      refute Trading.detail_loaded?(roth)
      assert Trading.needs_detail?(roth)
    end

    test "a detail landing for an account that no longer exists is dropped", %{snap: snap} do
      {:ok, detail} = Trading.parse_detail(~s({"positions": [{"symbol": "GME"}], "orders": []}))

      merged = Trading.merge_detail(snap, "••••0000", detail)

      # Nothing resurrected, nothing corrupted.
      assert length(Trading.accounts(merged)) == 2
      refute Enum.any?(Trading.accounts(merged), &Trading.detail_loaded?/1)
    end

    test "an unreadable account is never worth a stage-2 run" do
      {:ok, %{"accounts" => [crypto]}} =
        Trading.parse_snapshot(~s({"accounts": [
          {"id": "999999013", "label": "Crypto", "value": 12.5, "cash": 0.0,
           "buying_power": 0.0, "holdings_supported": false}
        ]}))

      refute Trading.needs_detail?(crypto)
    end

    test "last4 comes from the stored field, not the display id" do
      {:ok, %{"accounts" => [a, b]}} =
        Trading.parse_snapshot(~s({"accounts": [
          {"id": "111116587", "label": "A", "value": 1.0, "cash": 0.0, "buying_power": 0.0},
          {"id": "999996587", "label": "B", "value": 1.0, "cash": 0.0, "buying_power": 0.0}
        ]}))

      # Both really do end in 6587; the dedupe suffix on B's display id must not
      # leak into the digits stage 2 matches on.
      assert Trading.last4(a) == "6587"
      assert Trading.last4(b) == "6587"
      assert b["id"] != a["id"]
    end
  end

  describe "total_value/1 and select_account/2" do
    setup do
      {:ok, snap} =
        Trading.parse_snapshot(~s({"accounts": [
          {"id": "111111111", "label": "Investing", "value": 100.0, "cash": 0.0,
           "buying_power": 0.0},
          {"id": "222222222", "label": "Roth IRA", "agentic": true, "value": 25.0, "cash": 0.0,
           "buying_power": 0.0},
          {"id": "333333333", "label": "Crypto", "value": "unknown", "cash": 0.0,
           "buying_power": 0.0}
        ]}))

      {:ok, snap: snap}
    end

    test "total skips accounts whose value isn't a number", %{snap: snap} do
      assert Trading.total_value(snap) == 125.0
    end

    test "an explicit selection wins", %{snap: snap} do
      assert Trading.select_account(snap, "••••1111")["label"] == "Investing"
    end

    test "no selection falls back to the agentic account", %{snap: snap} do
      assert Trading.select_account(snap, nil)["label"] == "Roth IRA"
    end

    test "a stale selection falls back rather than pointing at nothing", %{snap: snap} do
      assert Trading.select_account(snap, "deleted-account")["label"] == "Roth IRA"
    end

    test "with no agentic account the largest wins" do
      {:ok, snap} =
        Trading.parse_snapshot(~s({"accounts": [
          {"id": "111111111", "label": "Small", "value": 1.0, "cash": 0.0, "buying_power": 0.0},
          {"id": "222222222", "label": "Big", "value": 900.0, "cash": 0.0, "buying_power": 0.0}
        ]}))

      assert Trading.select_account(snap, nil)["label"] == "Big"
      assert Trading.total_value(%{}) == 0
      assert Trading.select_account(%{"accounts" => []}, nil) == nil
    end
  end

  test "snapshot cache round-trips through Settings and knows staleness" do
    assert Trading.cached_snapshot() == :none

    {:ok, snap} =
      Trading.parse_snapshot(
        ~s({"accounts": [{"id": "••••6587", "label": "Investing", "value": 2.38,
            "cash": 2.38, "buying_power": 2.38, "positions": []}]})
      )

    Trading.store_snapshot(snap)
    assert {:ok, cached} = Trading.cached_snapshot()
    assert [%{"label" => "Investing"}] = cached["accounts"]
    refute Trading.snapshot_stale?(cached)

    old = Map.put(cached, "fetched_at", "2020-01-01T00:00:00Z")
    assert Trading.snapshot_stale?(old)
    assert Trading.snapshot_stale?(%{})
  end

  test "a snapshot cached in the old single-account shape reads as absent" do
    BusterClaw.Settings.put(
      "trading_account_snapshot",
      ~s({"account": "••••6587", "value": 2.38, "cash": 2.38, "buying_power": 2.38,
          "fetched_at": "2026-07-27T00:00:00Z"})
    )

    # Not an error and not half-rendered: the panel just refetches into the new
    # shape on the next open.
    assert Trading.cached_snapshot() == :none
  end
end
