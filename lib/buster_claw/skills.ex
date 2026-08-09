defmodule BusterClaw.Skills do
  @moduledoc """
  Composition skills — the runtime-addable layer of the command surface.

  A skill is one markdown file at `<workspace>/skills/<name>.md`. There are two
  kinds (`handler_kind`):

  - **composition** — its `steps` are an ordered list of *existing native
    commands*; it owns no new capability, only new sequencing, and every step is
    re-authorised through `Commands.call/3` so a skill can never exceed its
    caller's trust.
  - **reference** — a playbook the agent *reads* (no steps; the markdown body is
    the payload) to do an authoring task the command surface doesn't cover, e.g.
    designing a homepage shader pattern. Reference skills are discoverable via
    `list/0` but are NOT in the runnable catalog (`catalog_entries/0`).

  Skills are discovered at runtime (no recompile), exactly like job descriptions
  (`BusterClaw.Jobs`) and trusted senders — file-first, git-diffable,
  operator-editable.

  This module only *loads and validates* skill files. Resolution, per-step
  authorization, and execution live in `BusterClaw.Commands` (the single dispatch
  choke point): every step is dispatched back through `Commands.call/3` as the
  same caller, so the catalog's tier/gated rules apply per step and a skill can
  never exceed its invoker's trust.

  ## Frontmatter schema (S0.2)

      ---
      name: save-note                       # must equal the filename stem ([a-z0-9-])
      description: Save a quick note.        # what / when to use
      tier: restricted                       # safe | restricted (declared ceiling)
      enabled: true                          # default false — a skill only runs when true
      handler_kind: composition              # the only kind supported today
      args: {"title": {"type":"string"}}     # JSON map of inputs
      steps: [{"command":"document_save","args":{"name":"$title","body":"$body"}}]
      ---

  Load guards (S0.5 threat model): `enabled` defaults false; only `composition`
  handlers are accepted; the name must match `[a-z0-9-]` and the filename stem;
  `steps` must be a non-empty flat list of `{command, args}` within `max_steps`.
  """
  require Logger

  alias BusterClaw.Library.{Artifact, Frontmatter}

  @subdir "skills"
  @roster "README.md"

  def dir, do: Artifact.workspace_path(@subdir)
  def roster_path, do: Path.join(dir(), @roster)
  defp skill_path(name), do: Path.join(dir(), name <> ".md")

  @doc "All enabled, valid skills as summaries (`name`/`description`/`tier`), sorted."
  def list do
    enabled_skills() |> Enum.map(&summary/1) |> Enum.sort_by(& &1.name)
  end

  @doc """
  Catalog entries for enabled **composition** skills, shaped like native command
  entries but marked `source: :composition` so the catalog stays auditable.
  Reference skills are excluded — they are read, not run, so they never enter the
  runnable command surface.
  """
  def catalog_entries do
    enabled_skills()
    |> Enum.filter(&(&1.handler_kind == :composition))
    |> Enum.map(&catalog_entry/1)
  end

  @doc """
  Fetch an enabled, **runnable** (composition) skill by name for execution.
  Returns `{:ok, skill}` or `:error`. Disabled, invalid, and **reference** skills
  are all non-resolvable here — that is the enable gate from the threat model plus
  the run/read split (a reference skill is read via `load/1`, never run).
  """
  def fetch(name) when is_binary(name) do
    case load(name) do
      {:ok, %{enabled: true, handler_kind: :composition} = skill} -> {:ok, skill}
      _ -> :error
    end
  end

  def fetch(_name), do: :error

  @doc """
  Load and validate a skill file (enabled or not). Returns `{:ok, skill}`,
  `{:error, reason}` for a malformed file, or `nil` when no file exists.
  """
  def load(name) when is_binary(name) do
    case File.read(skill_path(name)) do
      {:ok, content} ->
        %{fields: fields, body: body} = Frontmatter.split(content)

        case validate(name, fields, body) do
          {:ok, _skill} = ok ->
            ok

          {:error, reason} = err ->
            Logger.warning("Skills: ignoring invalid skill #{inspect(name)} — #{inspect(reason)}")
            err
        end

      _ ->
        nil
    end
  end

  def load(_name), do: nil

  @doc """
  Write an enabled composition skill file from structured attrs (`name`,
  `description`, `tier`, `steps`). Refuses to overwrite an existing file or shadow
  a native command. Returns `{:ok, path}` or `{:error, reason}`. Used by the Phase 3
  approval flow; the format matches what `load/1` parses (single-line JSON `steps`).
  """
  def write(%{name: name, steps: steps} = attrs) do
    cond do
      not Regex.match?(~r/\A[a-z0-9][a-z0-9-]*\z/, to_string(name)) ->
        {:error, :invalid_name}

      File.exists?(skill_path(name)) ->
        {:error, :exists}

      not (is_list(steps) and steps != []) ->
        {:error, :no_steps}

      true ->
        File.mkdir_p!(dir())
        File.write!(skill_path(name), render(attrs))
        {:ok, skill_path(name)}
    end
  end

  defp render(%{name: name, steps: steps} = attrs) do
    tier = attrs |> Map.get(:tier, :restricted) |> to_string()
    description = Map.get(attrs, :description, "") |> to_string()

    """
    ---
    name: #{name}
    description: #{yaml_quote(description)}
    tier: #{yaml_quote(tier)}
    enabled: true
    handler_kind: composition
    steps: #{Jason.encode!(steps)}
    ---

    # #{name}

    #{description}
    """
  end

  # Quote interpolated frontmatter scalars so arbitrary text (a `:` metacharacter,
  # an embedded newline, a quote) can't break the YAML structure or smuggle in
  # extra fields. Newlines collapse to spaces; the escaping matches what
  # `Frontmatter.split/1` unquotes (`\"` and `\\`).
  defp yaml_quote(value) do
    escaped =
      value
      |> to_string()
      |> String.replace("\\", "\\\\")
      |> String.replace("\"", "\\\"")
      |> String.replace(["\r\n", "\n", "\r"], " ")

    ~s("#{escaped}")
  end

  @doc """
  Best-effort seed: create `skills/` with a roster README and one enabled
  example. Never overwrites an existing operator-authored file.
  """
  def ensure do
    File.mkdir_p!(dir())
    maybe_write(roster_path(), default_roster())
    maybe_write(skill_path("save-note"), default_save_note())
    maybe_write(skill_path("shader-designer"), default_shader_designer())
    maybe_write(skill_path("sound-cutup"), default_sound_cutup())
    maybe_write(skill_path("pockets"), default_pockets())
    maybe_write(skill_path("terminal-paint"), default_terminal_paint())
    :ok
  rescue
    error ->
      Logger.warning("Skills.ensure failed: #{Exception.message(error)}")
      :error
  end

  # --- internals ---------------------------------------------------------

  defp enabled_skills do
    case File.ls(dir()) do
      {:ok, entries} ->
        entries
        |> Enum.filter(&skill_file?/1)
        |> Enum.flat_map(fn entry ->
          case entry |> Path.rootname() |> load() do
            {:ok, %{enabled: true} = skill} -> [skill]
            _ -> []
          end
        end)

      _ ->
        []
    end
  end

  defp validate(name, fields, body) do
    with :ok <- validate_name(name, fields),
         {:ok, kind} <- validate_kind(fields),
         {:ok, steps} <- validate_steps(kind, fields, body) do
      {:ok,
       %{
         name: name,
         description: description(fields, body),
         tier: tier(fields),
         enabled: fields["enabled"] == true,
         handler_kind: kind,
         args: args(fields),
         steps: steps,
         body: body
       }}
    end
  end

  defp validate_name(name, fields) do
    cond do
      not Regex.match?(~r/\A[a-z0-9][a-z0-9-]*\z/, name) -> {:error, :invalid_name}
      is_binary(fields["name"]) and fields["name"] != name -> {:error, :name_mismatch}
      true -> :ok
    end
  end

  defp validate_kind(fields) do
    case fields["handler_kind"] || "composition" do
      "composition" -> {:ok, :composition}
      "reference" -> {:ok, :reference}
      other -> {:error, {:unsupported_handler_kind, other}}
    end
  end

  # Composition skills carry an ordered step list. Reference skills carry none —
  # they are playbooks the agent *reads*, so the markdown body is the payload and
  # steps are neither expected nor run.
  defp validate_steps(:reference, _fields, body) do
    if present(body), do: {:ok, []}, else: {:error, :empty_reference}
  end

  defp validate_steps(:composition, fields, _body) do
    steps = fields["steps"]

    cond do
      not is_list(steps) or steps == [] -> {:error, :no_steps}
      length(steps) > max_steps() -> {:error, :too_many_steps}
      not Enum.all?(steps, &valid_step?/1) -> {:error, :invalid_step}
      true -> {:ok, steps}
    end
  end

  defp valid_step?(%{"command" => command} = step) when is_binary(command) do
    case Map.get(step, "args") do
      nil -> true
      args when is_map(args) -> true
      _ -> false
    end
  end

  defp valid_step?(_step), do: false

  defp tier(fields) do
    case fields["tier"] do
      "safe" -> :safe
      _ -> :restricted
    end
  end

  defp args(fields) do
    case fields["args"] do
      args when is_map(args) -> args
      _ -> %{}
    end
  end

  defp description(fields, body) do
    present(fields["description"]) || first_line(body) || ""
  end

  defp catalog_entry(skill) do
    %{
      name: skill.name,
      type: :trigger,
      tier: skill.tier,
      description: skill.description,
      args: skill.args,
      source: :composition
    }
  end

  defp summary(skill), do: Map.take(skill, [:name, :description, :tier, :handler_kind])

  defp skill_file?(name), do: Path.extname(name) == ".md" and name != @roster

  defp max_steps, do: Application.get_env(:buster_claw, :skill_max_steps, 20)

  defp maybe_write(path, content) do
    if File.exists?(path), do: :ok, else: File.write(path, content)
  end

  defp present(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp present(_value), do: nil

  defp first_line(body) do
    body
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.find(&(&1 != "" and not String.starts_with?(&1, "#")))
  end

  # --- seed templates ----------------------------------------------------
  #
  # The seeds live in `skill-seeds/*.md` and are embedded at compile time
  # — the shape `BusterClaw.UserGuide` and `BusterClaw.Introduction` both use.
  # They were 162 lines of heredoc here until 08-08.
  #
  # Keeping them as real `.md` files means the two skill seeds are now the same
  # kind of thing they seed: `save-note.md` and `shader-designer.md` can be read,
  # diffed and validated as skills without being extracted from a string first.
  @seed_dir Path.expand(Path.join([__DIR__, "..", "..", "skill-seeds"]))

  @external_resource Path.join(@seed_dir, "README.md")
  @external_resource Path.join(@seed_dir, "save-note.md")
  @external_resource Path.join(@seed_dir, "shader-designer.md")
  @external_resource Path.join(@seed_dir, "sound-cutup.md")
  @external_resource Path.join(@seed_dir, "pockets.md")
  @external_resource Path.join(@seed_dir, "terminal-paint.md")

  @default_roster File.read!(Path.join(@seed_dir, "README.md"))
  @default_save_note File.read!(Path.join(@seed_dir, "save-note.md"))
  @default_shader_designer File.read!(Path.join(@seed_dir, "shader-designer.md"))
  @default_sound_cutup File.read!(Path.join(@seed_dir, "sound-cutup.md"))
  @default_pockets File.read!(Path.join(@seed_dir, "pockets.md"))
  @default_terminal_paint File.read!(Path.join(@seed_dir, "terminal-paint.md"))

  defp default_roster, do: @default_roster
  defp default_save_note, do: @default_save_note
  defp default_shader_designer, do: @default_shader_designer
  defp default_sound_cutup, do: @default_sound_cutup
  defp default_pockets, do: @default_pockets
  defp default_terminal_paint, do: @default_terminal_paint
end
