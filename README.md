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

## Commands

- `/search <query>`: Search the web.
- `/ingest <url>`: Ingest content for analysis.
- `/browse <url>`: Fetch and render a URL via headless browser.
- `/remember <text>`: Save a fact to persistent memory.
- `/memories`: List saved memories.
- `/status`: Show pipeline activity.
- `/help`: Show available commands.

## Development Notes

- [Quality checks](docs/QUALITY.md) lists the Phoenix and Tauri commands to run before refactors.
- [Architecture notes](docs/ARCHITECTURE.md) documents the current runtime shape, persisted files, and generated-code boundaries.
- [Local trust model](docs/LOCAL_TRUST.md) documents shell hooks, webhooks, stored secrets, fetched markdown, and MCP boundaries.
- [Rewrite packaging notes](docs/rewrite/DESKTOP_PACKAGING.md) document the Phoenix/Tauri desktop path.
- [Rewrite cutover notes](docs/rewrite/CUTOVER.md) document what still blocks packaged daily use.
- Historical quality plans are archived in `daily-growth/old-maps/`.

## License

MIT
