defmodule BusterClaw.TerminalCommands do
  @moduledoc """
  Whitelisted role-specific CLI commands for visible terminal sessions.

  The shipped catalog lives in `@roles`. A user catalog — overrides and
  additions for the non-protected roles — persists as one JSON document in
  `BusterClaw.Settings` (key `"terminal_commands.catalog"`) and is merged over
  the built-ins at read time by `load/1`, so every consumer (the terminal
  menu, startup-profile validation, the CLI) sees the same view.

  Two roles are **protected** and can never be customized: `mailman` (the On
  Duty verbs the orchestrator's kill switch, crash-loop brake, and per-shift
  run cap depend on) and `agent-setup` (the Setup wizard's install path).
  `load/1` drops them from any persisted document and re-injects the shipped
  entries, and `Catalog` refuses to persist them — the safety surface is not a
  user preference.

  This catalog feeds terminal startup profiles and the terminal-only Commands
  menu, so neither surface accepts arbitrary shell text: edits pass the
  `Catalog` changeset (slug keys, single-line shell commands) before they are
  stored.
  """

  require Logger

  alias BusterClaw.Library.Artifact
  alias BusterClaw.Settings
  alias BusterClaw.TerminalCommands.Catalog
  alias BusterClaw.TerminalCommands.Command
  alias BusterClaw.TerminalCommands.RoleEdit

  # File-first storage: the catalog the terminal cmd-list dropdown reads lives
  # in the workspace as `<workspace>/cmd-list/catalog.json` (git-diffable,
  # operator-editable, no recompile — like `skills/`, `shaders/`, and the
  # `buster-claw` launcher). `ensure/0` seeds it with the full shipped defaults;
  # protected roles are still enforced from code, never from the file.
  @subdir "cmd-list"
  @catalog_file "catalog.json"
  @roster "README.md"
  # Where the user catalog lived before it moved into the workspace; read once
  # by `ensure/0` to migrate an existing edit, then deleted.
  @legacy_settings_key "terminal_commands.catalog"
  @topic "terminal_commands"
  @protected_keys ["mailman", "agent-setup"]

  @roles [
    %{
      key: "agent-setup",
      label: "Install Claude Code",
      aliases: ["claude-setup", "install-claude"],
      startup_profile: "agent-setup",
      # Kept resolvable (the Setup wizard's install button + startup-profile
      # validation rely on it), but hidden from the terminal command menu.
      hidden: true,
      commands: [
        %{
          key: "install-claude",
          label: "Install Claude Code",
          description: "Install the Claude Code CLI with Homebrew.",
          command: "brew install --cask claude-code",
          default?: true
        }
      ]
    },
    %{
      key: "mailman",
      label: "On Duty",
      aliases: ["mail-triage", "gmail-poller", "on-duty", "off-duty", "shift", "on-shift", "duty"],
      startup_profile: "mailman",
      commands: [
        %{
          key: "on-duty",
          label: "Go On Duty",
          description:
            "Open an unattended shift AND watch Gmail: the agent works the queue and replies in-thread to trusted-sender requests under the per-shift run cap + kill-switch + no-sleep. Ctrl-C stands down.",
          command: "./buster-claw on-duty",
          default?: true
        },
        %{
          key: "on-duty-minute",
          label: "Go On Duty — Poll Every Minute",
          description: "Same, with a 60-second Gmail poll cadence.",
          command: "./buster-claw on-duty --interval 60"
        },
        %{
          key: "off-duty",
          label: "Off Duty",
          description: "Stand down — end the active shift (the Dispatcher stops pumping).",
          command: "./buster-claw off-duty"
        },
        %{
          key: "shift-status",
          label: "Shift Status",
          description: "Whether a shift is active, its mode, and dispatched/done/failed counts.",
          command: "./buster-claw shift status"
        }
      ]
    },
    %{
      key: "queue",
      label: "Dispatch Queue",
      aliases: ["dispatch-queue", "queue"],
      startup_profile: "queue",
      commands: [
        %{
          key: "dispatch-list",
          label: "List Queue",
          description: "Show the open Dispatch items (queued / claimed / running).",
          command: "./buster-claw dispatch list"
        },
        %{
          key: "dispatch-claim",
          label: "Claim Next",
          description: "Claim the oldest single-strategy item to work it.",
          command: "./buster-claw dispatch claim"
        },
        %{
          key: "dispatch-strategy-swarm",
          label: "Mark Item → Swarm",
          description:
            "Opt a queued item into the parallel coordinator (it decomposes into role-typed sub-runs). Replace <id> with the item id from `dispatch list`.",
          command: "./buster-claw dispatch strategy <id> swarm"
        }
      ]
    },
    %{
      key: "toolbox",
      label: "Commands",
      aliases: ["surface", "toolbox"],
      startup_profile: "toolbox",
      commands: [
        %{
          key: "commands-list",
          label: "List Commands",
          description: "Print the full command surface, including runtime skills ([skill]).",
          command: "./buster-claw commands"
        },
        %{
          key: "runtime-status",
          label: "Runtime Status",
          description: "Quick health/status snapshot of the running app.",
          command: "./buster-claw run runtime_status"
        },
        %{
          key: "memory-search",
          label: "Search Memory",
          description:
            "Recall past run summaries by full-text query. Edit the query text before running.",
          command: ~s(./buster-claw run memory_search --json '{"query":"shift"}')
        }
      ]
    },
    %{
      key: "prompts",
      label: "Prompts",
      aliases: ["prompt"],
      startup_profile: "prompts",
      # One static default prompt; a prompt per enabled skill is synthesized
      # from the `skills/` folder at display time (see `skill_prompt_commands/0`
      # and `with_skill_prompts/1`), so the Prompts flyout tracks the folder
      # with no recompile and no restated rows here.
      commands: [
        %{
          key: "welcome-introduction",
          command: "Welcome to Buster Claw. Please read the introduction.",
          kind: :prompt,
          default?: true
        }
      ]
    }
  ]

  # ---- Shipped catalog + protection model ---------------------------------

  @doc "The shipped, compile-time catalog (pre-merge)."
  def builtin_roles, do: @roles

  @doc "Find a shipped role by exact key (aliases don't count here)."
  def builtin_role(key), do: Enum.find(@roles, &(&1.key == key))

  @doc "Role keys that can never be customized (the shift safety surface)."
  def protected_keys, do: @protected_keys

  @doc "Whether a role key is protected from customization."
  def protected?(key), do: key in @protected_keys

  # ---- Merged catalog (what every consumer reads) --------------------------

  @doc """
  Return every terminal role command group, including menu-hidden ones. The
  `prompts` role is augmented at read time with one generated prompt per enabled
  skill (`with_skill_prompts/1`); those synthesized rows never touch the
  persisted file.
  """
  def roles, do: load() |> with_skill_prompts()

  @doc """
  Roles to surface in the terminal command menu — everything except those flagged
  `hidden: true` (which stay resolvable for startup profiles but aren't listed).
  """
  def menu_roles, do: Enum.reject(roles(), &Map.get(&1, :hidden, false))

  @doc """
  One synthesized `prompts` command per enabled skill (`Skills.list/0`),
  generated at read time — never persisted, so it can't drift from `skills/*.md`.
  Composition skills get a "run it" prompt; reference skills get a "read + do the
  task" prompt. Each carries `generated: true`.
  """
  def skill_prompt_commands do
    BusterClaw.Skills.list() |> Enum.map(&skill_prompt_command/1)
  rescue
    # Skills folder unreadable → no synthesized prompts (the static default stays).
    _error -> []
  end

  # Append the synthesized skill prompts to the `prompts` role, skipping any key
  # a persisted/built-in row already owns (so a user's own `skill-<name>` row
  # shadows the generated one — a zero-UI override).
  defp with_skill_prompts(roles) do
    synthesized = skill_prompt_commands()

    Enum.map(roles, fn role ->
      if role.key == "prompts" do
        owned = MapSet.new(role.commands, & &1.key)
        extra = Enum.reject(synthesized, &MapSet.member?(owned, &1.key))
        %{role | commands: role.commands ++ extra}
      else
        role
      end
    end)
  end

  defp skill_prompt_command(%{name: name, description: description, handler_kind: kind}) do
    %{
      key: "skill-#{name}",
      label: "Skill — #{humanize_key(name)}",
      description: description,
      command: skill_prompt_text(kind, name),
      kind: :prompt,
      default?: false,
      builtin: false,
      generated: true
    }
  end

  defp skill_prompt_text(:composition, name) do
    "Run the #{name} skill. First read skills/#{name}.md to confirm it's enabled and see its " <>
      "declared args, gather any inputs it needs from me, then run it with " <>
      "`./buster-claw run #{name} --json '{…}'` and report the result back to me."
  end

  defp skill_prompt_text(_reference, name) do
    "Read the #{name} skill (skills/#{name}.md) in full, then carry out the task it describes, " <>
      "following its steps and producing the artifact it asks for."
  end

  @doc "Find a role by key or alias."
  def role(key) when is_binary(key) do
    normalized = normalize_key(key)

    Enum.find(roles(), fn role ->
      normalized == role.key or normalized in role.aliases
    end)
  end

  def role(_key), do: nil

  @doc "Return the startup profile for a role key or alias."
  def startup_profile_for_role(role_key) do
    case role(role_key) do
      %{startup_profile: startup_profile} -> startup_profile
      nil -> nil
    end
  end

  @doc "Return the default startup command for a startup profile."
  def startup_command(profile) when is_binary(profile) do
    Enum.find_value(roles(), fn role ->
      if role.startup_profile == profile do
        role.commands
        |> Enum.find(&Map.get(&1, :default?, false))
        |> case do
          %{command: command} -> command
          nil -> nil
        end
      end
    end)
  end

  def startup_command(_profile), do: nil

  # ---- Loading + merging ----------------------------------------------------

  @doc "Load the merged catalog from the persisted user document."
  def load, do: load(user_doc())

  @doc """
  Merge a decoded (string-keyed) user document — or `nil` — over the shipped
  catalog. Pure; this is the test seam.

  Semantics: protected roles are dropped from the user document (defense in
  depth against direct `Settings` writes) and re-injected from the built-ins;
  user edits win on a built-in command's label/description/command; built-in
  commands absent from the document still appear (new app versions ship new
  commands even into edited roles); user-added commands and user-only roles
  append at the end.
  """
  def load(user_doc) do
    doc = Catalog.migrate(user_doc)

    user_roles =
      case doc do
        %{"roles" => roles} when is_list(roles) -> Enum.filter(roles, &valid_doc_role?/1)
        _other -> []
      end

    by_key = Map.new(user_roles, &{&1["key"], &1})
    builtin_keys = Enum.map(@roles, & &1.key)

    merged =
      Enum.map(@roles, fn role ->
        if role.key in @protected_keys do
          normalize_builtin_role(role, true)
        else
          merge_role(role, by_key[role.key])
        end
      end)

    user_only =
      user_roles
      |> Enum.reject(&(&1["key"] in builtin_keys))
      |> Enum.map(&normalize_user_role/1)
      |> Enum.reject(&is_nil/1)

    merged ++ user_only
  end

  # ---- File-first workspace storage ------------------------------------------

  @doc "Absolute path to the cmd-list folder in the current workspace."
  def dir, do: Artifact.workspace_path(@subdir)

  @doc "Absolute path to the catalog file the terminal dropdown reads."
  def catalog_path, do: Path.join(dir(), @catalog_file)

  @doc "The PubSub topic catalog updates broadcast on."
  def topic, do: @topic

  @doc "Subscribe the calling process to `{:terminal_commands_updated, roles}`."
  def subscribe, do: Phoenix.PubSub.subscribe(BusterClaw.PubSub, @topic)

  @doc """
  Seed the `cmd-list/` folder: a README plus `catalog.json` holding the full
  shipped defaults (so the folder shows every editable command). Never
  overwrites an existing catalog; migrates a pre-existing Settings-stored
  catalog into the file once. Best-effort — never raises (used at boot).
  """
  def ensure do
    File.mkdir_p!(dir())
    maybe_write(roster_path(), default_roster())

    unless File.exists?(catalog_path()) do
      doc = migrate_legacy_catalog() || default_catalog_doc()
      write_catalog(doc)
    end

    :ok
  rescue
    error ->
      Logger.warning("TerminalCommands.ensure failed: #{Exception.message(error)}")
      :error
  end

  @doc """
  Validate and persist the full catalog document (string-keyed map) to the
  workspace file, then broadcast the merged catalog. Returns `:ok` or
  `{:error, changeset}`.
  """
  def put_catalog(doc) when is_map(doc) do
    with {:ok, normalized} <- Catalog.validate(doc),
         :ok <- write_catalog(normalized) do
      broadcast_update()
      :ok
    end
  end

  @doc "Restore the catalog file to the shipped defaults (every role reset)."
  def reset_catalog do
    write_catalog(default_catalog_doc())
    broadcast_update()
    :ok
  end

  defp roster_path, do: Path.join(dir(), @roster)

  defp write_catalog(doc) do
    File.mkdir_p!(dir())

    case File.write(catalog_path(), Jason.encode!(doc, pretty: true)) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp maybe_write(path, content) do
    unless File.exists?(path), do: File.write(path, content)
  end

  # Serialize the shipped non-protected roles to the full file shape so the
  # seeded catalog.json lists every editable command (not a sparse diff).
  # Protected roles are omitted — they are re-injected from code at load time.
  defp default_catalog_doc do
    roles =
      @roles
      |> Enum.reject(&(&1.key in @protected_keys))
      |> Enum.map(&serialize_builtin_role/1)

    %{"version" => Catalog.version(), "roles" => roles}
  end

  defp serialize_builtin_role(role) do
    default_key = Enum.find_value(role.commands, fn c -> if Map.get(c, :default?), do: c.key end)

    commands =
      Enum.map(role.commands, fn c ->
        %{"key" => c.key, "command" => c.command, "kind" => to_string(Map.get(c, :kind, :shell))}
        |> put_present("label", Map.get(c, :label))
        |> put_present("description", Map.get(c, :description))
      end)

    %{"key" => role.key, "commands" => commands}
    |> put_present("default_key", default_key)
  end

  # One-time migration of a pre-file catalog from Settings. Returns a full doc
  # (the old diff expanded over the shipped defaults) or nil when none exists.
  defp migrate_legacy_catalog do
    with json when is_binary(json) <- Settings.get(@legacy_settings_key),
         {:ok, %{} = diff_doc} <- Jason.decode(json) do
      full = full_doc_from_roles(load(diff_doc))
      Settings.delete(@legacy_settings_key)
      full
    else
      _ -> nil
    end
  rescue
    # Settings unreachable (e.g. no Repo yet) → skip migration, seed defaults.
    _error -> nil
  end

  # Serialize merged runtime roles back into the full file shape (non-protected
  # only). Used to expand a migrated diff into a complete catalog file.
  defp full_doc_from_roles(runtime_roles) do
    roles =
      runtime_roles
      |> Enum.reject(&(&1.key in @protected_keys))
      |> Enum.map(fn role ->
        default_key = Enum.find_value(role.commands, fn c -> if c.default?, do: c.key end)

        commands =
          Enum.map(role.commands, fn c ->
            %{"key" => c.key, "command" => c.command, "kind" => to_string(c.kind)}
            |> put_present("label", c.label)
            |> put_present("description", c.description)
          end)

        %{"key" => role.key, "commands" => commands}
        |> put_present("default_key", default_key)
      end)

    %{"version" => Catalog.version(), "roles" => roles}
  end

  @doc "Remove one role's customizations, restoring its shipped commands."
  def reset_role(role_key) when is_binary(role_key) do
    if protected?(role_key) do
      {:error, :protected}
    else
      roles =
        current_doc_roles()
        |> Enum.reject(&(&1["key"] == role_key))

      put_catalog(%{"version" => Catalog.version(), "roles" => roles})
    end
  end

  # ---- Editing ---------------------------------------------------------------

  @doc """
  Build the editor base for a non-protected role: the full merged command list
  as a `RoleEdit` struct. Returns `nil` for protected or unknown roles.
  """
  def role_edit(role_key) when is_binary(role_key) do
    case Enum.find(load(), &(&1.key == role_key)) do
      %{protected: false} = role ->
        %RoleEdit{
          key: role.key,
          default_key: Enum.find_value(role.commands, fn c -> if c.default?, do: c.key end),
          commands:
            Enum.map(role.commands, fn c ->
              %Command{
                id: Ecto.UUID.generate(),
                key: c.key,
                label: c.label,
                description: c.description,
                command: c.command,
                kind: Atom.to_string(c.kind),
                builtin: c.builtin
              }
            end)
        }

      _other ->
        nil
    end
  end

  def role_edit(_role_key), do: nil

  @doc """
  Apply editor params to a `RoleEdit` base, compute the diff against the
  shipped catalog, and persist it. New rows get server-minted keys. Returns
  `{:ok, %{commands_changed: boolean}}` (whether what the terminal would run
  changed — commands or default, not just labels), `{:error, changeset}`, or
  `{:error, :protected}`.
  """
  def save_role_edit(%RoleEdit{key: role_key} = base, params) do
    if protected?(role_key) do
      {:error, :protected}
    else
      case Ecto.Changeset.apply_action(RoleEdit.changeset(base, params), :update) do
        {:ok, edit} -> persist_role_edit(role_key, edit)
        {:error, changeset} -> {:error, changeset}
      end
    end
  end

  @doc """
  Agent-facing single-command upsert for a non-protected role — the programmatic
  equivalent of editing one row in Settings → cmd-list. `attrs` (string keys):
  `"role_key"` + `"command_key"` are required; optional `"command"` (the
  command/prompt text), `"label"`, `"description"`. Editing an existing command
  overrides only the fields supplied; an unknown `command_key` carrying a
  `"command"` adds a new user command (its `kind` is inferred — `prompt` for the
  `prompts` role or multiline text, else `shell`).

  Goes through the same diff → `Catalog` validation → persist → broadcast path as
  the UI, so the terminal flyout refreshes live and On Duty (`mailman`/
  `agent-setup`) roles are refused. Returns `{:ok, %{commands_changed: boolean}}`
  (whether what the terminal would run changed), `{:error, :protected |
  :not_found | :missing_command}`, or `{:error, %Ecto.Changeset{}}`.
  """
  def set_command(attrs) when is_map(attrs) do
    role_key = string_arg(attrs, "role_key")
    command_key = string_arg(attrs, "command_key")

    cond do
      is_nil(role_key) or is_nil(command_key) ->
        {:error, :not_found}

      protected?(role_key) ->
        {:error, :protected}

      true ->
        case role_edit(role_key) do
          nil ->
            {:error, :not_found}

          %RoleEdit{commands: commands} = base ->
            case upsert_command(commands, role_key, command_key, command_fields(attrs)) do
              {:ok, commands} -> persist_role_edit(role_key, %{base | commands: commands})
              {:error, reason} -> {:error, reason}
            end
        end
    end
  end

  def set_command(_attrs), do: {:error, :not_found}

  defp upsert_command(commands, role_key, command_key, fields) do
    case Enum.find_index(commands, &(&1.key == command_key)) do
      nil ->
        case Map.get(fields, :command) do
          text when is_binary(text) and text != "" ->
            new = %Command{
              id: Ecto.UUID.generate(),
              key: command_key,
              label: Map.get(fields, :label),
              description: Map.get(fields, :description),
              command: text,
              kind: infer_kind(role_key, text),
              builtin: false
            }

            {:ok, commands ++ [new]}

          _ ->
            {:error, :missing_command}
        end

      index ->
        updated =
          commands
          |> Enum.at(index)
          |> apply_command_fields(fields)

        {:ok, List.replace_at(commands, index, updated)}
    end
  end

  defp apply_command_fields(%Command{} = command, fields) do
    %Command{
      command
      | command: Map.get(fields, :command, command.command),
        label: Map.get(fields, :label, command.label),
        description: Map.get(fields, :description, command.description)
    }
  end

  # Only the keys actually supplied end up in the field map, so an absent field
  # keeps its current value; a supplied blank label/description clears it.
  defp command_fields(attrs) do
    %{}
    |> put_field(attrs, "command", :command)
    |> put_field(attrs, "label", :label)
    |> put_field(attrs, "description", :description)
  end

  defp put_field(fields, attrs, str_key, atom_key) do
    case Map.fetch(attrs, str_key) do
      {:ok, value} when is_binary(value) -> Map.put(fields, atom_key, blank_to_nil(value))
      _ -> fields
    end
  end

  defp infer_kind("prompts", _text), do: "prompt"

  defp infer_kind(_role_key, text) do
    if String.contains?(text, "\n"), do: "prompt", else: "shell"
  end

  defp string_arg(attrs, key) do
    case Map.get(attrs, key) do
      value when is_binary(value) -> blank_to_nil(value)
      _ -> nil
    end
  end

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank_to_nil(_value), do: nil

  # ---- Private: persistence helpers ------------------------------------------

  defp persist_role_edit(role_key, %RoleEdit{} = edit) do
    before_snapshot = execution_snapshot(role_key)
    entry = role_entry(role_key, edit)
    existing = current_doc_roles()

    roles =
      if Enum.any?(existing, &(&1["key"] == role_key)) do
        Enum.flat_map(existing, fn role ->
          if role["key"] == role_key, do: List.wrap(entry), else: [role]
        end)
      else
        existing ++ List.wrap(entry)
      end

    case put_catalog(%{"version" => Catalog.version(), "roles" => roles}) do
      :ok -> {:ok, %{commands_changed: before_snapshot != execution_snapshot(role_key)}}
      {:error, _reason} = error -> error
    end
  end

  # The persisted entry for one role — the FULL role (every command with its
  # fields), so the workspace `catalog.json` always shows the complete list
  # rather than a sparse diff. New rows get server-minted keys.
  defp role_entry(role_key, %RoleEdit{} = edit) do
    taken = MapSet.new(Enum.map(edit.commands, & &1.key) |> Enum.reject(&is_nil/1))

    {commands, _taken} =
      Enum.map_reduce(edit.commands, taken, fn c, taken ->
        key = c.key || mint_key(taken)

        entry =
          %{"key" => key, "command" => c.command, "kind" => c.kind}
          |> put_present("label", c.label)
          |> put_present("description", c.description)

        {entry, MapSet.put(taken, key)}
      end)

    %{"key" => role_key, "commands" => commands}
    |> put_present("default_key", edit.default_key)
  end

  # What the terminal would actually run for a role: command strings + the
  # startup default. Label/description edits don't count.
  defp execution_snapshot(role_key) do
    case Enum.find(load(), &(&1.key == role_key)) do
      nil -> nil
      role -> Enum.map(role.commands, &{&1.key, &1.command, &1.default?})
    end
  end

  defp current_doc_roles do
    case Catalog.migrate(user_doc()) do
      %{"roles" => roles} when is_list(roles) -> Enum.filter(roles, &valid_doc_role?/1)
      _other -> []
    end
  end

  defp user_doc do
    case File.read(catalog_path()) do
      {:ok, json} ->
        case Jason.decode(json) do
          {:ok, %{} = doc} ->
            doc

          _other ->
            Logger.warning("terminal_commands: #{@catalog_file} is corrupt, using built-ins")
            nil
        end

      # No file yet (fresh workspace before `ensure/0` runs) → built-ins.
      {:error, _reason} ->
        nil
    end
  rescue
    # The catalog is a safety surface: if the workspace is unreachable, serve
    # the built-ins rather than fail closed.
    _error -> nil
  end

  defp default_roster do
    """
    # Terminal cmd-list

    `catalog.json` is the command cheatsheet the in-app terminal shows in its
    **cmd-list** dropdown, and the whitelist for `terminal open --role <key>`
    startup profiles. It is read live — edit it (or use Settings → Cmd List) and
    the dropdown updates with no recompile.

    Shape: `{"version": 1, "roles": [{"key", "commands": [{"key", "label",
    "description", "command", "kind"}], "default_key"}]}`. `kind` is `"shell"`
    (single-line, typed into the PTY) or `"prompt"` (may be multiline). Edits are
    validated before they take effect (slug keys, single-line shell commands).

    The **On Duty** roles (`mailman`, `agent-setup`) are the shift-safety surface
    and are enforced from code — they never appear here and can't be overridden
    from this file. Delete `catalog.json` to restore the shipped defaults on the
    next launch. Prompt entries are also generated from your `skills/` folder.
    """
  end

  defp broadcast_update do
    Phoenix.PubSub.broadcast(BusterClaw.PubSub, @topic, {:terminal_commands_updated, load()})
  end

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  defp mint_key(taken) do
    key = "cmd-" <> Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)
    if MapSet.member?(taken, key), do: mint_key(taken), else: key
  end

  # ---- Private: merge helpers -------------------------------------------------

  defp valid_doc_role?(%{"key" => key}) when is_binary(key) do
    String.match?(key, Command.key_format()) and not protected?(key)
  end

  defp valid_doc_role?(_role), do: false

  defp merge_role(builtin, nil), do: normalize_builtin_role(builtin, false)

  defp merge_role(builtin, user) do
    base = normalize_builtin_role(builtin, false)
    user_cmds = normalize_user_commands(user["commands"])
    overrides = Map.new(user_cmds, &{&1.key, &1})
    builtin_keys = MapSet.new(base.commands, & &1.key)

    merged =
      Enum.map(base.commands, fn c ->
        case overrides[c.key] do
          nil ->
            c

          # User wins on label/description/command; kind, builtin, and
          # default? stay authoritative from the shipped catalog. An override
          # that would put a multiline command into a shell row (only possible
          # via a direct Settings write — the changeset refuses it) reverts to
          # the shipped row.
          o ->
            candidate = %{c | label: o.label, description: o.description, command: o.command}
            if multiline_shell?(candidate), do: c, else: candidate
        end
      end)

    added =
      user_cmds
      |> Enum.reject(&MapSet.member?(builtin_keys, &1.key))
      |> Enum.reject(&multiline_shell?/1)

    %{base | commands: apply_default(merged ++ added, user["default_key"])}
  end

  defp normalize_builtin_role(role, protected?) do
    %{
      key: role.key,
      label: role.label,
      aliases: role.aliases,
      startup_profile: role.startup_profile,
      hidden: Map.get(role, :hidden, false),
      protected: protected?,
      commands: Enum.map(role.commands, &normalize_builtin_command/1)
    }
  end

  defp normalize_builtin_command(command) do
    %{
      key: command.key,
      label: Map.get(command, :label),
      description: Map.get(command, :description),
      command: command.command,
      kind: Map.get(command, :kind, :shell),
      default?: Map.get(command, :default?, false),
      builtin: true,
      generated: false
    }
  end

  # User-only roles (a Phase 2 surface, but the merge already honors them).
  defp normalize_user_role(user) do
    commands =
      user["commands"]
      |> normalize_user_commands()
      |> Enum.reject(&multiline_shell?/1)
      |> apply_default(user["default_key"])

    if commands == [] do
      nil
    else
      %{
        key: user["key"],
        label: humanize_key(user["key"]),
        aliases: [],
        startup_profile: nil,
        hidden: false,
        protected: false,
        commands: commands
      }
    end
  end

  defp normalize_user_commands(commands) when is_list(commands) do
    commands
    |> Enum.map(&normalize_user_command/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq_by(& &1.key)
  end

  defp normalize_user_commands(_commands), do: []

  defp normalize_user_command(%{"key" => key, "command" => command} = cmd)
       when is_binary(key) and is_binary(command) do
    if String.match?(key, Command.key_format()) and String.trim(command) != "" do
      %{
        key: key,
        label: str_or_nil(cmd["label"]),
        description: str_or_nil(cmd["description"]),
        command: command,
        kind: parse_kind(cmd["kind"]),
        default?: false,
        builtin: false,
        generated: false
      }
    end
  end

  defp normalize_user_command(_cmd), do: nil

  defp apply_default(commands, default_key) do
    if is_binary(default_key) and Enum.any?(commands, &(&1.key == default_key)) do
      Enum.map(commands, &%{&1 | default?: &1.key == default_key})
    else
      commands
    end
  end

  defp multiline_shell?(%{kind: :shell, command: command}) when is_binary(command),
    do: String.match?(command, ~r/[\r\n]/)

  defp multiline_shell?(_command), do: false

  defp parse_kind("prompt"), do: :prompt
  defp parse_kind(_kind), do: :shell

  defp str_or_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp str_or_nil(_value), do: nil

  defp humanize_key(key) do
    key
    |> String.split("-")
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  defp normalize_key(value) do
    value
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9_-]+/, "-")
    |> String.trim("-")
  end
end
