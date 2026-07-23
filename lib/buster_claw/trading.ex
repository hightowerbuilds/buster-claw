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

  @snapshot_prompt """
  Call mcp__robinhood__get_accounts and mcp__robinhood__get_portfolio for the
  agentic account, plus the order-history tool for the 10 most recent orders,
  then output ONLY one JSON object — no prose, no code fences:
  {"account": "<masked account id>", "value": <total usd number>,
   "cash": <usd number>, "buying_power": <usd number>,
   "positions": [{"symbol": "<ticker>", "quantity": <number>, "value": <usd number>}],
   "orders": [{"symbol": "<ticker>", "side": "buy" or "sell", "quantity": <number>,
    "price": <usd number or null>, "state": "<order state>",
    "placed_at": "<ISO8601 timestamp or null>"}]}
  Numbers must come from the tool results — never invent them. If the tools are
  unavailable or unauthenticated, output exactly: {"error": "<one-line reason>"}
  """

  @system_prompt """
  You are trading on the operator's Robinhood Agentic account through the
  mcp__robinhood__* tools. Orders execute with real money on the dedicated
  agentic account (the primary Robinhood account is read-only to you).

  Rules:
  - Check current positions and buying power (list_positions, get_balance)
    before placing any order.
  - After placing or cancelling an order, re-check list_orders and report the
    actual status and fill — never assume an order executed.
  - Quote real numbers from get_quotes; never invent prices, fills, or P&L.
  - If the Robinhood tools are unavailable or unauthenticated, say so plainly
    and stop — never simulate trading activity.
  """

  def conv_id, do: @conv_id

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

  @doc "The cached snapshot, `{:ok, map} | :none`."
  def cached_snapshot do
    with raw when is_binary(raw) <- Settings.get(@snapshot_key),
         {:ok, %{"value" => _} = snap} <- Jason.decode(raw) do
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

  @doc """
  Fetch a fresh account snapshot through the operator's own `claude` (haiku —
  a refresh costs cents, not dollars). Blocking (~10s); callers run it under
  `start_async`. Test seam: `:trading_snapshot_fetcher` app env.
  """
  def fetch_account_snapshot do
    case Application.get_env(:buster_claw, :trading_snapshot_fetcher) do
      fun when is_function(fun, 0) -> fun.()
      nil -> run_snapshot_fetch()
    end
  end

  defp run_snapshot_fetch do
    opts = [
      extra_args: ["--strict-mcp-config", "--mcp-config", ensure_mcp_config()],
      model: "haiku",
      timeout_ms: 90_000,
      login: true
    ]

    case AgentRunner.run(@snapshot_prompt, opts) do
      {:ok, %{exit_status: 0, output: output}} -> parse_snapshot(output)
      {:ok, %{exit_status: status}} -> {:error, {:agent_exit, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Extract and validate the snapshot JSON from an agent's raw output. Stderr is
  merged into stdout by the runner, so tolerate surrounding noise; stamp
  `fetched_at` app-side — the model's clock is never trusted.
  """
  def parse_snapshot(output) when is_binary(output) do
    with [json] <- Regex.run(~r/\{.*\}/s, output) || :nomatch,
         {:ok, decoded} <- Jason.decode(json) do
      case decoded do
        %{"error" => msg} ->
          {:error, {:robinhood, to_string(msg)}}

        %{"value" => v, "cash" => c, "buying_power" => bp} = snap
        when is_number(v) and is_number(c) and is_number(bp) ->
          {:ok,
           snap
           |> Map.put("positions", snap["positions"] |> List.wrap() |> Enum.filter(&is_map/1))
           |> Map.put("orders", snap["orders"] |> List.wrap() |> Enum.filter(&is_map/1))
           |> Map.put("fetched_at", DateTime.utc_now() |> DateTime.to_iso8601())}

        _other ->
          {:error, :bad_snapshot}
      end
    else
      _ -> {:error, :bad_snapshot}
    end
  end
end
