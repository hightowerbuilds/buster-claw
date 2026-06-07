# Intentions

The north-star for Buster Claw — what it's for and what it deliberately is not.

## What it is

Buster Claw is a desktop runtime where an AI agent manages your web interactivity —
browsing and fetch, Google Workspace (Gmail / Calendar), third-party integrations
(GitHub / Sentry / Umami), MCP servers, and outbound delivery — through one auditable
command surface.

The intelligence is **remote, not in the box**. You run Claude Code or Codex in the
in-app terminal; those agents drive Buster Claw through its MCP server (`POST /mcp`) and
the workspace files. The app itself has no built-in LLM and needs no API keys.

## What it is not

- **Not a local-first research/knowledge tool.** Data is stored locally, but that's a
  property, not the pitch. Content ingest is a secondary capability, not the headline.
- **Not its own brain.** The built-in chat, the LLM providers, and the
  ingest→analyze→deliver pipeline were removed. The terminal agent is the brain.

## What it optimizes for

1. **One auditable surface** — every command, outbound send, and untrusted fetch flows
   through `BusterClaw.Commands` and is recorded by Sentinel, with per-caller trust tiers.
2. **Unattended reliability** — the orchestration "shift" lets a deterministic Elixir
   brain dispatch disposable agents for up to 12 hours with brakes and a black box.
3. **Honest boundaries** — restricted actions are refused for untrusted callers, secrets
   are encrypted at rest, and fetched/agent-authored content is sanitized before display.
