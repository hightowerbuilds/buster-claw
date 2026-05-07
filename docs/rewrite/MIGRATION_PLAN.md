# Migration Plan

## Purpose

Move legacy local file state into the Elixir rewrite SQLite model without changing the local-first contract. SQLite becomes the source of truth for structured state, while markdown artifacts remain inspectable under `Library/raw/**`, `Library/reports/**`, `Library/Memory.md`, and `Intentions.md`.

This plan is a one-way import into a new rewrite database. It must never mutate, delete, or rewrite legacy user data files during import.

## Inputs

Runtime root:

- `sources.json`
- `providers.json`
- `mcp.json`
- `Intentions.md`

Library root:

- `Library/raw/YYYY-MM-DD/*.md`
- `Library/reports/YYYY-MM-DD/*.md`
- `Library/reports/manifest.json`
- `Library/queue.json`
- `Library/Memory.md`
- `Library/delivery.json`
- `Library/hooks.json`
- `Library/webhooks.json`
- `Library/scheduler.json`
- `Library/calendar.json`

Legacy aliases to support during discovery:

- `memory/pneuma.md`, documented in `docs/ARCHITECTURE.md`, should be imported only if `Library/Memory.md` is absent.
- Missing optional JSON files are valid and should import as empty collections.

Generated files are not migration inputs:

- generated desktop or build artifacts

## Target Tables

Import into the tables proposed in `docs/rewrite/DATA_MODEL.md`:

- Core configuration: `sources`, `providers`, `mcp_servers`, `delivery_destinations`, `hooks`, `webhooks`, `scheduler_jobs`, `calendar_events`, `memories`, `intentions_versions`.
- Library and artifacts: `documents`, `reports`, `document_frontmatter`, `report_frontmatter`.
- Workflow and audit state: `analysis_jobs`, `ingestion_runs`, `ingestion_items`, `delivery_attempts`, `hook_runs`, `webhook_deliveries`, `scheduler_runs`, `mcp_server_runtime_events`, `runtime_events`.

Runtime histories that only existed in memory should not be invented. Create durable runtime rows only when legacy files contain enough evidence, or when the importer itself needs an audit record.

## Import Order

1. Create an import run record in `runtime_events` with the source root, library root, importer version, started timestamp, and dry-run flag.
2. Validate source paths and take a read-only snapshot of every discovered file's path, size, mtime, and hash.
3. Import `Intentions.md` into `intentions_versions` before reports, because report rows may reference the active intentions version.
4. Import `sources.json` into `sources`.
5. Import `providers.json` into `providers`.
6. Import `mcp.json` into `mcp_servers`.
7. Import `Library/delivery.json` into `delivery_destinations`.
8. Import `Library/hooks.json` into `hooks`.
9. Import `Library/webhooks.json` into `webhooks`.
10. Import `Library/scheduler.json` into `scheduler_jobs`.
11. Import `Library/calendar.json` into `calendar_events`.
12. Import `Library/Memory.md` or the legacy `memory/pneuma.md` fallback into `memories`.
13. Index raw markdown artifacts under `Library/raw/YYYY-MM-DD/*.md` into `documents` and `document_frontmatter`.
14. Import `Library/reports/manifest.json` if present, then index report markdown artifacts under `Library/reports/YYYY-MM-DD/*.md` into `reports` and `report_frontmatter`.
15. Import `Library/queue.json` after documents and reports so processed-file state can be matched to document rows.
16. Derive `analysis_jobs` from current queue entries, processed-file state, and document/report matches.
17. Run validation checks and write an import summary event.

The importer should use one database transaction per stage, plus an outer import marker. If any stage fails validation, leave prior stages committed only when running in resumable mode; otherwise run the whole import in a single transaction and roll it back.

## Field Mapping

### Sources

Read `sources.json` as `{ "sources": [...] }`.

- `url` maps to `sources.url`.
- `type` maps to `sources.type`; valid values are `article`, `documentation`, `rss`, `youtube_transcript`, and `browser`.
- `name` maps to `sources.name`.
- `tags` maps to JSON tags or a normalized tag join table.
- `browser_engine` maps to `sources.browser_engine`.
- `cookies` maps to local JSON. Do not print cookie values in logs.
- `enabled` defaults to `true` because legacy sources have no disabled field.

Use URL as the natural key. Duplicate URLs in the same file should be rejected unless all other fields are identical, in which case the duplicate is skipped with a warning.

### Providers

Read `providers.json` as `{ "providers": [...] }`.

- `name` maps to `providers.name`.
- `type` maps to `providers.type`; valid values are `ollama`, `openrouter`, `openai`, `anthropic`, and `custom`.
- `baseUrl` maps to `providers.base_url`.
- `apiKey` maps to `providers.api_key`.
- `model` maps to `providers.model`.
- `active` maps to `providers.active`.
- `priority` maps to `providers.priority`.

