# Buster Claw

`buster-claw` is a desktop application for managing, searching, and analyzing local knowledge using Ollama and LLM providers. Built with [Wails](https://wails.io/), it combines a high-performance Go backend with a modern SolidJS frontend.

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

1. **Requirements**: Go 1.26+, Node.js (for frontend), Ollama.
2. **Clone & Install**:
   ```bash
   git clone <repo-url>
   cd buster-claw
   go mod download
   ```
3. **Run Development**:
   ```bash
   wails dev
   ```
4. **Build**:
   ```bash
   wails build
   ```

## Configuration

Settings are managed via the UI, which persists data into the library directory:
- `sources.json`: Managed ingestion sources.
- `mcp.json`: MCP server connections.
- `providers.json`: LLM provider API keys and configurations.
- `Library/`: Central store for all raw documents, reports, and job state.

## Commands

- `/search <query>`: Search the web.
- `/ingest <url>`: Ingest content for analysis.
- `/browse <url>`: Fetch and render a URL via headless browser.
- `/remember <text>`: Save a fact to persistent memory.
- `/memories`: List saved memories.
- `/status`: Show pipeline activity.
- `/help`: Show available commands.

## Development Notes

- [Quality checks](docs/QUALITY.md) lists the backend and frontend commands to run before refactors.
- [Architecture notes](docs/ARCHITECTURE.md) documents the current runtime shape, persisted files, and generated-code boundaries.
- [Code quality roadmap](CODE_QUALITY_ROADMAP.md) tracks the modularization plan.

## License

MIT
