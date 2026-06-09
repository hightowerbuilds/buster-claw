# 06-07-2026 Summary

## Today

### Brand/logo update

- Replaced the old "Phoenix Skeleton / Buster Claw" text treatment on the home
  status page with the supplied Buster Claw logo image.
- Added the logo image paths to `.gitignore` so the working asset does not get
  accidentally committed from either the repo root or `priv/static/images`.

### Roadmap check

- Reviewed the active `daily-growth/roadmaps` folder.
- Current orchestration implementation is largely built out, but the follow-up
  file still tracks real-world validation work:
  - real 12-hour unattended dry-run
  - crash-loop brake trip-path test with an injectable failure seam
  - token / dollar budget cap enforcement
  - full packaged Tauri build in a normal shell

### Unused code audit and removal

- Audited the app for dead code and stale feature surfaces with `rg`, compile
  checks, command-catalog review, and dependency cleanup.
- Removed the legacy local-data importer:
  - `BusterClaw.Migration`
  - `sources.json`
  - migration tests
- Removed stale prompt/planning artifacts that were no longer part of the
  runtime:
  - `BusterClaw.Intentions`
  - `Intentions.md`
- Removed the unused Swoosh mailer stack:
  - `BusterClaw.Mailer`
  - Swoosh config and dev mailbox route
  - Swoosh dependency plus unused transitive deps from `mix.lock`
- Removed the dead desktop workspace relaunch bridge:
  - unused `WorkspacePicker` JS hook
  - Tauri `workspace_relaunch` command
  - Tauri ACL permission and generated schema references
- Removed unused runtime/process surfaces:
  - `BusterClaw.AgentMode`
  - bulk hook event execution (`hook_event_execute` / `Hooks.execute_event`)
  - old `llm_submission` Sentinel category
  - obsolete `no_active_provider` error special-case
- Tightened placeholder automation features that only recorded data but did not
  execute real work:
  - scheduler jobs now only expose `integrations_poll`
  - webhook create/update no longer expose `custom_cmd` or `deliver_to`
  - delivery destinations no longer advertise email
- Removed stale helpers and fields:
  - `source_id` document passthrough
  - `report_id` delivery attempt passthrough
  - raw markdown re-index helpers
  - unused report-date directory helper
- Removed duplicated hashed font files from `priv/static/fonts`; the app uses
  the unhashed font assets.

### Docs and command surface cleanup

- Replaced the stale hand-written `docs/COMMAND_SURFACE.md` catalog with a
  shorter overview that points to the live command catalog as source of truth.
- Updated README, UML, architecture notes, CLI examples, setup copy, settings
  labels, and the model introduction so they no longer claim removed features
  exist.
- Current command catalog count: 71 commands.

### Orchestration assignment work preserved

- The worktree also includes shift assignment metadata work:
  - new shift assignment fields (`job_key`, `job_name`, `job_description`,
    `agent_name`, `shell`, `duration_hours`)
  - a migration for those columns
  - panel/status test updates
- During cleanup verification, fixed small compile/test issues in that area:
  - reused `@default_shift_hours` for the default Lookout shift
  - made shift option lookup accept both atom and string keys

### Home shift shell display

- Built the home-page shift container around the terminal-agent control model:
  the browser UI now **only displays** whether a shell is currently open/on shift
  for a job.
- Added durable shift assignment metadata to the `shifts` schema and command
  surface so terminal agents can start shifts with job/shell identity:
  - `job` / `job_key`
  - `agent_name`
  - `shell`
  - `hours` / `duration_hours`
- Added a small shift job catalog in `BusterClaw.Orchestration`:
  - `Lookout` defaults to a 12-hour shift
  - `Dispatcher` defaults to 4 hours
  - `Scribe` defaults to 2 hours
- Updated the home `OrchestrationPanel` to show:
  - empty state: `No shift shell open.`
  - active state: `Shell open`, job name, agent name, shell name, shift window,
    time remaining, and progress
