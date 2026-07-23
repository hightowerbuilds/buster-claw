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

  alias BusterClaw.Library.Artifact

  @conv_id "trading"
  @mcp_url "https://agent.robinhood.com/mcp/trading"

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
end
