---
id: trading-robinhood
schema: 1
name: Robinhood Trading
version: "1.0.0"
summary: Read your Robinhood accounts, positions and orders in a pinned conversation, and propose trades for your confirmation.
surface: trading
network: ["agent.robinhood.com"]
writes: ["order_cancel"]
money: true
---

# Robinhood Trading

Adds the **Trading** surface: a pinned conversation beside a live accounts
dashboard, reading your Robinhood accounts through your own agent.

## What it can reach

- **Your Robinhood accounts** — balances, positions, resting and historical
  orders, tax lots, quotes, index levels, and earnings dates.
- **One network host** — `agent.robinhood.com`, the Robinhood MCP server. The run
  is scoped to exactly that server; no other tooling you have configured is
  visible to it.
- **One write verb** — cancelling a resting order. It reaches the broker the
  moment the model calls it, with no confirmation card in front of it. Every use
  lands on the Security feed as it happens.

## What it cannot do

- **It cannot place or amend an order.** The placement tool is not in the
  conversation's run. To place a trade the model *proposes* one and you confirm
  it with a click; your click is what reaches the broker.
- **It cannot act on a non-agentic account.** Robinhood refuses order actions on
  any account not marked agent-enabled.
- **It never sees your credentials.** This application holds no broker
  credentials and speaks no MCP. You authenticate Robinhood to your own `claude`
  installation with a one-time `claude mcp login robinhood`; the tokens live in
  your macOS Keychain.

## What is not guaranteed

Stated plainly, because the rest of this file reads like a list of controls:

- **Balances are transcribed by a language model**, not read from a structured
  pipe. A wrong number can enter your permanent portfolio history, and Robinhood
  does not publish historical account values to correct it from.
- **Which account a cancellation lands in is not enforced by this application.**
  The tool call belongs to the model; the account rule is an instruction in its
  playbook and a fact about what Robinhood accepts.

## Setup

    claude mcp add --transport http --scope user robinhood https://agent.robinhood.com/mcp/trading
    claude mcp login robinhood

## Parts

- `robinhood-trading` — the operating playbook: authority model, account
  identity, the cancel discipline, and the order-proposal contract.
