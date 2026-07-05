# Terminal cmd-list Editor Roadmap

*2026-07-04. Governing principle: **the terminal's command cheatsheet is
user-editable in the Settings tab, but the On Duty command strings are
immutable — the shift/orchestrator safety surface is not a user preference.**
Users can reword prompts, tune toolbox commands, and add their own; they cannot
edit or remove the four On Duty verbs the kill switch, crash-loop brake, and
per-shift run cap depend on. Edits persist in the existing `app_settings` KV
store and merge over the built-in catalog at read time, so every consumer (the
terminal menu, `startup_profile` validation, the CLI) sees the same view with no
new migration.*

Effort tags: **S** = a sitting, **M** = a day-ish, **L** = multi-day / has unknowns.

---

## Where this sits

Today `BusterClaw.TerminalCommands` (`lib/buster_claw/terminal_commands.ex`)
holds a compile-time `@roles` attribute — five role groups (`agent-setup`,
`mailman`, `queue`, `toolbox`, `prompts`) with ~13 commands total. Three
consumers read it:

- `BusterClawWeb.TerminalLive` → `menu_roles/0` renders the cmd-list flyout
  (the `cmd-list` button on the terminal toolbar).
- `BusterClaw.TerminalWorkspace` → `startup_profile_for_role/1` +
  `startup_command/1` whitelist the `startup_profile` query param that opens a
  terminal pre-typing a role's default command. The catalog is the whitelist —
  it never admits arbitrary shell.
- `BusterClaw.CLI` → indirectly, via the `terminal open --role` path through
  `TerminalWorkspace`.

Nothing persists; the catalog is code. This roadmap makes the **non-protected**
portion of it user-editable from a new Settings sub-tab, without changing the
contract every consumer already relies on (`roles/0`, `menu_roles/0`,
`role/1`, `startup_command/1`, `startup_profile_for_role/1`).

## Protection model — what is locked

Two roles are **protected** and never editable, deletable, or overridable from
the UI:

- `mailman` (On Duty) — `on-duty`, `on-duty-minute`, `off-duty`, `shift-status`.
  The orchestrator's safety model depends on these exact command strings
  (`./buster-claw on-duty`, `./buster-claw off-duty`, etc.) and the audit feed
  references them by name. We lock the whole role so labels, descriptions, and
  commands stay intact.
- `agent-setup` (Install Claude Code) — already `hidden: true`, kept resolvable
  for the Setup wizard's install button + `startup_profile` validation. Stays
  built-in only.

Protected roles render read-only in the editor with a lock icon
(`hero-lock-closed`, `aria-label="Protected"`) and a one-line note: "Part of the
shift safety surface — not editable." The editor never accepts a POST that
touches a protected role key, even if the UI were tricked into submitting one
(server-side refuse in `CmdListLive`).

Everything else (`queue`, `toolbox`, `prompts`) is editable end-to-end:
command string, label, description, and add/delete commands within the role.

## Persistence — single JSON document in `app_settings`

The catalog is small (~13 rows) and a user preference, not a domain entity with
relationships. We store it as one JSON document under the existing
`BusterClaw.Settings` KV store, key `"terminal_commands.catalog"`. No new
migration, no new table.

**Trade-offs to be aware of:**
- ✅ Atomic, simple, fits the existing `Settings` pattern for global prefs.
- ✅ Versioned document shape makes future schema changes explicit.
- ⚠️ Last-write-wins: two browser tabs editing simultaneously can clobber each
  other. Acceptable for a single-user desktop app, but worth noting.
- ⚠️ Whole document is rewritten on every save. Negligible at this size.

If the catalog grows significantly (Phase 2 user-authored role groups), revisit
a dedicated `terminal_command_roles`/`terminal_commands` table.

**Persisted shape** (string keys only — see the atom-key note below):

```json
{
  "version": 1,
  "roles": [
    {
      "key": "toolbox",
      "label": "Commands",
      "aliases": ["surface", "toolbox"],
      "startup_profile": "toolbox",
      "commands": [
        {
          "key": "commands-list",
          "label": "List Commands",
          "description": "Print the full command surface, including runtime skills ([skill]).",
          "command": "./buster-claw commands",
          "is_default": true,
          "builtin": true
        },
        {
          "key": "my-status",
          "label": "My Status",
          "command": "./buster-claw run runtime_status",
          "is_default": false,
          "builtin": false
        }
      ]
    }
  ]
}
```

- `is_default` replaces the runtime `default?` key in the persisted shape.
- `builtin` flags rows that came from `@roles`. Built-in non-protected rows are
  editable but not deletable (prevents accidental loss of shipped commands);
  user-added rows are fully deletable.