- Removed the browser-side start/reassign controls after deciding all shift
  control belongs to the terminal agent:
  - no `Start shift` button
  - no shift assignment form
  - no browser LiveView events for `start_shift_assignment` or
    `change_shift_assignment`
- Kept the CLI/API/MCP control path. Example:

  ```sh
  ./buster-claw run shift_start --json '{"job":"lookout","agent_name":"Codex","shell":"Terminal 1","hours":12}'
  ```

### Shift role sessions

- Split the operating model so there is still only one active shift window,
  while specialist shells now run as active role sessions inside that shift.
- Added the `shift_assignments` runtime table and schema for specialist role
  sessions with:
  - `shift_id`
  - `role_key`
  - `agent_name`
  - `shell`
  - `status`
  - `started_at`, `ended_at`, `heartbeat_at`
  - optional `purpose`, `dedupe_key`, and `notes`
- Added role-session commands for terminal/API/MCP control:
  - `shift_assignment_start`
  - `shift_assignment_status`
  - `shift_assignment_stop`
- Added built-in specialist role defaults for Mail Triage, Scribe, CI Fix, and
  Dispatcher so those shells can attach to the active Lookout shift without
  starting another shift.
- Updated the home shift container to show active specialist shells under the
  current shift in a display-only `Specialist Shells` section.
- Starting the same role or dedupe key now replaces the prior active session
  under the current shift; stopping/completing/superseding the shift stops all
  active role sessions.

### Dispatch queue table

- Added the durable `dispatch_items` table as the handoff contract for trusted
  inbound requests.
- Dispatch rows now carry Gmail identity, sender/trust/auth fields, request
  summary/body excerpt, recommended agent/role, risk, status, dedupe key,
  lifecycle timestamps, outcome/notes, metadata, and links to:
  - active shift
  - shift assignment
  - orchestrator task
- Added `BusterClaw.Dispatch.Item` and `BusterClaw.Dispatch` with queue
  operations for:
  - enqueueing requests
  - mapping Gmail message context into Dispatch rows
  - claiming the oldest queued item
  - marking an item running
  - heartbeats
  - finishing as `done`, `failed`, or `blocked`
- Added focused Dispatch tests for dedupe behavior, Gmail mapping, claiming, and
  lifecycle transitions.

### Multiple terminals plan

- Added a roadmap for building multiple visible terminal sessions in Buster Claw.
- The plan identifies the current blocker: Tauri already supports multiple PTY
  sessions, but `TerminalLive` hardcodes `data-session-key="main"`.
- Proposed phased work:
  - parameterize terminal session keys
  - add new terminal tab creation
  - pass terminal params through split panes
  - add scoped terminal toolbar controls
  - later connect Dispatch/Dispatcher-created work to visible terminal sessions

## Verification

- `mix precommit` passed after the read-only shift display update: 320 tests,
  0 failures.
- `mix precommit` passed after the shift role-session model update: 325 tests,
  0 failures.
- `mix precommit` passed after the Dispatch table update: 330 tests, 0 failures.
- `cargo check` passed in `desktop/tauri`.
- Final stale-symbol search found no remaining runtime references to the removed
  code paths.
- Dev DB was migrated with `20260607181043_add_shift_assignment_fields`.
- Dev DB was migrated with `20260607184830_create_shift_assignments`.
- Dev DB was migrated with `20260607195108_create_dispatch_items`.
- Phoenix was run on `http://127.0.0.1:4001/` because an existing process was
  holding `:4000`; the running page was checked to confirm the home shift
  display renders and the removed shift form/button IDs do not.

## Notes

- Test database state briefly had the new shift migration marked up while the
  table was missing the new columns; rerunning migration state repaired the
  test DB before the final clean precommit.
- The active roadmap still needs the real 12-hour unattended run before the
  orchestration build-out can be considered field-validated.
