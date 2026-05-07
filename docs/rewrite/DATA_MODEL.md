# Rewrite Data Model Notes

## Purpose

The current app persists state across several JSON files, markdown files, in-memory structures, and generated manifests. The Elixir rewrite should consolidate structured state into SQLite while preserving markdown artifacts on disk.

## Current Runtime Files

Repo/runtime root:

- [ ] `sources.json`: configured ingestion sources.
- [ ] `providers.json`: configured model providers and active provider selection.
- [ ] `mcp.json`: configured MCP stdio server commands.
- [ ] `Intentions.md`: analysis instructions.

Library root:

- [ ] `Library/raw/YYYY-MM-DD/*.md`: raw ingested documents.
- [ ] `Library/reports/YYYY-MM-DD/*.md`: generated markdown reports.
- [ ] `Library/reports/manifest.json`: report manifest.
- [ ] `Library/queue.json`: processed-file tracking for pending analysis.
- [ ] `Library/Memory.md`: persistent memory.
- [ ] `Library/delivery.json`: delivery destinations.
- [ ] `Library/hooks.json`: reactive hooks.
- [ ] `Library/webhooks.json`: local webhook definitions.
- [ ] `Library/scheduler.json`: scheduled jobs.
- [ ] `Library/calendar.json`: user calendar events.

Build/generated state:

- [x] Legacy frontend generated artifacts are no longer part of the active repo.

## Proposed SQLite Tables

Core configuration:

- [ ] `sources`
- [ ] `providers`
- [ ] `mcp_servers`
- [ ] `webhooks`
- [ ] `hooks`
- [ ] `delivery_destinations`
- [ ] `scheduler_jobs`
- [ ] `calendar_events`
- [ ] `memories`
- [ ] `intentions_versions`

Library and artifacts:

- [ ] `documents`
- [ ] `reports`
- [ ] `document_frontmatter`
- [ ] `report_frontmatter`

Workflow state:

- [ ] `ingestion_runs`
- [ ] `ingestion_items`
- [ ] `analysis_jobs`
- [ ] `delivery_attempts`
- [ ] `hook_runs`
- [ ] `webhook_deliveries`
- [ ] `scheduler_runs`
- [ ] `mcp_server_runtime_events`
- [ ] `runtime_events` or `audit_events`

## Source Fields

- [ ] `id`
- [ ] `url`
- [ ] `type`
- [ ] `name`
- [ ] `tags`
- [ ] `browser_engine`
- [ ] `cookies`
- [ ] `enabled`
- [ ] `inserted_at`
- [ ] `updated_at`

Constraints:

- [ ] Unique URL.
- [ ] Valid source type.
- [ ] Tags stored as JSON or normalized join table.

## Provider Fields

- [ ] `id`
- [ ] `name`
- [ ] `type`
- [ ] `base_url`
- [ ] `api_key`
- [ ] `model`
- [ ] `active`
- [ ] `priority`
- [ ] `inserted_at`
- [ ] `updated_at`

Constraints:

- [ ] Unique name.
- [ ] At most one active provider, enforced in context logic or database constraint.
- [ ] API key remains local and should be masked in UI responses.

## Document Fields

- [ ] `id`
- [ ] `source_id`
- [ ] `filename`
- [ ] `artifact_path`
- [ ] `date`
- [ ] `source_url`
- [ ] `name`
- [ ] `tags`
- [ ] `content_hash`
- [ ] `status`
- [ ] `excerpt`
- [ ] `fetched_at`
- [ ] `inserted_at`
- [ ] `updated_at`

Status values:

- [ ] `fetched`
- [ ] `queued`
- [ ] `analyzing`
- [ ] `analyzed`
- [ ] `failed`
- [ ] `deleted`

Constraints:

- [ ] Artifact path must resolve under configured library root.
- [ ] Content hash should support deduplication.
- [ ] Source URL should support deduplication and lookup.

## Report Fields

- [ ] `id`
- [ ] `document_id`
- [ ] `filename`
- [ ] `artifact_path`
- [ ] `source_file`
- [ ] `source_url`
- [ ] `model`
- [ ] `provider_id`
- [ ] `intentions_version_id`
- [ ] `tags`
- [ ] `generated_at`
- [ ] `inserted_at`
- [ ] `updated_at`