- Protected roles (`mailman`, `agent-setup`) are **absent** from the persisted
  document; `load/0` always re-injects them from `@roles`.

**Atom-key note:** `Jason.decode!/1` returns string keys. We must *not* use
`keys: :atoms` on the whole document because user-supplied slug keys would be
converted to atoms (memory-leak risk; AGENTS.md forbids `String.to_atom/1` on
user input). `load/0` keeps the persisted document as string-keyed maps and
maps only the known, whitelisted fields to the atom-keyed runtime shape that
the rest of the app expects.

A `BusterClaw.TerminalCommands.Catalog` module holds an embedded-only Ecto
schema + changeset for the whole document, run before persisting. Validation:
role keys are slugs (`^[a-z0-9-]+$`), unique within the document, and not in the
protected set; command keys are slugs unique within their role; `command` is
non-empty; prompts may be multiline, shell commands may not contain newlines;
each role has at least one command and at most one `is_default: true` command.

---

## Phases

### Phase 0 — refactor `TerminalCommands` to load a merged catalog (S)

**Goal:** every existing consumer reads the merged catalog with no behavior
change when the user catalog is empty.

- Add `BusterClaw.TerminalCommands.load/0`:
  - Reads `Settings.get("terminal_commands.catalog")`, JSON-decodes it with
    string keys.
  - Calls `load/1` with the decoded map (or `nil` if missing).
- Add `BusterClaw.TerminalCommands.load/1` as the merge function (and test
  seam):
  - Accepts a decoded map (or `nil`).
  - Runs the document through `Catalog.migrate/1` (currently a no-op that
    returns the input unchanged; future versions will upgrade older schemas).
  - **Command-level merge:** for each non-protected role in `@roles`, merge
    built-in commands with user commands by `key`. User wins on `label`,
    `description`, `command`, `is_default`. Built-in commands not present in
    the user doc are appended (forward-compat: new app versions ship new
    built-in commands that appear even if the user has edited the role).
    User-only commands (keys not in `@roles`) are appended at the end.
  - Re-injects protected roles (`mailman`, `agent-setup`) from `@roles`
    unchanged.
  - Appends user-only roles (keys not in `@roles`) at the end, in document
    order.
  - Returns the same shape `@roles` always returned, so `roles/0`,
    `menu_roles/0`, `role/1`, `startup_command/1`,
    `startup_profile_for_role/1` keep their contracts.
- Add `BusterClaw.TerminalCommands.put_catalog/1`:
  - Runs the document through `Catalog.changeset/2`.
  - On `:ok`, encodes to JSON and calls `Settings.put/2`.
  - Returns `:ok | {:error, changeset}`.
  - On success, broadcasts `{:terminal_commands_updated, catalog}` on
    `BusterClaw.PubSub` topic `"terminal_commands"` so open terminals can
    re-assign `:terminal_command_roles`.
- Rewire `roles/0`, `menu_roles/0`, `role/1`, `startup_command/1`,
  `startup_profile_for_role/1` to call `load/0`. No caching initially — the
  data is tiny (~1KB JSON, local SQLite read) and negligible for a desktop
  app; add caching only if profiling shows a need.
- `menu_roles/0` keeps the `hidden: true` filter (so `agent-setup` stays off
  the menu). User-added roles are visible by default; Phase 2 will add a
  `hidden` field if needed.
- Empty/missing user catalog → `load/0` returns exactly today's `@roles`
  output.

**Files:** `lib/buster_claw/terminal_commands.ex` (add `load/0`, `load/1`,
`put_catalog/1`, rewire 5 public fns), `lib/buster_claw/terminal_commands/catalog.ex`
(new — embedded schema, changeset, `migrate/1` as a no-op).

**Tests:** update `test/buster_claw/terminal_commands_test.exs` to use
`load/1` (pass decoded maps, no DB needed) and add cases for:
- empty-merge-is-no-op
- protected-role-is-injected-from-builtin
- user-role-append order
- user-override of a non-protected command
- **forward-compat:** user doc has old `toolbox` role, `@roles` has a new
  built-in command; assert the new command appears in the merged output.

Add one integration test that uses `BusterClaw.DataCase` and writes via
`Settings.put/2`, then asserts `load/0` sees it.

### Phase 1 — the Settings sub-tab + editor (M)

**Goal:** a user can open Settings → cmd-list, edit a non-protected role's
commands, add/delete user commands, choose the default command per role, reset
a role to defaults, and see the change in the terminal cmd-list flyout
immediately (even if the terminal is already open).

