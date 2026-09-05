defmodule BusterClaw.TerminalCommands do
  @moduledoc """
  Whitelisted role-specific CLI commands for visible terminal sessions.

  The shipped catalog lives in `Builtins`. A user catalog — overrides and
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

  # ---- Shipped catalog + protection model ---------------------------------

  # The shipped catalog and the protection model live in `Builtins` (a leaf —
  # extracted 08-02 so the catalog submodules stop reaching back into this
  # facade, which was a dependency cycle). Delegates keep the public surface.
  defdelegate builtin_roles, to: BusterClaw.TerminalCommands.Builtins
  defdelegate builtin_role(key), to: BusterClaw.TerminalCommands.Builtins
  defdelegate protected_keys, to: BusterClaw.TerminalCommands.Builtins
  defdelegate protected?(key), to: BusterClaw.TerminalCommands.Builtins

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
    builtin_keys = Enum.map(builtin_roles(), & &1.key)

    merged =
      Enum.map(builtin_roles(), fn role ->
        if protected?(role.key) do
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
      builtin_roles()
      |> Enum.reject(&protected?(&1.key))
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
      |> Enum.reject(&protected?(&1.key))
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

  # ---- Editing: REMOVED 09-05 ------------------------------------------------
  #
  # The Settings → Cmd List page and the `terminal_command_set` verb were the
  # only two ways to write here, and both are gone (operator: "I don't want us
  # to be having this version of changing commands for our app anymore" — skills
  # are how new commands get made now).
  #
  # What is left is a READ path, and deliberately so. The merge below still
  # applies a `terminal_commands.catalog` document an earlier version wrote, so
  # an operator who customised their terminal menu keeps those commands; nothing
  # can write a new one. The same posture as `sketches/` — stop offering the
  # feature, do not reach into somebody's data to erase it.
  #
  # If a later pass confirms no install carries a customised document, the whole
  # user-document layer below collapses to `Builtins` and this module halves.

  # ---- Private: persistence helpers ------------------------------------------

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
      Enum.reject(
        user_cmds,
        &(MapSet.member?(builtin_keys, &1.key) or multiline_shell?(&1))
      )

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