Use provider name as the natural key. If multiple providers are marked active, keep the lowest `priority` active and import the others as inactive with a validation warning. Provider secrets remain local and should be masked in import logs, summaries, and UI responses.

### MCP Servers

Read `mcp.json` as `{ "servers": [...] }`. Preserve the full server command definition as structured JSON where exact fields are not yet finalized. The natural key is server name. Do not launch MCP processes during import.

### Delivery, Hooks, Webhooks, Scheduler, Calendar

Import each optional JSON file from `Library/` using its existing top-level collection:

- `Library/delivery.json`: `{ "destinations": [...] }`, keyed by destination name.
- `Library/hooks.json`: `{ "hooks": [...] }`, keyed by hook name plus event.
- `Library/webhooks.json`: `{ "hooks": [...] }`, keyed by webhook name.
- `Library/scheduler.json`: `{ "jobs": [...] }`, keyed by job id.
- `Library/calendar.json`: `{ "events": [...] }`, keyed by event id.

Preserve legacy camelCase fields:

- `customCmd` maps to `custom_cmd`.
- `deliverTo` maps to `deliver_to`.
- `chatId` maps to `chat_id`.

Validate cron expressions before inserting scheduler jobs. Invalid jobs should be imported as disabled with `last_error` set, not dropped.

### Memory

Read markdown lines matching `- [RFC3339 timestamp] text` from `Library/Memory.md`. Import each line into `memories` with:

- `created_at` from the bracketed timestamp when valid.
- `text` from the remaining line.
- `artifact_path` pointing at the source memory file.
- `source_line` if supported.

If a timestamp is missing or invalid, use the import timestamp as `inserted_at`, preserve the raw timestamp string in metadata, and emit a warning.

### Intentions

Read the full `Intentions.md` body into `intentions_versions`.

The deterministic version key should be the content hash. Mark the newest imported version active. Reports imported in the same run should reference this active version unless their frontmatter proves another version.

## Artifact Indexing Rules

Artifacts stay on disk. SQLite stores validated relative paths, hashes, metadata, and relationships.

### Path Rules

- Resolve every artifact path to an absolute path before indexing.
- Reject any path that escapes the configured runtime root or library root after symlink resolution.
- Store artifact paths relative to the runtime root when possible, for example `Library/raw/2026-04-26/source.md`.
- Normalize path separators to `/`.
- Index only `.md` files under the expected date directory shapes.
- Ignore hidden files, temporary files, generated frontend files, and non-markdown files.

### Raw Documents

Scan `Library/raw/YYYY-MM-DD/*.md`.

- `artifact_path` is the normalized relative path.
- `filename` is the basename.
- `date` comes from the `YYYY-MM-DD` directory first, then frontmatter, then file mtime.
- `content_hash` is SHA-256 of the exact file bytes.
- `source_url`, `name`, and `tags` come from frontmatter when present.
- `source_id` is matched by exact `source_url` to `sources.url`; RSS-expanded entries may have no configured source match and should still import.
- `status` defaults to `fetched`.
- `excerpt` should be the first non-frontmatter text, capped for UI display.

Store all parsed frontmatter keys in `document_frontmatter`, even if only a subset maps to first-class columns.

### Reports

First read `Library/reports/manifest.json` when present. Then scan `Library/reports/YYYY-MM-DD/*.md` and merge filesystem findings with manifest entries.

- `artifact_path` is the normalized relative path.
- `filename` is the basename.
- `generated_at` comes from report frontmatter or manifest, then date directory, then file mtime.
- `source_file` comes from frontmatter or manifest.
- `source_url`, `model`, and `tags` come from frontmatter or manifest.
- `document_id` is matched by `source_file` basename, exact artifact path, or source URL plus nearest date.
- `provider_id` is matched by active provider/model when possible; otherwise leave null.
- `intentions_version_id` points to the active imported intentions version when `intentions_used` is true or unknown.

Store all parsed report frontmatter in `report_frontmatter`. If a manifest entry points to a missing markdown file, insert a report row with `status = "missing_artifact"` only if the target schema supports status; otherwise record the warning in `runtime_events` and skip the report row.

## Queue And Job State

The legacy queue has two sources:

- In-memory `QueueEntry` values exposed while the app is running.
- `Library/queue.json` with `{ "processed_files": { "/abs/path/doc.md": true } }`.

The importer can only rely on `Library/queue.json` unless a running Go process exports live queue state. For the normal offline import:

- Mark documents whose absolute or normalized path appears in `processed_files` as `analyzed` when a matching report exists.
- Mark documents in `processed_files` without a matching report as `analyzed` with a warning, because the legacy queue only means analysis completed enough to mark processed.
- Mark unprocessed raw documents as `fetched`; the rewrite may present them as pending raw documents.
- Create `analysis_jobs` with `status = "done"` for processed documents with reports.
- Do not create queued or analyzing jobs from missing in-memory state.

