defmodule BusterClaw.Trading do
  @moduledoc """
  The Trading home sub-tab's conversation profile: Robinhood's agentic-trading
  MCP server, attached to a dedicated pinned chat conversation.

  Deliberately thin. The app holds no broker credentials and speaks no MCP —
  the operator's own `claude` CLI does both (OAuth tokens live in the macOS
  Keychain after a one-time interactive `claude mcp login robinhood`; headless
  runs reuse them). Robinhood-side, orders execute on the dedicated Agentic
  account — the primary account is read-only to agents. The app's contribution
  is the surface, the pinned system prompt, and the Sentinel audit line on
  every send (see `StatusLive.dispatch_chat/2`).

  The conversation is DB-less on purpose: `"trading"` never gets a
  `Conversations` row, so it can't appear in (or be closed from) the Chat
  tab's strip, while the transcript still persists via `Agent.Transcript`.
  """

  alias BusterClaw.AgentRunner
  alias BusterClaw.Library.Artifact
  alias BusterClaw.Settings

  @conv_id "trading"
  @mcp_url "https://agent.robinhood.com/mcp/trading"

  # The account panel's cached snapshot (JSON blob in Settings — the
  # browser_tabs precedent). Every refresh is a real (cheap, haiku) agent run,
  # so staleness is tolerated rather than polled away.
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
    {"id": "<the account number>",
     "label": "<human name: Investing, Roth IRA, Traditional IRA, Crypto, …>",
     "agentic": true or false,
     "holdings_supported": true or false,
     "value": <total usd number>, "cash": <usd number>,
     "buying_power": <usd number>}
  ]}

  Rules:
  - One entry per account from get_accounts. Never merge or omit accounts.
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
  You are trading on the operator's Robinhood accounts through the
  mcp__robinhood__* tools.

  Account authority — this is the one rule that never bends:
  - You may READ any account (get_accounts, get_portfolio, positions, orders).
  - You may place, amend, or cancel orders ONLY on the dedicated Agentic
    account. Every other account — Investing, Roth IRA, Traditional IRA,
    Crypto — is READ-ONLY to you.
  - If the operator asks you to trade in a non-agentic account, do not do it.
    Say which account you can trade in and stop.

  Rules:
  - Check current positions and buying power (get_portfolio,
    get_equity_positions) before placing any order.
  - Every tool call takes an account_number — pass the agentic account's
    number on anything that writes. Never let a read of another account carry
    into an order.
  - After placing or cancelling an order, re-check the order tools and report
    the actual status and fill — never assume an order executed.
  - Quote real numbers from the quote tools; never invent prices, fills, or P&L.
  - If the Robinhood tools are unavailable or unauthenticated, say so plainly
    and stop — never simulate trading activity.
  """

  def conv_id, do: @conv_id

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
       account ends in those digits. If more than one does, use the first.
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
      extra_cli_args: ["--strict-mcp-config", "--mcp-config", ensure_mcp_config()]
    ]
  end

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

  @doc """
  Stage 1: fetch balances for every account through the operator's own `claude`
  (haiku — a refresh costs cents, not dollars). Blocking; callers run it under
  `start_async`. Test seam: `:trading_snapshot_fetcher` app env.
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
       account ends in those digits. If more than one does, use the first.
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
      extra_args: ["--strict-mcp-config", "--mcp-config", ensure_mcp_config()],
      model: "haiku",
      timeout_ms: timeout_ms,
      login: true
    ]

    case AgentRunner.run(prompt, opts) do
      {:ok, %{exit_status: 0, output: output}} -> parser.(output)
      {:ok, %{exit_status: status}} -> {:error, {:agent_exit, status}}
      {:error, reason} -> {:error, reason}
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
             "positions" => detail["positions"] |> List.wrap() |> Enum.filter(&is_map/1),
             "orders" => detail["orders"] |> List.wrap() |> Enum.filter(&is_map/1),
             "detail_at" => DateTime.utc_now() |> DateTime.to_iso8601()
           }}

        _other ->
          {:error, :bad_snapshot}
      end
    else
      _ -> {:error, :bad_snapshot}
    end
  end

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

  @doc "The snapshot's accounts, or `[]`."
  def accounts(%{"accounts" => accounts}) when is_list(accounts), do: accounts
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