Constraints:

- [ ] Artifact path must resolve under configured library root.
- [ ] Report filename should be sanitized.

## Analysis Job Fields

- [ ] `id`
- [ ] `document_id`
- [ ] `report_id`
- [ ] `status`
- [ ] `progress`
- [ ] `model`
- [ ] `provider_id`
- [ ] `error`
- [ ] `started_at`
- [ ] `finished_at`
- [ ] `inserted_at`
- [ ] `updated_at`

Status values:

- [ ] `queued`
- [ ] `analyzing`
- [ ] `done`
- [ ] `failed`
- [ ] `cancelled`

## Scheduler Fields

- [ ] `id`
- [ ] `type`
- [ ] `cron`
- [ ] `enabled`
- [ ] `custom_cmd`
- [ ] `deliver_to`
- [ ] `last_run_at`
- [ ] `next_run_at`
- [ ] `last_error`
- [ ] `inserted_at`
- [ ] `updated_at`

Job types:

- [ ] `ingest`
- [ ] `analyze`
- [ ] `full`
- [ ] `digest`
- [ ] `custom`

## Webhook Fields

- [ ] `id`
- [ ] `name`
- [ ] `secret`
- [ ] `action`
- [ ] `custom_cmd`
- [ ] `deliver_to`
- [ ] `enabled`
- [ ] `inserted_at`
- [ ] `updated_at`

Actions:

- [ ] `ingest`
- [ ] `analyze`
- [ ] `full`
- [ ] `command`

## Hook Fields

- [ ] `id`
- [ ] `name`
- [ ] `event`
- [ ] `type`
- [ ] `target`
- [ ] `async`
- [ ] `enabled`
- [ ] `inserted_at`
- [ ] `updated_at`

Hook run fields:

- [ ] `id`
- [ ] `hook_id`
- [ ] `event`
- [ ] `type`
- [ ] `started_at`
- [ ] `duration_ms`
- [ ] `success`
- [ ] `error`
- [ ] `stdout`
- [ ] `stderr`
- [ ] `status_code`
- [ ] `payload`

## Delivery Fields

- [ ] `id`
- [ ] `name`
- [ ] `type`
- [ ] `url`
- [ ] `token`
- [ ] `chat_id`
- [ ] `enabled`
- [ ] `inserted_at`
- [ ] `updated_at`

Delivery attempt fields:

- [ ] `id`
- [ ] `delivery_destination_id`
- [ ] `report_id`
- [ ] `title`
- [ ] `status`
- [ ] `error`
- [ ] `started_at`
- [ ] `finished_at`

## MCP Fields

- [ ] `id`
- [ ] `name`
- [ ] `command`
- [ ] `args`
- [ ] `env`
- [ ] `enabled`
- [ ] `last_status`
- [ ] `last_error`
- [ ] `last_connected_at`
- [ ] `inserted_at`
- [ ] `updated_at`

Discovered tool fields, if persisted:

- [ ] `id`
- [ ] `mcp_server_id`
- [ ] `name`
- [ ] `qualified_name`
- [ ] `description`
- [ ] `input_schema`
- [ ] `discovered_at`

## Memory Fields

- [ ] `id`
- [ ] `created_at`
- [ ] `text`
- [ ] `inserted_at`
- [ ] `updated_at`

## Calendar Fields

- [ ] `id`
- [ ] `date`
- [ ] `title`
- [ ] `notes`
- [ ] `inserted_at`
- [ ] `updated_at`

Constraints:

- [ ] Date validates as `YYYY-MM-DD`.
- [ ] Title is required.

## Import Strategy

- [ ] Import JSON configuration into SQLite tables.
- [ ] Index raw markdown documents without rewriting them.
- [ ] Index report markdown documents without rewriting them.
- [ ] Import report manifest entries when present.
- [ ] Import memories from `Library/Memory.md`.
- [ ] Leave original files untouched during first import.
- [ ] Make imports idempotent.
- [ ] Write a migration report that records created, skipped, and failed records.