If an optional live queue export is added later, import each entry by path:

- `queued` maps to `analysis_jobs.status = "queued"` and `documents.status = "queued"`.
- `analyzing` maps to `analysis_jobs.status = "failed"` with an interruption note unless the source app was explicitly paused before export.
- `done` maps to `analysis_jobs.status = "done"`.
- `failed` maps to `analysis_jobs.status = "failed"` and preserves `error`.

## Idempotency Strategy

Every import must be safe to run more than once.

- Use deterministic natural keys for legacy records: source URL, provider name, MCP server name, delivery name, hook name plus event, webhook name, scheduler job id, calendar event id, artifact path, and content hash.
- Add `legacy_source_path`, `legacy_source_hash`, and `last_imported_at` metadata where the target schema supports it.
- Use upserts for configuration rows. Re-running the importer updates rows when the source file hash changed and leaves unchanged rows untouched.
- Use `artifact_path` plus `content_hash` for document and report rows. If the same path has a new hash, update metadata and preserve the previous hash in an audit event.
- Use content hash as the natural key for `intentions_versions`.
- Use memory file path plus source line plus text hash for memory entries.
- Use an `import_runs` concept through `runtime_events` so each row can be traced to the import that created or last updated it.

Idempotency must not hide conflicts. If two legacy records map to the same natural key with different payloads inside one import run, fail that stage unless a documented conflict rule exists.

## Validation

Run validation before and after writes.

Preflight validation:

- Source root and library root exist or are explicitly accepted as empty.
- JSON files parse when present.
- Optional missing files are reported as skipped, not errors.
- Artifact paths resolve under the configured root.
- Date directories use `YYYY-MM-DD`.
- Provider active state has at most one effective active provider.
- Scheduler cron expressions parse.

Post-import validation:

- Counts match: imported rows plus skipped rows equal discovered legacy records.
- Every `documents.artifact_path` and `reports.artifact_path` points to an existing markdown file unless explicitly recorded as a missing manifest artifact.
- Every `reports.document_id`, when set, points to an existing document.
- Every active provider is unique.
- Every processed queue path is matched to a document or recorded as an orphan warning.
- Every markdown artifact can be opened and hashed after import.
- No imported path escapes the runtime or library root.
- Acceptance queries for the parity views return data for sources, documents, reports, queue-derived pending state, providers, memory, calendar, webhooks, hooks, delivery, and scheduler definitions when those legacy inputs existed.

Write a machine-readable import summary with counts for discovered, inserted, updated, unchanged, skipped, warned, and failed records per stage.

## Rollback And Safety Policy

The importer is read-only toward legacy user data files.

- Default to dry-run mode until validation passes.
- Before a real import, create a SQLite backup if the target database already exists.
- Use SQLite transactions around each stage. For first-run imports, prefer one transaction for the full import.
- Never delete target rows during import unless the user explicitly runs a prune mode.
- Never delete, move, rewrite, or normalize markdown artifacts in place.
- Never log provider API keys, webhook secrets, Telegram tokens, cookies, or full hook payloads.
- On failure, roll back the active transaction and leave the legacy files untouched.
- On partial resumable imports, record the failed stage and make the next run continue by idempotent upsert, not by truncating tables.
- If validation finds path traversal, symlink escape, malformed JSON, or duplicate conflicting natural keys, stop before writing that stage.

Rollback procedure:

1. Stop the rewrite app so no workers are writing SQLite.
2. Restore the pre-import SQLite backup, or drop the newly created database if this was a first import.
3. Keep the import summary and warnings for debugging.
4. Re-run dry-run after fixing the source files or importer mapping.

## Acceptance Checks

The migration is acceptable when these checks pass against a copied legacy runtime:

- Dry-run reports zero fatal errors and lists every discovered legacy file.
- Real import completes without mutating any legacy JSON or markdown file hashes.
- Sources from `sources.json` appear in the rewrite Sources view.
- Providers from `providers.json` appear in Intelligence, with exactly one active provider when legacy data had any active provider.
- MCP server definitions appear without being launched during import.
- Raw markdown files from `Library/raw/YYYY-MM-DD/*.md` appear in Documents and can be previewed.
- Processed entries from `Library/queue.json` are reflected as analyzed or recorded as orphan warnings.
- Unprocessed raw documents appear as pending candidates for analysis.
- Reports from manifest and filesystem scans appear in Analysis and can be opened.
- Report-to-document links resolve when source file or source URL data is available.
- Memory entries from `Library/Memory.md` appear in Advanced and chat memory context.
- Delivery destinations, hooks, webhooks, scheduler jobs, and calendar events survive app restart.
- Scheduler jobs with invalid cron expressions are visible but disabled with an error.
- Secrets are present for local execution but masked in UI responses and import logs.
- Restarting the rewrite app after import shows the same migrated state without re-running the importer.
- Re-running the importer produces no duplicate rows and reports unchanged rows for unchanged input files.