- **Route + tab:** add `live "/cmd-list", CmdListLive, :index` inside the
  `:default` live_session in `router.ex`. Add `%{key: :cmd_list, label:
  "cmd-list", path: "/cmd-list"}` to `@tabs` in
  `lib/buster_claw_web/components/settings_tabs.ex`, placed after
  `:configuration`.
- **LiveView:** `lib/buster_claw_web/live/cmd_list_live.ex`.
  - `mount/3`: subscribe to `"terminal_commands"` PubSub topic; load catalog
    via `TerminalCommands.load/0`; assign `:roles`, `:protected_keys`, and
    one `to_form/2` per non-protected role.
  - Render each role as an `ic-panel` with the Settings tab header
    (`<BusterClawWeb.SettingsTabs.tabs active={:cmd_list} />`). Protected
    roles render read-only with lock icon and plain `<code>` rows.
    Non-protected roles render one `<.form>` with `phx-submit="save_role"`
    and `phx-change="validate"`, containing all command rows. Each row has
    `<.input>` fields for `label`, `description`, `command` (with
    `phx-debounce="blur"` to avoid chatty keystrokes on long prompts), a
    radio/select for `is_default`, and a delete button (`aria-label="Delete
    command"`) if `builtin == false`. An "Add command" button appends a blank
    row. A "Reset role to defaults" button reverts that role to the built-in
    `@roles` entry.
  - `handle_event("validate", %{"role_key" => rk, "role" => params}, socket)`
    — update the in-memory assign for that role (no persist). This gives live
    feedback without saving.
  - `handle_event("save_role", %{"role_key" => rk, "role" => params}, socket)`
    — refuse if `rk in @protected_keys`; build the updated role map; run
    `Catalog.changeset`; on `:ok` call `TerminalCommands.put_catalog/1`;
    reassign `:roles` from `load/0`; put flash "Saved.". On `{:error,
    changeset}`, reassign the form with errors so the user sees validation
    failures. Use unique DOM ids per form and row (`cmd-list-form-{role}`,
    `cmd-list-row-{role}-{command}`).
  - `handle_event("add_command", %{"role_key" => rk}, socket)` — refuse if
    protected; append a blank user row to the in-memory assign (`builtin:
    false`, key minted once as `cmd-{System.unique_integer([:positive])}` and
    preserved thereafter; `is_default: false`). **Do not persist** — the
    blank row would fail validation. The user fills it in and clicks "Save
    role" to persist.
  - `handle_event("delete_command", %{"role_key" => rk, "command_key" =>
    ck}, socket)` — refuse if protected or row is `builtin: true`; remove
    from the in-memory assign; if the deleted row was `is_default: true`,
    promote the first remaining command to `is_default: true`. **Do not
    persist** — wait for "Save role".
  - `handle_event("reset_role", %{"role_key" => rk}, socket)` — refuse if
    protected; remove the role from the in-memory assign (so built-in
    defaults take over on next save). **Do not persist** — wait for "Save
    role". Show a confirm dialog: "This will remove all your custom commands
    from this role. Continue?"
  - `handle_info({:terminal_commands_updated, catalog}, socket)` — reassign
    `:roles` from the broadcast payload (so if another tab edits the catalog,
    this tab stays in sync).
  - After every successful persist, call
    `BusterClaw.Sentinel.observe(:settings_change,
    "terminal cmd-list edited", %{role: rk, action: action})` so catalog
    edits land on the audit feed.
- **TerminalLive refresh:** `BusterClawWeb.TerminalLive` subscribes to
  `"terminal_commands"` in `mount/3` and handles
  `{:terminal_commands_updated, catalog}` by reassigning
  `:terminal_command_roles` from `menu_roles/0`. This ensures the flyout
  reflects edits immediately, even if the terminal is already open.
- **Forms per AGENTS.md:** every form is `to_form/2`-assigned in the LiveView
  and consumed as `<.form for={@form} id="...">` + `<.input
  field={@form[:field]}>` in the template. Never touch a changeset directly
  in the template.
- **Accessibility:** lock icon has `aria-label="Protected"`. Delete buttons
  have `aria-label="Delete command"`. Each role form has
  `aria-labelledby="{role}-heading"`. Add/reset buttons have descriptive
  `aria-label` attributes.
- **No new migration, no new schema.** The `Catalog` changeset is an
  embedded-only `Ecto.Schema` used purely for validation before
  serialize-to-JSON.

