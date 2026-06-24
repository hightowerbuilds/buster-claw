defmodule BusterClaw.Skills do
  @moduledoc """
  Composition skills — the runtime-addable layer of the command surface.

  A skill is one markdown file at `<workspace>/skills/<name>.md`. Its `steps` are
  an ordered list of *existing native commands*; a skill owns no new capability,
  only new sequencing. Skills are discovered at runtime (no recompile), exactly
  like job descriptions (`BusterClaw.Jobs`) and trusted senders — file-first,
  git-diffable, operator-editable.

  This module only *loads and validates* skill files. Resolution, per-step
  authorization, and execution live in `BusterClaw.Commands` (the single dispatch
  choke point): every step is dispatched back through `Commands.call/2` as the
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
  def skill_path(name), do: Path.join(dir(), name <> ".md")

  @doc "All enabled, valid skills as summaries (`name`/`description`/`tier`), sorted."
  def list do
    enabled_skills() |> Enum.map(&summary/1) |> Enum.sort_by(& &1.name)
  end

  @doc """
  Catalog entries for enabled skills, shaped like native command entries but
  marked `source: :composition` so the catalog stays auditable.
  """
  def catalog_entries, do: Enum.map(enabled_skills(), &catalog_entry/1)

  @doc """
  Fetch an enabled, valid skill by name. Returns `{:ok, skill}` or `:error`.
  A disabled or invalid skill is non-resolvable (returns `:error`) — that is the
  enable gate from the threat model.
  """
  def fetch(name) when is_binary(name) do
    case load(name) do
      {:ok, %{enabled: true} = skill} -> {:ok, skill}
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
    description = Map.get(attrs, :description, "")

    """
    ---
    name: #{name}
    description: #{description}
    tier: #{tier}
    enabled: true
    handler_kind: composition
    steps: #{Jason.encode!(steps)}
    ---

    # #{name}

    #{description}
    """
  end

  @doc """
  Best-effort seed: create `skills/` with a roster README and one enabled
  example. Never overwrites an existing operator-authored file.
  """
  def ensure do
    File.mkdir_p!(dir())
    maybe_write(roster_path(), default_roster())
    maybe_write(skill_path("save-note"), default_save_note())
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
         {:ok, steps} <- validate_steps(fields) do
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
      other -> {:error, {:unsupported_handler_kind, other}}
    end
  end

  defp validate_steps(fields) do
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

  defp summary(skill), do: Map.take(skill, [:name, :description, :tier])

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

  defp default_roster do
    """
    # Skills

    Composition skills extend Buster Claw's command surface at runtime, with no
    recompile. Each skill is one markdown file here (`<name>.md`) whose `steps`
    are an ordered list of existing native commands.

    ## Frontmatter
    - `name` — must equal the filename stem (`[a-z0-9-]`).
    - `description` — what it does / when to use it.
    - `tier` — `safe` or `restricted` (a declared ceiling; per-step authorization
      still applies, so a skill can never exceed the trust of its caller).
    - `enabled` — `false` by default; a skill only runs when explicitly `true`.
    - `handler_kind` — `composition` (the only kind supported today).
    - `args` — JSON map of the skill's inputs.
    - `steps` — JSON array of `{"command": "<native>", "args": {...}}`, run in order.

    In step args, `$<arg>` interpolates a skill input and `$prior` is the previous
    step's result. Every step is re-checked against the same gating Buster Claw
    applies to a direct command call.
    """
  end

  defp default_save_note do
    """
    ---
    name: save-note
    description: Save a quick note to the Library. Use to capture text as a document.
    metadata: {"version":"1.0.0"}
    tier: restricted
    enabled: true
    handler_kind: composition
    args: {"title":{"type":"string","required":true},"body":{"type":"string","required":true}}
    steps: [{"command":"document_save","args":{"name":"$title","body":"$body"}}]
    ---

    # save-note

    A one-step composition skill: it forwards `$title`/`$body` to the native
    `document_save` command. Run it with:

        ./buster-claw run save-note --json '{"title":"Hello","body":"World"}'

    Skills are ordinary markdown files in this folder. A skill only runs when
    `enabled: true`; omit or set it false to keep a skill staged but inert.
    """
  end
end
