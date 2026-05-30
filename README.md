# Buster Claw

`buster-claw` is a local-first Phoenix/LiveView application wrapped in a Tauri desktop shell. Phoenix lives at the repository root; the desktop shell lives in `desktop/tauri`.

## Features

- **Local & Remote LLM Chat**: Interact with local Ollama models or configured external AI providers.
- **Knowledge Pipeline**:
  - **Ingestion**: Scrape and fetch content from web pages and RSS feeds.
  - **Analysis**: Queue-based asynchronous processing to structure ingested documents into markdown reports.
  - **Delivery**: Automatically push reports to Slack, Discord, Telegram, or email.
- **Agentic Capabilities**:
  - **MCP Integration**: Connect Model Context Protocol servers to extend LLM capabilities with custom tools.
  - **Parallel Processing**: Multi-worker analysis pipeline for efficient document handling.
  - **Web Search**: Integrated web search tool for real-time information retrieval.
- **Automation**:
  - **Scheduler**: Cron-based job execution for fully autonomous research cycles.
  - **Webhooks**: Trigger ingestion or analysis pipelines via external HTTP events.
  - **Reactive Hooks**: Pre/post-processing hooks for pipeline events (e.g., auto-tagging, custom alerts).
- **Persistent Memory**: Durable context storage in `Memory/Pneuma.md` to keep your AI smart across sessions.

## Quick Start

Requirements:

- Elixir/Erlang
- Rust/Cargo
- `cargo-tauri`
- Ollama or configured remote LLM provider

Run Phoenix:

```bash
mix phx.server
```

Run the desktop shell in another terminal:

```bash
cd desktop/tauri
cargo tauri dev
```

Phoenix is available directly at `http://127.0.0.1:4000/`; the Tauri shell opens the same app in a native desktop window.

The desktop shell points at `http://127.0.0.1:4000` in dev mode. Override that endpoint when needed:

```bash
cd desktop/tauri
BUSTER_CLAW_PHOENIX_URL=http://127.0.0.1:4001 cargo tauri dev
```

## Configuration

Rewrite state is managed by Phoenix/Ecto and the local library directory:

- `buster_claw_dev.db`: development SQLite database.
- `Library/`: raw documents and generated reports.
- Legacy data files such as `sources.json` and `Library/*.json` are migration inputs.

## Slash commands (in chat)

- `/search <query>`: Search the web.
- `/ingest <url>`: Ingest content for analysis.
- `/browse <url>`: Fetch and render a URL via headless browser.
- `/remember <text>`: Save a fact to persistent memory.
- `/memories`: List saved memories.
- `/status`: Show pipeline activity.
- `/help`: Show available commands.

## Driving Buster Claw (CLI, MCP, HTTP)

Buster Claw exposes a single canonical command surface — see [`docs/rewrite/COMMAND_SURFACE.md`](docs/rewrite/COMMAND_SURFACE.md) for the full catalog (76 commands across sources, providers, documents, analysis, memory, chat, scheduler, webhooks, hooks, delivery, integrations, search, browser, runtime). Three frontends consume it:

### Authentication

A loopback API token lives at `~/Library/Application Support/BusterClaw/api_token` (auto-generated on first launch). Override via `BUSTER_CLAW_API_TOKEN`. The Phoenix endpoint binds to `127.0.0.1` only; the token defends against other local users on a shared machine.

### CLI escript

```bash
# Build (once)
mix escript.build

# Run
./buster-claw commands                          # list the catalog
./buster-claw source list                       # noun-verb shorthand
./buster-claw run analysis_queue --json '{"document_id": 1}'
./buster-claw run web_search --json '{"query": "phoenix liveview"}'
```

Token comes from `BUSTER_CLAW_API_TOKEN` env, then the file path above, then `--token <token>` flag. Base URL is `BUSTER_CLAW_URL` env or `--url <url>` flag (default `http://127.0.0.1:4000`).

### MCP server (for Claude Code, Codex, other TUI agents)

Buster Claw hosts an MCP server at `POST /mcp` using the Streamable HTTP transport (JSON-RPC, JSON response form). Add this to your Claude Code config (`~/Library/Application Support/Claude/claude_desktop_config.json` or similar):

```json
{
  "mcpServers": {
    "buster-claw": {
      "url": "http://127.0.0.1:4000/mcp",
      "headers": {
        "Authorization": "Bearer <your-token>"
      }
    }
  }
}
```

The full safe-tier catalog (read commands, chat, low-risk triggers) appears in the agent's tool list. Restricted commands (deletes, `provider_set_active`, `delivery_dispatch_all`) are still callable via the HTTP API and CLI but are not exposed to MCP for safety.

### HTTP API (for direct integration)

```bash
TOKEN=$(cat ~/Library/Application\ Support/BusterClaw/api_token)

# Catalog (no auth needed)
curl http://127.0.0.1:4000/api/commands

# Invoke a command
curl -X POST http://127.0.0.1:4000/api/run \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"command":"source_list","args":{}}'
```

### Internal agent (chat-driven tool calls)

When the active provider is Anthropic, the chat session passes safe-tier commands to the model as Anthropic tool definitions and runs an agentic loop — the model can call `runtime_status`, `document_list`, `analysis_queue`, `chat_messages`, etc. and use the results in its next reply. The loop is capped at 6 iterations to prevent runaway recursion. Other provider types fall back to plain chat without tools (OpenAI/Gemini/Codex tool-call adapters are planned).

## Development Notes

- [Quality checks](docs/QUALITY.md) lists the Phoenix and Tauri commands to run before refactors.
- [Architecture notes](docs/ARCHITECTURE.md) documents the current runtime shape, persisted files, and generated-code boundaries.
- [UML / architecture diagrams](docs/UML.md) — Mermaid diagrams of the system layers, supervision tree, domain model, command surface, provider abstraction, and the core functional flows (ingest→analyze→deliver, agentic chat loop).
- [Local trust model](docs/LOCAL_TRUST.md) documents shell hooks, webhooks, stored secrets, fetched markdown, and MCP boundaries.
- [Rewrite packaging notes](docs/rewrite/DESKTOP_PACKAGING.md) document the Phoenix/Tauri desktop path.
- [Rewrite cutover notes](docs/rewrite/CUTOVER.md) document what still blocks packaged daily use.
- Historical quality plans are archived in `daily-growth/old-maps/`.

## License

MIT
