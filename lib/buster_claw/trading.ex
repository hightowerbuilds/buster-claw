defmodule BusterClaw.Trading do
  @moduledoc """
  Everything that talks to Robinhood through the operator's own agent: the
  pinned trading conversation's profile, and every read the Trading tab's
  dashboard is built from — each one a prompt, a parser, and a test seam.

  The app holds no broker credentials and speaks no MCP — the operator's
  `claude` CLI does both (OAuth tokens live in the macOS Keychain after a
  one-time interactive `claude mcp login robinhood`; headless runs reuse them).
  Robinhood marks one account as Agentic, but this application currently exposes
  only an allowlisted set of read tools. Orders cannot be placed, amended, or
  cancelled from the Trading chat. Every chat send lands a Sentinel
  `:outbound_send` line (see `TradingLive.dispatch_chat/2`).

  ## The reads (each: prompt + parser + `:trading_*_fetcher` seam)

  - **Stage 1** — balances for every account (`fetch_account_snapshot/0`)
  - **Stage 2** — one account's holdings/orders, by last-four
    (`fetch_account_detail/1`)
  - **Costs** — one account's positions with tax-lot cost basis
    (`fetch_costs/1`)
  - **Sweep** — daily closes for held symbols + quotes + indexes + earnings, one
    run per trading day (`fetch_market_data/1`; stored by `BusterClaw.MarketData`)
  - **Chart tier** — full OHLCV for one symbol, bounded window
    (`fetch_symbol_bars/3`)
  - **Backfill** — realized P&L history (`fetch_realized_pnl/1`; stored by
    `BusterClaw.Portfolio`)

  Two rules every parser enforces rather than requests: sensitive shapes are
  normalized app-side (account numbers are masked here no matter what the model
  returns), and payloads stay bounded — every number transits a language model,
  so transcription size is a correctness parameter.

  The Trading page is a strip of typed conversations (`tabs/0`): `robinhood`
  tabs get the reads above, and `chartbuild` tabs get `BusterClaw.ChartBuilder`.
  Chart Build has no broker surface — it gets a bounded snapshot of already-cached
  data, web *search* for discovery, and `ChartBuilder.Fetch` for any public figure
  it needs to plot. (A `research` kind sat between them until 08-03; Chart Build
  absorbed its job and its fetchers.)
  `"trading"` — which used to be DB-less so it could not appear in Home's chat
  strip — is now a real row seeded at that same id, so its existing
  `Agent.Transcript` history carries straight over. `kind` is what keeps it out
  of Home's list now.
  """

  alias BusterClaw.Agent.Conversations
  alias BusterClaw.Agent.StreamEvent
  alias BusterClaw.AgentRunner
  alias BusterClaw.Library.Artifact
  alias BusterClaw.ModelPolicy
  alias BusterClaw.Settings

  @conv_id "trading"
  @tab_kinds ~w(chat robinhood chartbuild)
  @mcp_url "https://agent.robinhood.com/mcp/trading"
  @read_tools ~w(
    mcp__robinhood__get_accounts
    mcp__robinhood__get_earnings_calendar
    mcp__robinhood__get_equity_historicals
    mcp__robinhood__get_equity_orders
    mcp__robinhood__get_equity_positions
    mcp__robinhood__get_equity_quotes
    mcp__robinhood__get_equity_tax_lots
    mcp__robinhood__get_index_quotes
    mcp__robinhood__get_indexes
    mcp__robinhood__get_portfolio
    mcp__robinhood__get_realized_pnl
  )

  # The account panel's cached snapshot (JSON blob in Settings — the
  # browser_tabs precedent). Every refresh is a real agent run, so staleness is
  # tolerated rather than polled away.
  @snapshot_key "trading_account_snapshot"
  @stale_after_min 15

  # Stage 1 — balances for every account, and nothing else. Deliberately does
  # NOT fetch positions or orders: those are ~2 more sequential tool calls per
  # account, and folding them in here is what made the one-shot version take
  # ~105s before a chip ever appeared. Breadth first, depth on demand.
  @accounts_prompt """
  List EVERY brokerage account with its balances. Do NOT fetch positions or
  order history — those are a separate, later request.

  1. Call mcp__robinhood__get_accounts to list all of them.
  2. For EACH account returned, call mcp__robinhood__get_portfolio with that
     account_number.

  Then output ONLY one JSON object — no prose, no code fences:
  {"accounts": [
    {"id": "<the account_number field, exactly as get_accounts returned it>",
     "label": "<the nickname if set, otherwise the brokerage_account_type>",
     "agentic": true or false,
     "holdings_supported": true or false,
     "value": <get_portfolio total_value>,
     "cash": <get_portfolio cash>,
     "buying_power": <get_portfolio buying_power.buying_power>}
  ]}

  Rules:
  - One entry per account from get_accounts. Never merge or omit accounts.
  - Copy each number from the named get_portfolio field. Do NOT substitute
    equity_value for total_value, and do not add pending_deposits to anything —
    total_value already accounts for them.
  - Negative cash and negative buying power are REAL and common (unsettled
    deposits). Report them as negative. Never clamp to zero, round, or tidy a
    number into a cleaner-looking one.
  - Numbers must come from the tool results — never invent them.
  - "agentic": true ONLY if the tool data explicitly marks that account as
    enabled for agentic trading. When the data does not say, use false.
  - "holdings_supported": false for an account whose holdings these tools
    cannot read — there is no crypto positions tool, so a crypto account is
    false. Otherwise true.
  - If the tools are unavailable or unauthenticated, output exactly:
    {"error": "<one-line reason>"}
  """

  @system_prompt """
  You are the operator's Robinhood portfolio assistant.

  Authority — this is the one rule that never bends:
  - You may READ any account using the available get_* tools.
  - You have NO order tool and you never will in this conversation. You cannot
    place, amend, or cancel anything. What you can do is PROPOSE an order, which
    the application shows the operator as a confirmation card. Their click, not
    your message, is what reaches the broker.
  - Never say or imply that you placed, submitted, or cancelled an order. You
    did not. Say "I've put that up for your confirmation."

  Proposing an order:
  - Only propose when the operator has actually asked to trade. Do not attach a
    proposal to a research answer.
  - Before proposing, make sure you know all six of these. Ask for whatever is
    missing — ask in one message, not one question at a time:
      1. buy or sell
      2. the symbol
      3. the size — either a number of shares or a dollar amount, not both
      4. market or limit
      5. the limit price, if it is a limit order
      6. day or gtc (good till cancelled)
    Never guess a missing one, and never default the size or the price.
  - Name the account by the last four digits of its number, from get_accounts.
  - Only ever propose for an account whose get_accounts entry has
    `agentic_allowed: true`. Robinhood refuses orders on any other account, so
    proposing one wastes the operator's confirmation on something that cannot
    work. If they ask for a different account, say plainly that it is not
    agent-enabled and name the ones that are. If more than one is eligible, ask
    which.
  - It is worth quoting the symbol first so your proposal carries a real price.
  - Then end your message with a fenced block, exactly this form:

    ```order
    {"side": "buy", "symbol": "AAPL", "quantity": 2, "order_type": "limit",
     "limit_price": 199.25, "time_in_force": "day", "account_last4": "6587"}
    ```

    Use "amount_usd" instead of "quantity" for a dollar-sized order. Omit
    "limit_price" entirely for a market order. One block per message, and only
    in the message that proposes the trade — never in an explanation of how
    orders work, because the fence is what arms the confirmation card.

  Rules:
  - Use get_portfolio and get_equity_positions for account facts.
  - Treat order history as read-only evidence.
  - Quote real numbers from the quote tools; never invent prices, fills, or P&L.
  - If the Robinhood tools are unavailable or unauthenticated, say so plainly
    and stop — never simulate trading activity.
  """

  def conv_id, do: @conv_id

  @doc """
  The Trading page's open tabs, guaranteeing at least one.

  The first Robinhood tab is seeded at the historical `"trading"` id so the
  transcript written while that conversation was DB-less becomes this tab's
  history instead of being orphaned.
  """
  def tabs do
    _seeded = Conversations.ensure(@conv_id, title: "Robinhood", kind: "robinhood")

    case Conversations.list_kinds(@tab_kinds) do
      [] ->
        {:ok, conv} = Conversations.create(%{title: "Robinhood", kind: "robinhood"})
        [conv]

      tabs ->
        # The seeded tab leads regardless of insertion order. `inserted_at` is
        # second-precision, so a conversation created in the same second as the
        # seed ties and falls back to sorting by id — where "conv-…" beats
        # "trading" and the page would open on someone's Chart Build tab.
        {pinned, rest} = Enum.split_with(tabs, &(&1.id == @conv_id))
        pinned ++ rest
    end
  end

  @doc "The conversation kinds that live on the Trading page, in tab order."
  def tab_kinds, do: @tab_kinds

  # The kind → Claude-profile mapping lives in `BusterClaw.Trading.ChatProfile`,
  # NOT here and not behind a delegate from here. Naming `ChartBuilder` from this
  # module — directly or through a defdelegate — is what closed the
  # `Trading → ChartBuilder → Portfolio → Trading` cycle on 08-03. The dispatcher
  # is a leaf its caller reaches directly; see that module's moduledoc.

  @doc "Human label for a kind, used when titling a new tab."
  def kind_label("chartbuild"), do: "Chart Build"
  def kind_label("chat"), do: "Chat"
  def kind_label(_robinhood), do: "Robinhood"

  @doc "Short badge for a kind, written on tabs and window title bars."
  def kind_badge("chartbuild"), do: "CHART"
  def kind_badge("chat"), do: "CHAT"
  def kind_badge(_robinhood), do: "RH"

  @doc "The stage-1 (balances for every account) prompt. Exposed for tests."
  def accounts_prompt, do: @accounts_prompt

  @doc """
  The stage-2 (one account's holdings and orders) prompt. Exposed for tests.

  The account is identified by the **last four digits** of its number, not by
  the number itself: we mask ids on the way in and never persist the raw
  brokerage number, so stage 2 re-resolves it from `get_accounts` at call time.
  That costs one cheap extra tool call and keeps full account numbers out of
  the Settings cache entirely.
  """
  def detail_prompt(last4) when is_binary(last4) do
    """
    Fetch holdings and recent orders for ONE account: the one whose account
    number ENDS IN #{last4}.

    1. Call mcp__robinhood__get_accounts and find the account whose number ends
       in #{last4}. Output {"error": "account not found"} and stop ONLY if no
       account ends in those digits. If more than one does, output
       {"error": "ambiguous account identity"} and stop.
    2. Call mcp__robinhood__get_equity_positions for that account_number.
    3. Call mcp__robinhood__get_equity_orders for that account_number and keep
       the 10 most recent.

    Then output ONLY one JSON object — no prose, no code fences:
    {"positions": [{"symbol": "<ticker>", "quantity": <number>, "value": <usd number>}],
     "orders": [{"symbol": "<ticker>", "side": "buy" or "sell", "quantity": <number>,
      "price": <usd number or null>, "state": "<order state>",
      "placed_at": "<ISO8601 timestamp or null>"}]}

    Rules:
    - Read only. Never place, amend, or cancel an order.
    - Numbers must come from the tool results — never invent them.
    - An account with no holdings is "positions": [] — never a guess.
    - If the tools are unavailable or unauthenticated, output exactly:
      {"error": "<one-line reason>"}
    """
  end

  @doc """
  Options for `Chat.ensure_started/2`. Captured once at process start (like
  every ensure_started opt) — a config change needs `Chat.stop(conv_id())` to
  take effect on the next turn.

  `--strict-mcp-config` scopes the conversation to exactly this server: no
  other operator-configured MCP tooling leaks into the trading surface.
  """
  def chat_opts do
    [
      append_system_prompt: @system_prompt,
      permission_mode: "dontAsk",
      extra_cli_args: read_only_cli_args()
    ]
  end

  @doc """
  Claude arguments that make the Robinhood surface deny-by-default.

  `dontAsk` is the AgentRunner permission mode; the run is scoped to the
  Robinhood MCP server, the built-in tools are explicitly denied, and only the
  named `get_*` tools are pre-approved. A write tool introduced by Robinhood
  later remains unapproved without a code change here.

  ## Why `--disallowedTools` and not `--tools ""` (2026-07-28)

  This used to pass `--tools ""` to empty the built-in tool set. That silently
  broke every trading read for as long as it existed: `--tools ""` does not just
  drop the built-ins, it takes MCP tools with it. Measured against the operator's
  real account, `--tools ""` produced **0 broker tool calls in 4 runs** across two
  models, and the model filled the silence with invented accounts rather than
  stopping. Dropping it: 1 call in 1 run on the default model.

  `--allowedTools` alone is NOT confinement — it is an approval list, not a deny
  list. Under `dontAsk`, a built-in that is merely absent from it still runs:
  a probe asked for `Bash` with only the Robinhood tool allowed and got a clean
  execution with an empty `permission_denials`. `--disallowedTools` is what
  actually refuses it (same probe, 0 Bash calls), and it leaves MCP intact.

  So all three do distinct work and all three are load-bearing: `--mcp-config`
  scopes which servers exist, `--disallowedTools` refuses the built-ins,
  `--allowedTools` pre-approves the reads.
  """
  def read_only_cli_args do
    [
      "--disallowedTools",
      Enum.join(BusterClaw.AgentToolPolicy.denied_builtins(), ","),
      "--allowedTools",
      Enum.join(@read_tools, ","),
      "--strict-mcp-config",
      "--mcp-config",
      ensure_mcp_config()
    ]
  end

  @doc """
  The built-in tools a trading run is refused. The list itself lives in
  `BusterClaw.AgentToolPolicy` (a leaf — extracted 08-02 to break the
  Trading<->Research cycle); this delegate keeps `TradingOrder`'s call site.
  """
  defdelegate denied_tools, to: BusterClaw.AgentToolPolicy, as: :denied_builtins

  @doc """
  Seed `<workspace>/mcp/robinhood.json` and return its path. Never overwrites
  an existing file — operator edits (extra headers, a different endpoint) win,
  the same contract as `Jobs.seed_agent_settings/0`.
  """
  def ensure_mcp_config do
    path = Artifact.workspace_path(["mcp", "robinhood.json"])
    File.mkdir_p!(Path.dirname(path))
    unless File.exists?(path), do: File.write!(path, default_mcp_config())
    path
  end

  defp default_mcp_config do
    Jason.encode!(
      %{
        "mcpServers" => %{
          "robinhood" => %{"type" => "http", "url" => @mcp_url, "timeout" => 60_000}
        }
      },
      pretty: true
    ) <> "\n"
  end

  # --- Account snapshot (the tab's right-hand panel) ---

  @doc """
  The cached snapshot, `{:ok, map} | :none`.

  Keyed on `"accounts"`, which is also the version check: a snapshot cached by
  the older single-account shape (a bare `"value"` at the top level) fails to
  match and reads as `:none`, so the panel simply refetches into the new shape
  instead of needing a migration.
  """
  def cached_snapshot do
    with raw when is_binary(raw) <- Settings.get(@snapshot_key),
         {:ok, %{"accounts" => [_ | _]} = snap} <- Jason.decode(raw) do
      {:ok, snap}
    else
      _ -> :none
    end
  end

  @doc "True when the snapshot is missing a stamp or older than #{@stale_after_min} minutes."
  def snapshot_stale?(%{"fetched_at" => stamp}) when is_binary(stamp) do
    case DateTime.from_iso8601(stamp) do
      {:ok, at, _} -> DateTime.diff(DateTime.utc_now(), at, :minute) >= @stale_after_min
      _ -> true
    end
  end

  def snapshot_stale?(_snap), do: true

  def store_snapshot(snap), do: Settings.put(@snapshot_key, Jason.encode!(snap))

  # Stage 1 is get_accounts + one get_portfolio per account; stage 2 is
  # get_accounts + positions + orders for a single account. Both are bounded by
  # a small, fixed number of sequential tool calls — unlike the one-shot version
  # they replace, whose cost scaled with account count and blew a 90s cap at
  # three accounts. Caps are generous because being killed mid-flight reports a
  # failure that is really just our own stopwatch.
  @accounts_timeout_ms 180_000
  @detail_timeout_ms 180_000
  # The backfill is three calls like stage 2, but returns years of buckets — the
  # 07-27 probe came back with 31 of them — so it gets the same generous cap.
  @backfill_timeout_ms 180_000
  # The market sweep is the longest run in the app: discovery + a batched
  # historicals call + two quote calls + the largest transcription any prompt
  # asks for (90 close-pairs per held symbol). 240s was measured too small on
  # 07-28 — the run was killed with no output at all, the same our-own-stopwatch
  # failure as the original 90s stage-1 cap. It runs from the daily pump where
  # nobody is watching a spinner, so the cap is set with real headroom.
  @market_data_timeout_ms 480_000
  # Costs: discovery + positions + one tax-lots call per held symbol. Scales
  # with holdings, so it gets stage-2-plus headroom.
  @costs_timeout_ms 240_000
  # Chart tier: one tool call, but up to ~260 six-field rows of transcription —
  # heavier per row than the sweep's pairs. Sized against the sweep's measured
  # 213s with headroom.
  @symbol_bars_timeout_ms 300_000

  @doc """
  Stage 1: fetch balances for every account through the operator's own `claude`,
  on the `:trading_read` model (`run_agent/3` — a floor keeps this off haiku).
  Blocking; callers run it under `start_async`. Test seam:
  `:trading_snapshot_fetcher` app env.
  """
  def fetch_account_snapshot do
    case Application.get_env(:buster_claw, :trading_snapshot_fetcher) do
      fun when is_function(fun, 0) -> fun.()
      nil -> run_agent(@accounts_prompt, @accounts_timeout_ms, &parse_snapshot/1)
    end
  end

  @doc """
  Stage 2: fetch one account's holdings and recent orders, identified by the
  last four digits of its number. Blocking; callers run it under `start_async`.
  Test seam: `:trading_detail_fetcher` app env (an arity-1 function of `last4`).
  """
  def fetch_account_detail(last4) when is_binary(last4) do
    case Application.get_env(:buster_claw, :trading_detail_fetcher) do
      fun when is_function(fun, 1) -> fun.(last4)
      nil -> run_agent(detail_prompt(last4), @detail_timeout_ms, &parse_detail/1)
    end
  end

  @doc """
  The chart-tier fetch (TRADING_TAB_ROADMAP Phase 4): full OHLCV for ONE
  symbol across one bounded window. Blocking; callers run it under
  `start_async`. Test seam: `:trading_bars_fetcher` app env (an arity-3
  function of symbol, start `Date`, and interval `"day" | "week"`).
  """
  def fetch_symbol_bars(symbol, %Date{} = start, interval)
      when is_binary(symbol) and interval in ["day", "week"] do
    case Application.get_env(:buster_claw, :trading_bars_fetcher) do
      fun when is_function(fun, 3) ->
        fun.(symbol, start, interval)

      nil ->
        run_agent(
          symbol_bars_prompt(symbol, start, interval),
          @symbol_bars_timeout_ms,
          &parse_symbol_bars/1
        )
    end
  end

  @doc """
  The chart-tier prompt. Exposed for tests.

  One symbol, one explicit interval, one bounded window — the whole reason the
  chart tier exists apart from the closes sweep is that ~260 six-field rows is
  the most transcription a run is allowed to carry.
  """
  def symbol_bars_prompt(symbol, %Date{} = start, interval) do
    """
    Fetch price history for EXACTLY ONE symbol: #{symbol}.

    Call mcp__robinhood__get_equity_historicals once, with:
    - symbols: ["#{symbol}"]
    - interval: "#{interval}"
    - start_time: "#{Date.to_iso8601(start)}T00:00:00Z"

    Then output ONLY one JSON object — no prose, no code fences:
    {"bars": [["YYYY-MM-DD", <open>, <high>, <low>, <close>, <volume integer or null>], ...]}

    Rules:
    - Read only. Never place, amend, or cancel an order.
    - One array entry per bar the tool returns, OLDEST FIRST, all prices in
      usd, transcribed exactly — never invented, averaged, or resampled to a
      different interval than "#{interval}".
    - Omit bars the tool marks "interpolated": true; they carry no information.
    - If the tools are unavailable, unauthenticated, or the symbol has no data,
      output exactly: {"error": "<one-line reason>"}
    """
  end

  @doc """
  Extract and validate chart-tier bars. Returns `{:ok, [%{bar_on, open, high,
  low, close, volume}]}` oldest first. A row is dropped when its date is
  unparseable, any price is non-positive, or high < low — the one arithmetic
  identity a real bar cannot violate, and therefore the cheapest transcription
  tripwire we have.
  """
  def parse_symbol_bars(output) when is_binary(output) do
    with [json] <- Regex.run(~r/\{.*\}/s, output) || :nomatch,
         {:ok, decoded} <- Jason.decode(json) do
      case decoded do
        %{"error" => msg} ->
          {:error, {:robinhood, to_string(msg)}}

        %{"bars" => bars} when is_list(bars) ->
          {:ok,
           bars
           |> Enum.map(&normalize_ohlc_row/1)
           |> Enum.reject(&is_nil/1)
           |> Enum.sort_by(& &1.bar_on, Date)}

        _other ->
          {:error, :bad_snapshot}
      end
    else
      _ -> {:error, :bad_snapshot}
    end
  end

  defp normalize_ohlc_row([date, open, high, low, close | rest]) do
    with true <- Enum.all?([open, high, low, close], &(is_number(&1) and &1 > 0)),
         true <- high >= low,
         {:ok, parsed} <- Date.from_iso8601(to_string(date)) do
      volume =
        case rest do
          [v | _] when is_integer(v) and v >= 0 -> v
          _ -> nil
        end

      %{bar_on: parsed, open: open, high: high, low: low, close: close, volume: volume}
    else
      _ -> nil
    end
  end

  defp normalize_ohlc_row(_row), do: nil

  @doc """
  The cost-basis fetch (TRADING_TAB_ROADMAP Phase 3): one account's positions
  WITH what was paid for them, from the tax-lot tools. Blocking; callers run it
  under `start_async`. Test seam: `:trading_costs_fetcher` app env (an arity-1
  function of `last4`).
  """
  def fetch_costs(last4) when is_binary(last4) do
    case Application.get_env(:buster_claw, :trading_costs_fetcher) do
      fun when is_function(fun, 1) -> fun.(last4)
      nil -> run_agent(costs_prompt(last4), @costs_timeout_ms, &parse_costs/1)
    end
  end

  @doc """
  The cost-basis prompt. Exposed for tests.

  `cost_basis` must come from the tax-lot tool's own lot figures — never
  quantity × current price, which is the market value wearing the cost's
  clothes and would make every unrealized gain read as zero.
  """
  def costs_prompt(last4) when is_binary(last4) do
    """
    Fetch positions WITH THEIR COST BASIS for ONE account: the one whose
    account number ENDS IN #{last4}.

    1. Call mcp__robinhood__get_accounts and find the account whose number ends
       in #{last4}. Output {"error": "account not found"} and stop ONLY if no
       account ends in those digits. If more than one does, output
       {"error": "ambiguous account identity"} and stop.
    2. Call mcp__robinhood__get_equity_positions for that account_number.
    3. For EACH symbol held, call mcp__robinhood__get_equity_tax_lots for that
       account_number and that symbol, and SUM the open lots' cost basis.

    Then output ONLY one JSON object — no prose, no code fences:
    {"positions": [{"symbol": "<ticker>", "quantity": <number>,
      "lots": <integer>, "cost_basis": <total usd number, or null>}]}

    Rules:
    - Read only. Never place, amend, or cancel an order.
    - "cost_basis" is the sum of the OPEN lots' cost basis from the tax-lot
      tool — NEVER quantity times the current price, and never a guess. If the
      tool cannot provide lots for a symbol, keep the row with
      "cost_basis": null and "lots": 0 rather than dropping or inventing it.
    - An account with no holdings is {"positions": []}.
    - If the tools are unavailable or unauthenticated, output exactly:
      {"error": "<one-line reason>"}
    """
  end

  @doc """
  Extract and validate the cost-basis JSON. Returns `{:ok, [%{symbol, quantity,
  lots, cost_basis}]}` — `cost_basis` nil when the tool couldn't say, which
  callers must render as "unavailable", never as zero.
  """
  def parse_costs(output) when is_binary(output) do
    with [json] <- Regex.run(~r/\{.*\}/s, output) || :nomatch,
         {:ok, decoded} <- Jason.decode(json) do
      case decoded do
        %{"error" => msg} ->
          {:error, {:robinhood, to_string(msg)}}

        %{"positions" => positions} when is_list(positions) ->
          {:ok,
           positions
           |> Enum.filter(&is_map/1)
           |> Enum.map(&normalize_cost_row/1)
           |> Enum.reject(&is_nil/1)}

        _other ->
          {:error, :bad_snapshot}
      end
    else
      _ -> {:error, :bad_snapshot}
    end
  end

  defp normalize_cost_row(row) do
    with symbol when is_binary(symbol) <- row["symbol"],
         true <- valid_symbol?(symbol),
         quantity when is_number(quantity) and quantity > 0 <- row["quantity"] do
      %{
        symbol: symbol,
        quantity: quantity * 1.0,
        lots: if(is_integer(row["lots"]) and row["lots"] >= 0, do: row["lots"], else: 0),
        cost_basis:
          if(is_number(row["cost_basis"]) and row["cost_basis"] >= 0, do: row["cost_basis"])
      }
    else
      _ -> nil
    end
  end

  @doc """
  The market-data sweep (TRADING_TAB_ROADMAP Phase 1): one run that discovers
  the held symbols and returns their daily closes since `start`, current quotes,
  and index quotes. Blocking; the Recorder calls it once per trading day.
  Test seam: `:trading_market_data_fetcher` app env (an arity-1 function of the
  start `Date`).
  """
  def fetch_market_data(%Date{} = start) do
    case Application.get_env(:buster_claw, :trading_market_data_fetcher) do
      fun when is_function(fun, 1) -> fun.(start)
      nil -> run_agent(market_data_prompt(start), @market_data_timeout_ms, &parse_market_data/1)
    end
  end

  @doc """
  The market-data prompt. Exposed for tests.

  Closes travel as compact `[date, close]` pairs — every row transits a
  language model, so payload size is a correctness parameter, and the pair form
  roughly halves the tokens per bar. The historicals call is batched (the tool
  takes up to 10 symbols); anything past 10 is skipped BY NAME rather than
  silently, and interpolated bars are dropped at the source since they carry no
  information.
  """
  def market_data_prompt(%Date{} = start) do
    """
    Collect market data for the operator's holdings, in ONE pass.

    1. Call mcp__robinhood__get_accounts, then mcp__robinhood__get_equity_positions
       for EACH account. Collect the distinct stock symbols held. Skip accounts
       whose positions the tools cannot read.
    2. Call mcp__robinhood__get_equity_historicals ONCE for ALL held symbols (it
       accepts up to 10 per call) with interval "day" and start_time
       "#{Date.to_iso8601(start)}T00:00:00Z". If more than 10 symbols are held,
       fetch the 10 largest positions by value and list the others in "skipped".
    3. Call mcp__robinhood__get_equity_quotes for the same symbols.
    4. Call mcp__robinhood__get_indexes, find the S&P 500 and the Nasdaq
       Composite, and call mcp__robinhood__get_index_quotes for both.
    5. Call mcp__robinhood__get_earnings_calendar once with days: 31, and keep
       ONLY the entries whose symbol is one of the held symbols from step 1.

    Then output ONLY one JSON object — no prose, no code fences:
    {"closes": {"<SYMBOL>": [["YYYY-MM-DD", <close usd number>], ...]},
     "quotes": [{"symbol": "<SYMBOL>", "price": <usd number>,
      "prev_close": <usd number or null>, "change_pct": <percent number or null>}],
     "indexes": [{"symbol": "<index symbol>", "name": "<index name>",
      "price": <number>, "prev_close": <number or null>,
      "change_pct": <percent number or null>}],
     "earnings": [{"symbol": "<SYMBOL>", "date": "YYYY-MM-DD",
      "timing": "am" or "pm" or null}],
     "skipped": ["<SYMBOL>"]}

    Rules:
    - Read only. Never place, amend, or cancel an order.
    - "prev_close" and "change_pct" come from the quote tool's own fields when
      it provides them (previous close / adjusted previous close); null when it
      does not. Never compute them yourself.
    - Closes are DAILY bars as [date, close] pairs, oldest first, transcribed
      exactly from the tool results — never invented, never averaged. Omit bars
      the tool marks "interpolated": true; they carry no information.
    - "earnings" holds only HELD symbols' upcoming reports from the calendar
      tool — an empty list is the correct answer when none report in the
      window. Dates and timing come from the tool, never inferred.
    - If the operator holds no stocks, output "closes": {}, "quotes": [] and
      "earnings": [] but still fill "indexes".
    - If one tool fails, leave its section empty and add a one-line reason to
      an "errors" array; keep the sections that worked.
    - If the tools are entirely unavailable or unauthenticated, output exactly:
      {"error": "<one-line reason>"}
    """
  end

  @doc """
  Extract and validate the market-data JSON. Returns
  `{:ok, %{closes: %{symbol => [%{bar_on: Date, close: number}]}, quotes: [...],
  indexes: [...], skipped: [...], errors: [...]}}`.

  Per-row tolerance, per the ledger's posture: an unparseable pair is dropped
  (with the rest of its symbol kept), a symbol key that isn't a plausible
  ticker is dropped whole, and a non-positive close is refused — a stock cannot
  close at nothing, and a zero would cliff every sparkline that touches it.
  """
  def parse_market_data(output) when is_binary(output) do
    with [json] <- Regex.run(~r/\{.*\}/s, output) || :nomatch,
         {:ok, decoded} <- Jason.decode(json) do
      case decoded do
        %{"error" => msg} ->
          {:error, {:robinhood, to_string(msg)}}

        %{"closes" => closes} when is_map(closes) ->
          {:ok,
           %{
             closes: normalize_closes(closes),
             quotes: normalize_quote_list(decoded["quotes"]),
             indexes: normalize_quote_list(decoded["indexes"]),
             earnings: normalize_earnings(decoded["earnings"]),
             skipped: decoded["skipped"] |> List.wrap() |> Enum.filter(&valid_symbol?/1),
             errors: decoded["errors"] |> List.wrap() |> Enum.filter(&is_binary/1)
           }}

        _other ->
          {:error, :bad_snapshot}
      end
    else
      _ -> {:error, :bad_snapshot}
    end
  end

  @symbol_re ~r/\A[A-Z][A-Z0-9.]{0,9}\z/
  defp valid_symbol?(symbol), do: is_binary(symbol) and Regex.match?(@symbol_re, symbol)

  defp normalize_closes(closes) do
    closes
    |> Enum.filter(fn {symbol, pairs} -> valid_symbol?(symbol) and is_list(pairs) end)
    |> Map.new(fn {symbol, pairs} ->
      bars =
        pairs
        |> Enum.map(&normalize_pair/1)
        |> Enum.reject(&is_nil/1)
        |> Enum.sort_by(& &1.bar_on, Date)

      {symbol, bars}
    end)
    |> Map.reject(fn {_symbol, bars} -> bars == [] end)
  end

  defp normalize_pair([date, close]) when is_binary(date) and is_number(close) and close > 0 do
    case Date.from_iso8601(date) do
      {:ok, parsed} -> %{bar_on: parsed, close: close}
      _error -> nil
    end
  end

  defp normalize_pair(_pair), do: nil

  defp normalize_earnings(list) do
    list
    |> List.wrap()
    |> Enum.filter(&is_map/1)
    |> Enum.map(fn row ->
      with symbol when is_binary(symbol) <- row["symbol"],
           true <- valid_symbol?(symbol),
           {:ok, date} <- Date.from_iso8601(to_string(row["date"] || "")) do
        %{
          "symbol" => symbol,
          "date" => Date.to_iso8601(date),
          "timing" => if(row["timing"] in ["am", "pm"], do: row["timing"])
        }
      else
        _ -> nil
      end
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp normalize_quote_list(list) do
    list
    |> List.wrap()
    |> Enum.filter(&is_map/1)
    |> Enum.map(fn quote_row ->
      %{
        "symbol" => quote_row["symbol"],
        "name" => quote_row["name"],
        "price" => if(is_number(quote_row["price"]), do: quote_row["price"]),
        "prev_close" => if(is_number(quote_row["prev_close"]), do: quote_row["prev_close"]),
        "change_pct" => if(is_number(quote_row["change_pct"]), do: quote_row["change_pct"])
      }
    end)
    |> Enum.filter(&(is_binary(&1["symbol"]) and is_number(&1["price"])))
  end

  @doc """
  The realized-P&L backfill: one account's complete closed-trade history.

  Run on demand, never on a timer — the history it returns barely changes, and
  each call is a real agent run. Test seam: `:trading_backfill_fetcher` app env
  (an arity-1 function of `last4`).
  """
  def fetch_realized_pnl(last4) when is_binary(last4) do
    case Application.get_env(:buster_claw, :trading_backfill_fetcher) do
      fun when is_function(fun, 1) -> fun.(last4)
      nil -> run_agent(backfill_prompt(last4), @backfill_timeout_ms, &parse_backfill/1)
    end
  end

  @doc """
  The backfill prompt. Exposed for tests.

  Asks for the tool's own bucket granularity rather than a daily series. At
  span "all" the API returns monthly buckets (probed 07-27); requesting daily
  would invite the model to invent points between them, and a fabricated
  resolution is worse than a coarse honest one.
  """
  def backfill_prompt(last4) when is_binary(last4) do
    """
    Fetch the complete realized profit & loss history for ONE account: the one
    whose account number ENDS IN #{last4}.

    1. Call mcp__robinhood__get_accounts and find the account whose number ends
       in #{last4}. Output {"error": "account not found"} and stop ONLY if no
       account ends in those digits. If more than one does, output
       {"error": "ambiguous account identity"} and stop.
    2. Call mcp__robinhood__get_realized_pnl for that account_number with
       span "all".

    Then output ONLY one JSON object — no prose, no code fences:
    {"buckets": [{"bucket_on": "<YYYY-MM-DD, the bucket's start date>",
      "realized": <usd number, may be negative, or null>, "trades": <integer>}]}

    Rules:
    - Read only. Never place, amend, or cancel an order.
    - One entry per bucket the tool returns, in the tool's OWN granularity.
      Never split a bucket into finer dates or merge several into one.
    - Numbers must come from the tool result — never invent them. Losing
      buckets are negative and must be reported as such.
    - A bucket the tool reports with no closing trades keeps "trades": 0 and
      "realized": null. Do not substitute 0 for null.
    - If the tools are unavailable or unauthenticated, output exactly:
      {"error": "<one-line reason>"}
    """
  end

  @doc """
  Extract and validate the backfill JSON. Returns `{:ok, [%{bucket_on: Date,
  realized: number | nil, trades: integer}]}`, oldest first.

  Buckets with an unparseable date are dropped rather than failing the fetch;
  a `null` realized figure is preserved as `nil` so the caller can tell "no
  trades that month" from "traded to exactly zero".
  """
  def parse_backfill(output) when is_binary(output) do
    with [json] <- Regex.run(~r/\{.*\}/s, output) || :nomatch,
         {:ok, decoded} <- Jason.decode(json) do
      case decoded do
        %{"error" => msg} ->
          {:error, {:robinhood, to_string(msg)}}

        %{"buckets" => buckets} when is_list(buckets) ->
          {:ok,
           buckets
           |> Enum.filter(&is_map/1)
           |> Enum.map(&normalize_bucket/1)
           |> Enum.reject(&is_nil/1)
           |> Enum.sort_by(& &1.bucket_on, Date)}

        _other ->
          {:error, :bad_snapshot}
      end
    else
      _ -> {:error, :bad_snapshot}
    end
  end

  defp normalize_bucket(bucket) do
    with date when is_binary(date) <- bucket["bucket_on"],
         {:ok, parsed} <- Date.from_iso8601(date) do
      %{
        bucket_on: parsed,
        realized: if(is_number(bucket["realized"]), do: bucket["realized"]),
        trades:
          if(is_integer(bucket["trades"]) and bucket["trades"] >= 0,
            do: bucket["trades"],
            else: 0
          )
      }
    else
      _ -> nil
    end
  end

  defp run_agent(prompt, timeout_ms, parser) do
    opts = [
      extra_args: read_only_cli_args() ++ ~w(--output-format stream-json --verbose),
      # NOT haiku — and since 08-03 a floor enforces that rather than a comment
      # asserting it. Haiku was chosen when these reads were cheap and their
      # failure mode was assumed to be an error; measured on 07-28 it invoked the
      # broker tool in only 1 of 2 runs, and on the miss it invented the answer
      # rather than reporting a problem. A read that silently fabricates half the
      # time is worse than a read that costs more, so `ModelPolicy` gives
      # `:trading_read` a floor the global default cannot lower — only naming
      # this surface explicitly can. `nil` means the operator set nothing and the
      # CLI keeps deciding, exactly as before.
      agent: ModelPolicy.backend_for(:trading_read),
      model: ModelPolicy.for_surface(:trading_read),
      permission_mode: "dontAsk",
      timeout_ms: timeout_ms,
      login: true
    ]

    case agent_runner().(prompt, opts) do
      {:ok, %{exit_status: 0, output: output}} ->
        with {:ok, text} <- verified_result(output), do: parser.(text)

      {:ok, %{exit_status: status}} ->
        {:error, {:agent_exit, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Test seam: `:trading_agent_runner` app env. The per-read `:trading_*_fetcher`
  # seams replace this function wholesale, so they can't show a test what opts it
  # builds — and the model floor above is exactly the thing worth asserting on.
  defp agent_runner,
    do: Application.get_env(:buster_claw, :trading_agent_runner, &AgentRunner.run/2)

  @doc """
  Take a run's final answer, but ONLY if it is backed by a real broker tool call.

  This is the gate that the stage-1 prompt's "if the tools are unavailable,
  output `{"error": ...}`" instruction could never be. On 2026-07-28 a run with
  no working Robinhood connection did not follow that instruction: it invented
  five accounts, four of which do not exist, with plausible balances totalling
  $69,322 against a real $118. `parse_snapshot/1` saw well-formed JSON and cached
  it, and nothing downstream could tell the difference.

  Nothing in a model's *text* can distinguish a real number from an invented one.
  A tool-use event can, so that is what we check: the stream must contain at
  least one `mcp__robinhood__*` call, or the run is refused outright. A model
  that fabricates now fails loudly instead of convincingly.
  """
  def verified_result(output) when is_binary(output) do
    events =
      output
      |> String.split("\n")
      |> Enum.flat_map(fn line ->
        case StreamEvent.parse(line) do
          {:ok, event} -> [event]
          :error -> []
        end
      end)

    if Enum.any?(events, &broker_tool_use?/1),
      do: last_result_text(events),
      else: {:error, :broker_tools_unavailable}
  end

  defp broker_tool_use?(%StreamEvent{kind: :tool_use, tool: tool}) when is_binary(tool),
    do: String.starts_with?(tool, "mcp__robinhood__")

  defp broker_tool_use?(_event), do: false

  defp last_result_text(events) do
    events
    |> Enum.filter(&(&1.kind == :result and is_binary(&1.text)))
    |> List.last()
    |> case do
      nil -> {:error, :no_result}
      %StreamEvent{text: text} -> {:ok, text}
    end
  end

  @doc """
  Extract and validate the stage-1 JSON from an agent's raw output. Stderr is
  merged into stdout by the runner, so tolerate surrounding noise; stamp
  `fetched_at` app-side — the model's clock is never trusted.

  Accounts are normalized individually and a malformed one is dropped rather
  than failing the whole fetch: with several accounts in a single run, one
  unreadable entry must not blank the panel for the rest. A snapshot where no
  account survives is `{:error, :bad_snapshot}`.
  """
  def parse_snapshot(output) when is_binary(output) do
    with [json] <- Regex.run(~r/\{.*\}/s, output) || :nomatch,
         {:ok, decoded} <- Jason.decode(json) do
      case decoded do
        %{"error" => msg} ->
          {:error, {:robinhood, to_string(msg)}}

        %{"accounts" => accounts} when is_list(accounts) ->
          case accounts
               |> Enum.filter(&is_map/1)
               |> Enum.map(&normalize_account/1)
               |> mark_identity_ambiguity()
               |> uniquify() do
            [] ->
              {:error, :bad_snapshot}

            normalized ->
              {:ok,
               %{
                 "accounts" => normalized,
                 "fetched_at" => DateTime.utc_now() |> DateTime.to_iso8601()
               }}
          end

        _other ->
          {:error, :bad_snapshot}
      end
    else
      _ -> {:error, :bad_snapshot}
    end
  end

  # An account keeps whatever the tools returned, with the fields the panel
  # renders forced into known shapes. `holdings_supported` defaults to TRUE on
  # absence: every account the tools can read is the common case, and the flag
  # exists to mark the exception (crypto, which has no positions tool).
  #
  # Positions and orders are deliberately ABSENT here, not empty. Stage 1 never
  # looked for them, and `[]` would claim it did — an account with no holdings
  # and an account whose holdings we haven't requested yet must not render
  # alike. `detail_at` appearing is what makes them real.
  defp normalize_account(account) do
    digits = account_digits(account["id"])

    account
    |> Map.drop(["positions", "orders", "detail_at"])
    |> Map.put("id", mask_account_id(digits))
    |> Map.put("last4", account_last4(digits))
    |> Map.put("label", account_label(account))
    |> Map.put("agentic", account["agentic"] == true)
    |> Map.put("holdings_supported", account["holdings_supported"] != false)
  end

  defp account_digits(id) when is_binary(id) or is_integer(id),
    do: id |> to_string() |> String.replace(~r/[^0-9]/, "")

  defp account_digits(_id), do: ""

  defp account_last4(""), do: nil
  defp account_last4(digits), do: String.slice(digits, -4..-1//1)

  defp account_label(%{"label" => label}) when is_binary(label) do
    case String.trim(label) do
      "" -> "Account"
      trimmed -> trimmed
    end
  end

  defp account_label(_account), do: "Account"

  # Masking is enforced here, not requested in the prompt. The prompt does ask
  # for a masked id, but a model that returns the raw brokerage account number
  # anyway (observed 07-27) would put full account numbers on screen and into
  # the Settings cache. The last four are enough to tell accounts apart, which
  # is the only thing the panel needs them for.
  defp mask_account_id(digits) when is_binary(digits) do
    case String.length(digits) do
      0 -> "account"
      n when n <= 4 -> "••••" <> digits
      _ -> "••••" <> String.slice(digits, -4, 4)
    end
  end

  # The masked id is the panel's selection key, so it has to stay unique even
  # when two accounts share their last four digits (or both mask to "account").
  # Suffix the later duplicates rather than dropping them — an unselectable
  # chip is worse than an ugly one.
  defp uniquify(accounts) do
    {reversed, _seen} =
      Enum.reduce(accounts, {[], %{}}, fn account, {acc, seen} ->
        id = account["id"]

        case Map.get(seen, id, 0) do
          0 -> {[account | acc], Map.put(seen, id, 1)}
          n -> {[Map.put(account, "id", "#{id} (#{n + 1})") | acc], Map.put(seen, id, n + 1)}
        end
      end)

    Enum.reverse(reversed)
  end

  # Last-four digits are only a safe local identity when exactly one account in
  # the broker snapshot carries them. Keep colliding accounts visible in the
  # balance overview, but mark them so every detail and persistence path can
  # fail closed instead of silently selecting or merging the first match.
  defp mark_identity_ambiguity(accounts) do
    frequencies =
      accounts
      |> Enum.map(& &1["last4"])
      |> Enum.reject(&is_nil/1)
      |> Enum.frequencies()

    Enum.map(accounts, fn account ->
      ambiguous? =
        case account["last4"] do
          nil -> false
          last4 -> Map.get(frequencies, last4, 0) > 1
        end

      Map.put(account, "identity_ambiguous", ambiguous?)
    end)
  end

  @doc """
  Extract and validate the stage-2 JSON (one account's holdings and orders).
  Same noise tolerance and app-side stamping as `parse_snapshot/1`.
  """
  def parse_detail(output) when is_binary(output) do
    with [json] <- Regex.run(~r/\{.*\}/s, output) || :nomatch,
         {:ok, decoded} <- Jason.decode(json) do
      case decoded do
        %{"error" => msg} ->
          {:error, {:robinhood, to_string(msg)}}

        %{} = detail ->
          {:ok,
           %{
             "positions" =>
               detail["positions"]
               |> List.wrap()
               |> Enum.map(&normalize_detail_position/1)
               |> Enum.reject(&is_nil/1),
             "orders" =>
               detail["orders"]
               |> List.wrap()
               |> Enum.map(&normalize_detail_order/1)
               |> Enum.reject(&is_nil/1),
             "detail_at" => DateTime.utc_now() |> DateTime.to_iso8601()
           }}

        _other ->
          {:error, :bad_snapshot}
      end
    else
      _ -> {:error, :bad_snapshot}
    end
  end

  defp normalize_detail_position(row) when is_map(row) do
    with symbol when is_binary(symbol) <- row["symbol"],
         true <- valid_symbol?(symbol),
         quantity when is_number(quantity) and quantity > 0 <- row["quantity"],
         value when is_number(value) and value >= 0 <- row["value"] do
      %{"symbol" => symbol, "quantity" => quantity, "value" => value}
    else
      _ -> nil
    end
  end

  defp normalize_detail_position(_row), do: nil

  defp normalize_detail_order(row) when is_map(row) do
    with symbol when is_binary(symbol) <- row["symbol"],
         true <- valid_symbol?(symbol),
         side when side in ["buy", "sell"] <- row["side"],
         quantity when is_number(quantity) and quantity > 0 <- row["quantity"],
         {:ok, price} <- optional_nonnegative_number(row["price"]),
         state when is_binary(state) and state != "" <- row["state"],
         {:ok, placed_at} <- optional_iso8601(row["placed_at"]) do
      %{
        "symbol" => symbol,
        "side" => side,
        "quantity" => quantity,
        "price" => price,
        "state" => state,
        "placed_at" => placed_at
      }
    else
      _ -> nil
    end
  end

  defp normalize_detail_order(_row), do: nil

  defp optional_nonnegative_number(nil), do: {:ok, nil}
  defp optional_nonnegative_number(value) when is_number(value) and value >= 0, do: {:ok, value}
  defp optional_nonnegative_number(_value), do: :error

  defp optional_iso8601(nil), do: {:ok, nil}

  defp optional_iso8601(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, _at, _offset} -> {:ok, value}
      _error -> :error
    end
  end

  defp optional_iso8601(_value), do: :error

  @doc """
  Merge a stage-2 result into the account with `id`. A snapshot that no longer
  contains that account is returned untouched — a detail fetch that lands after
  a refresh dropped its account must not resurrect it.
  """
  def merge_detail(snap, id, detail) do
    updated =
      snap
      |> accounts()
      |> Enum.map(fn account ->
        if account["id"] == id, do: Map.merge(account, detail), else: account
      end)

    Map.put(snap, "accounts", updated)
  end

  @doc "True once an account's holdings have actually been fetched."
  def detail_loaded?(%{"detail_at" => at}) when is_binary(at), do: true
  def detail_loaded?(_account), do: false

  @doc """
  True when an account's holdings are worth fetching: readable at all, and not
  already loaded. Crypto (`holdings_supported: false`) is never worth a run —
  there is no tool that would answer.
  """
  def needs_detail?(%{"holdings_supported" => false}), do: false
  def needs_detail?(%{"identity_ambiguous" => true}), do: false
  def needs_detail?(account) when is_map(account), do: not detail_loaded?(account)
  def needs_detail?(_account), do: false

  @doc """
  The digits stage 2 matches an account on. Stored at normalize time rather
  than re-derived from the displayed id, which carries mask bullets and — for
  accounts that collide on their last four — a disambiguating suffix that would
  poison a digits-only reparse.
  """
  def last4(%{"last4" => last4}) when is_binary(last4), do: last4
  def last4(_account), do: nil

  @doc """
  Collision-safe local key for ledger, flow, exclusion, cost, and backfill data.

  The current Robinhood surface exposes the account number but no separate
  opaque identifier. Until that exists, unique last-four digits are the local
  key. A collision returns nil and every dependent operation fails closed.
  """
  def account_key(%{"identity_ambiguous" => true}), do: nil
  def account_key(account), do: last4(account)

  @doc "The snapshot's accounts, or `[]`."
  def accounts(%{"accounts" => accounts}) when is_list(accounts),
    do: mark_identity_ambiguity(accounts)

  def accounts(_snap), do: []

  @doc """
  Combined value across every account in the snapshot. Accounts whose value
  isn't a number contribute nothing rather than poisoning the total.
  """
  def total_value(snap) do
    snap
    |> accounts()
    |> Enum.map(& &1["value"])
    |> Enum.filter(&is_number/1)
    |> Enum.sum()
  end

  @doc """
  The account to show first: the one selected by `id` if it's still present,
  else the agentic account, else the largest by value. Returns `nil` for an
  empty snapshot.
  """
  def select_account(snap, id) do
    accounts = accounts(snap)

    Enum.find(accounts, &(&1["id"] == id)) ||
      Enum.find(accounts, & &1["agentic"]) ||
      Enum.max_by(accounts, &account_value/1, fn -> nil end)
  end

  defp account_value(%{"value" => v}) when is_number(v), do: v
  defp account_value(_account), do: 0
end
