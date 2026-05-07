# Architecture

Buster Claw is now a Phoenix/LiveView application wrapped by a Tauri desktop shell.

## Runtime

- The repository root contains the Elixir application.
- `BusterClawWeb.Endpoint` serves the local UI on `127.0.0.1`.
- Phoenix LiveView owns UI state, streaming updates, forms, and routed surfaces.
- Ecto/SQLite owns structured local state.
- Markdown artifacts remain local files under the configured Library root.
- `desktop/tauri` contains the desktop shell used for development and future packaging.

## Core Contexts

- `BusterClaw.Sources`: ingestion source configuration.
- `BusterClaw.Ingest`: URL/RSS fetching and document creation.
- `BusterClaw.Library`: raw documents, reports, and artifact metadata.
- `BusterClaw.Providers`: local and remote LLM provider configuration.
- `BusterClaw.Chat`: supervised chat sessions and slash commands.
- `BusterClaw.Analysis`: durable analysis jobs and report generation.
- `BusterClaw.Automation`: MCP, scheduler, webhooks, hooks, and delivery configuration.
- `BusterClaw.Memory`: persistent prompt memory.
- `BusterClaw.Calendar`: durable calendar events.
- `BusterClaw.Migration`: importer for legacy local data files.

## Desktop Shell

The Tauri shell is intentionally thin in development. It opens the Phoenix app at `http://127.0.0.1:4000`. Production packaging still needs a release flow that starts the Phoenix runtime and opens the Tauri window after the local endpoint is healthy.