**Files:** `lib/buster_claw_web/live/cmd_list_live.ex` (new),
`lib/buster_claw_web/live/terminal_live.ex` (add PubSub subscribe +
handle_info), `lib/buster_claw_web/router.ex` (one live route),
`lib/buster_claw_web/components/settings_tabs.ex` (one tab entry),
`lib/buster_claw/terminal_commands/catalog.ex` (validation + migration).

**Tests:** `test/buster_claw_web/live/cmd_list_live_test.exs` —
- protected role renders no form fields and no delete/reset buttons
  (`refute has_element?(view, "#cmd-list-form-mailman")`).
- editing a `toolbox` command's text, choosing a different default, and
  `render_submit` persists; reopening the page shows the new text/default;
  `TerminalLive` reflects it (assert the flyout shows the new command).
- `add_command` to `prompts` appends a row in the form (not persisted yet);
  `render_submit` on "Save role" persists; `delete_command` on the new row
  removes it from the form; `render_submit` persists the deletion.
- `delete_command` on a `builtin: true` row is refused server-side.
- `reset_role` on `toolbox` (after confirm) restores the shipped commands on
  next save.
- a forged POST targeting `mailman` is refused server-side.
- validation error (empty `command` field) shows the changeset error in the
  form.

### Phase 1.5 — safety / escape hatches (S)

- **Reset whole catalog:** a "Reset all to defaults" button at the top of the
  page deletes the `"terminal_commands.catalog"` setting entirely, which
  makes `load/0` fall back to `@roles`. Requires a confirm dialog: "This
  will remove all your custom commands and restore the default catalog.
  Continue?"
- **Validation:** ensure `Catalog.changeset` rejects a role with zero
  commands or more than one `is_default: true` command.
- **Confirm dialogs:** `reset_role` and "Reset all" use `data-confirm`
  attributes (browser-native confirm) or a dedicated confirm modal if we want
  better UX.
- **Export/import (optional):** a JSON textarea showing the current document
  for power users to back up or hand-edit. Deferred unless asked.

### Phase 2 — stretch: user-authored role groups (L)

Not in the initial cut. The user asked to "edit the commands and prompts,"
not to add new role groups, so Phase 1 keeps the four non-protected built-in
roles and lets users add/delete commands within them. If we later want users
to create their own role groups (e.g. a "My Flows" group with several
prompts), the persisted shape already supports it — `load/0` appends user-only
roles. The work is purely UI: an "Add role" button + a role-level form
(label, aliases, startup_profile, hidden) + the same protected-key guard.
Defer until someone asks.

---

## Outstanding — to-complete checklist (as of 07-04, not started)

1. **Phase 0** — `TerminalCommands.load/0`, `load/1`, `put_catalog/1` +
   rewire 5 public fns + `Catalog` embedded schema + `migrate/1` (no-op) +
   PubSub broadcast on `put_catalog/1` success.
2. **Phase 0 tests** — empty-merge no-op, protected injection,
   user-role-append order, user-override round-trip, forward-compat (new
   built-in command appears), `Settings` integration.
3. **Phase 1** — `CmdListLive` route + tab entry + LiveView (mount, 5
   handle_events, handle_info for PubSub, render with protected roles
   read-only) + `TerminalLive` PubSub subscribe + handle_info.
4. **Phase 1 tests** — protected refusal, edit/save round-trip, default
   selection, add/delete user row (in-memory then persist), delete-builtin
   refusal, reset_role, forged-protected-key refusal, validation error
   display, live terminal refresh via PubSub.
5. **Phase 1.5** — reset-all button, confirm dialogs, zero-command /
   multiple-default validation.
6. **Sentinel** — `:settings_change` category entry for catalog edits
   (extend `classify/2` in `sentinel.ex` to map `:settings_change` to
   `:notice` severity).
7. **Quality gate** — `mix precommit` clean; `mix lint` clean; verify the
   existing `terminal_commands_test.exs` and `terminal_live_test.exs` still
   pass unchanged (the merge must be a no-op on an empty user catalog).

## Decisions needed from Luke

- **Delete semantics for built-in non-protected commands:** this roadmap keeps
  built-in non-protected commands editable-but-not-deletable. Good default?
- **Prompts multiline editing:** the `prompts` role's `skills-methodology`
  command is a long multiline string. Render as `<.input type="textarea">`?
- **Audit severity for catalog edits:** proposing `:notice` (a settings
  change). Want `:warning` instead because it changes what the terminal will
  run?
- **Reset scope:** per-role reset button + a top-level "Reset all to
  defaults" is the default here. OK?
- **`reset_role` semantics:** should it remove user-added commands (current
  plan) or keep them and only reset built-in commands?
