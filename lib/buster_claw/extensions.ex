defmodule BusterClaw.Extensions do
  @moduledoc """
  Extensions — the after-download capability layer.

  An extension is a **bundle of data**, never code. It carries a manifest, and
  *parts*: reference playbooks and composition skills. It can declare which
  application surface it activates and which network hosts and write verbs its
  tooling reaches, and that declaration is what the operator consents to.

  See `daily-growth/roadmaps/EXTENSIONS_ROADMAP.md` for the six locked decisions.
  The two that shape this module:

  - **D1 — an extension is never executable code.** No `.beam`, no `.ex`, no NIF.
    The BEAM has no code sandbox, so a loaded module would hold the keychain, the
    database, every token, and the Tauri bridge. This module only ever reads
    markdown.
  - **D3 — an extension may never grant itself a tier.** Its parts are reference
    playbooks (read, never run) and composition skills, and a composition skill's
    steps are re-authorised per step through `Commands.call/3`. An extension
    therefore cannot exceed the trust of whoever invokes it.

  ## Two sources

  - **Bundled** — `extensions/<id>/` at the repo root, embedded at compile time
    (the `BusterClaw.UserGuide` pattern) so bundles ship inside releases.
  - **Workspace** — `<workspace>/extensions/<id>/`, where **model-attached parts**
    land. Operator-visible, git-diffable, and editable by hand.

  A bundled extension and a workspace directory with the same id are the same
  extension: the manifest comes from the bundle, and the workspace supplies
  additional parts. A workspace part can only ever *add* a playbook or a
  composition — it cannot edit the manifest, so it cannot widen what the
  extension may reach.

  ## Enablement

  Every extension is **off on a fresh install** and turned on by the operator
  (`enable/1`), which is what makes an extension an after-download surface rather
  than shipped breadth. Enablement is one `Settings` key per extension, so it
  survives restarts and is visible in one place.

  ## Attaching a part

  `add_part/2` is how the model grows an extension without a release. The part it
  writes is **always `enabled: false`**. That is not a courtesy — it is the same
  gate `BusterClaw.Skills` already applies to authored skills (its threat model,
  T5), and it is the reason a model-authored composition cannot silently become a
  callable command that chains permitted reads into an outbound send.

  This module deliberately knows nothing about `BusterClaw.Skills`: it hands out
  directory paths and writes files, and Skills scans those paths. Pointing it the
  other way would close a `Skills → Extensions → Skills` cycle.
  """
  require Logger

  alias BusterClaw.Library.{Artifact, Frontmatter}
  alias BusterClaw.Settings

  @dir Path.expand(Path.join([__DIR__, "..", "..", "extensions"]))
  @subdir "extensions"
  @manifest "extension.md"
  @schema 1

  # Bundled manifests + parts, embedded at compile time so they ship in a
  # release (the workspace copy of a bundle may not exist on a fresh machine).
  @bundled_manifests Path.wildcard(Path.join([@dir, "*", @manifest]))
  @bundled_parts Path.wildcard(Path.join([@dir, "*", "skills", "*.md"]))

  for path <- @bundled_manifests ++ @bundled_parts do
    @external_resource path
  end

  @bundles Map.new(@bundled_manifests, fn path ->
             id = path |> Path.dirname() |> Path.basename()
             {id, File.read!(path)}
           end)

  @bundle_parts Enum.group_by(
                  @bundled_parts,
                  fn path -> path |> Path.dirname() |> Path.dirname() |> Path.basename() end,
                  fn path -> {Path.basename(path, ".md"), File.read!(path)} end
                )

  @doc "Absolute path of the workspace extensions directory."
  def dir, do: Artifact.workspace_path(@subdir)

  @doc "Absolute path of one extension's workspace directory (where parts land)."
  def extension_dir(id), do: Path.join(dir(), id)

  @doc "Absolute path of one extension's workspace skills directory."
  def parts_dir(id), do: Path.join(extension_dir(id), "skills")

  @doc "Every known extension id, sorted. Bundled ids plus any workspace-only ids."
  def ids do
    workspace =
      case File.ls(dir()) do
        {:ok, entries} -> entries
        _ -> []
      end

    (Map.keys(@bundles) ++ workspace)
    |> Enum.filter(&valid_id?/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  @doc """
  Every extension as a summary map: `id`, `name`, `summary`, `version`, `surface`,
  `network`, `writes`, `money`, `enabled`, `bundled`, and `parts` (a count).

  Invalid manifests are dropped with a warning rather than raising — one bad
  bundle must not take the surface down.
  """
  def list do
    ids() |> Enum.flat_map(&summarize/1) |> Enum.sort_by(& &1.id)
  end

  @doc """
  Load one extension's manifest. Returns `{:ok, manifest}`, `{:error, reason}` for
  a malformed manifest, or `nil` when the extension does not exist.
  """
  def fetch(id) when is_binary(id) do
    with true <- valid_id?(id),
         {:ok, raw} <- manifest_source(id) do
      %{fields: fields, body: body} = Frontmatter.split(raw)
      validate(id, fields, body)
    else
      false -> {:error, :invalid_id}
      :error -> nil
    end
  end

  def fetch(_id), do: nil

  @doc """
  Whether an extension is switched on. Off unless the operator turned it on.

  **Fails closed.** The enable flag lives in `Settings`, which is a database read,
  and this function sits under `BusterClaw.Skills` — which sits under the command
  catalog. A repo that is unavailable, unmigrated, or not checked out to the
  calling process must not take the catalog down, and it must never be read as
  "on": an error here means the extension contributes nothing.
  """
  def enabled?(id) when is_binary(id) do
    Settings.get(setting_key(id)) == "on"
  rescue
    _error -> false
  catch
    :exit, _reason -> false
  end

  def enabled?(_id), do: false

  @doc """
  Turn an extension on. Refuses an id with no valid manifest, so enabling is
  always a decision about something the loader has already parsed and accepted.
  """
  def enable(id) do
    case fetch(id) do
      {:ok, manifest} ->
        Settings.put(setting_key(id), "on")
        {:ok, manifest}

      {:error, reason} ->
        {:error, reason}

      nil ->
        {:error, :not_found}
    end
  end

  @doc """
  Set enablement **only if the operator has never decided** — the upgrade path
  for an install that predates the extension.

  Returns `:adopted` when it wrote a value, `:already_decided` when a setting
  already exists (including one deliberately set to off). Deciding for someone
  who has already decided is the one thing an upgrade must never do: an operator
  who turned Trading off does not want it back after an update.

  The *policy* — what counts as "this install already uses the surface" — lives
  at the call site, because it needs knowledge of the surface's own data that
  this module has no business carrying.
  """
  def adopt(id, enabled?) when is_binary(id) and is_boolean(enabled?) do
    cond do
      not valid_id?(id) -> {:error, :invalid_id}
      not is_nil(Settings.get(setting_key(id))) -> :already_decided
      true -> Settings.put(setting_key(id), if(enabled?, do: "on", else: "off")) && :adopted
    end
  rescue
    _error -> {:error, :unavailable}
  end

  @doc "Turn an extension off. Its parts leave the skills surface immediately."
  def disable(id) when is_binary(id) do
    if valid_id?(id) do
      Settings.put(setting_key(id), "off")
      :ok
    else
      {:error, :invalid_id}
    end
  end

  @doc """
  Whether the extension that owns an application surface is switched on.

  A surface (`"trading"`) is named by exactly one manifest's `surface:` field.
  This is what the dock, the split-pane list, and the surface's own LiveView
  consult, so "installed" has one answer everywhere.

  `enabled?/1` is checked **before** the manifest is parsed: when the extension
  is off — the common case on a fresh install, and the one on every page render
  — this costs one indexed settings lookup and no parsing.

  Fails closed for the same reason `enabled?/1` does: a surface whose ownership
  cannot be determined is not installed.
  """
  def surface_enabled?(surface) when is_binary(surface) do
    Enum.any?(ids(), fn id ->
      enabled?(id) and match?({:ok, %{surface: ^surface}}, fetch(id))
    end)
  end

  def surface_enabled?(_surface), do: false

  @doc """
  Whether any installed manifest claims this surface at all.

  A surface nobody owns is **not** gated — it is ordinary application code that
  happens to share a name. Without this, deleting an extension would silently
  hide the surface it used to own instead of leaving it visible.
  """
  def surface_owned?(surface) when is_binary(surface) do
    Enum.any?(ids(), fn id -> match?({:ok, %{surface: ^surface}}, fetch(id)) end)
  end

  def surface_owned?(_surface), do: false

  @doc """
  Workspace skill directories belonging to **enabled** extensions.

  `BusterClaw.Skills` scans these alongside the workspace `skills/` directory.
  A disabled extension contributes nothing, which is what makes the off switch
  real rather than cosmetic.
  """
  def skill_dirs do
    ids()
    |> Enum.filter(&enabled?/1)
    |> Enum.map(&parts_dir/1)
    |> Enum.filter(&File.dir?/1)
  end

  @doc """
  Bundled parts of **enabled** extensions as `{name, markdown}` pairs.

  Bundled parts are embedded at compile time rather than read from the workspace,
  so they cannot be edited into something the release never shipped. A workspace
  part with the same name shadows the bundled one — that is the deliberate escape
  hatch for an operator who wants to override a shipped playbook.
  """
  def bundled_parts do
    ids()
    |> Enum.filter(&enabled?/1)
    |> Enum.flat_map(&Map.get(@bundle_parts, &1, []))
  end

  @doc """
  Attach a part to an extension: write `<workspace>/extensions/<id>/skills/<name>.md`.

  `attrs` needs `:name` and `:body`, and may carry `:description` and `:kind`
  (`:reference`, the default, or `:composition` with `:steps`).

  **The part is always written `enabled: false`.** Nothing here can produce an
  active part; an operator enables it afterwards. Refuses to overwrite an existing
  part, refuses an extension that has no manifest, and refuses a name that is not
  `[a-z0-9-]`.

  Returns `{:ok, path}` or `{:error, reason}`.
  """
  def add_part(id, %{name: name} = attrs) do
    cond do
      not valid_id?(id) ->
        {:error, :invalid_id}

      not valid_id?(to_string(name)) ->
        {:error, :invalid_name}

      match?(nil, fetch(id)) ->
        {:error, :not_found}

      match?({:error, _}, fetch(id)) ->
        {:error, :invalid_manifest}

      File.exists?(part_path(id, name)) ->
        {:error, :exists}

      blank?(attrs[:body]) ->
        {:error, :empty_body}

      attrs[:kind] == :composition and not valid_steps?(attrs[:steps]) ->
        {:error, :no_steps}

      true ->
        File.mkdir_p!(parts_dir(id))
        File.write!(part_path(id, name), render_part(id, attrs))
        {:ok, part_path(id, name)}
    end
  end

  def add_part(_id, _attrs), do: {:error, :invalid_attrs}

  @doc "Absolute path of one part file."
  def part_path(id, name), do: Path.join(parts_dir(id), to_string(name) <> ".md")

  @doc """
  Best-effort seed: create `<workspace>/extensions/` with a roster README, and the
  `extension-authoring` playbook in `skills/` so the model can read how to attach
  a part before it tries. Never overwrites an operator-authored file.
  """
  def ensure do
    File.mkdir_p!(dir())
    maybe_write(Path.join(dir(), "README.md"), roster())

    skills_dir = Artifact.workspace_path("skills")
    File.mkdir_p!(skills_dir)
    maybe_write(Path.join(skills_dir, "extension-authoring.md"), authoring_skill())
    :ok
  rescue
    error ->
      Logger.warning("Extensions.ensure failed: #{Exception.message(error)}")
      :error
  end

  # --- internals ---------------------------------------------------------

  defp summarize(id) do
    case fetch(id) do
      {:ok, manifest} ->
        [Map.merge(manifest, %{enabled: enabled?(id), parts: part_count(id)})]

      {:error, reason} ->
        Logger.warning(
          "Extensions: ignoring invalid manifest #{inspect(id)} — #{inspect(reason)}"
        )

        []

      nil ->
        []
    end
  end

  defp part_count(id) do
    bundled = @bundle_parts |> Map.get(id, []) |> Enum.map(&elem(&1, 0))

    workspace =
      case File.ls(parts_dir(id)) do
        {:ok, files} ->
          files
          |> Enum.filter(&(Path.extname(&1) == ".md"))
          |> Enum.map(&Path.basename(&1, ".md"))

        _ ->
          []
      end

    (bundled ++ workspace) |> Enum.uniq() |> length()
  end

  # A bundled manifest wins over a workspace one: the manifest is the consent
  # document, and letting the workspace supply it would let an edited file widen
  # what a signed bundle declared.
  defp manifest_source(id) do
    case Map.fetch(@bundles, id) do
      {:ok, raw} -> {:ok, raw}
      :error -> File.read(Path.join(extension_dir(id), @manifest)) |> normalize_read()
    end
  end

  defp normalize_read({:ok, raw}), do: {:ok, raw}
  defp normalize_read(_error), do: :error

  defp validate(id, fields, body) do
    cond do
      is_binary(fields["id"]) and fields["id"] != id ->
        {:error, :id_mismatch}

      not is_integer(fields["schema"]) or fields["schema"] > @schema ->
        {:error, {:unsupported_schema, fields["schema"]}}

      blank?(fields["name"]) ->
        {:error, :missing_name}

      blank?(fields["version"]) ->
        {:error, :missing_version}

      true ->
        {:ok,
         %{
           id: id,
           name: fields["name"],
           version: to_string(fields["version"]),
           summary: present(fields["summary"]) || first_line(body) || "",
           surface: present(fields["surface"]),
           network: string_list(fields["network"]),
           writes: string_list(fields["writes"]),
           money: fields["money"] == true,
           bundled: Map.has_key?(@bundles, id),
           body: body
         }}
    end
  end

  defp render_part(id, %{name: name} = attrs) do
    kind = if attrs[:kind] == :composition, do: "composition", else: "reference"
    description = attrs |> Map.get(:description, "") |> to_string()

    metadata =
      Jason.encode!(%{"version" => "1.0.0", "extension" => id, "part" => "skill"})

    steps =
      if kind == "composition", do: "steps: #{Jason.encode!(attrs[:steps])}\n", else: ""

    """
    ---
    name: #{name}
    description: #{yaml_quote(description)}
    metadata: #{metadata}
    tier: safe
    enabled: false
    handler_kind: #{kind}
    #{steps}---

    #{String.trim(to_string(attrs[:body]))}
    """
  end

  # Quote interpolated frontmatter scalars so arbitrary text can't break the YAML
  # structure or smuggle in extra fields. Matches `Skills.yaml_quote/1`.
  defp yaml_quote(value) do
    escaped =
      value
      |> to_string()
      |> String.replace("\\", "\\\\")
      |> String.replace("\"", "\\\"")
      |> String.replace(["\r\n", "\n", "\r"], " ")

    ~s("#{escaped}")
  end

  defp valid_id?(id) when is_binary(id), do: Regex.match?(~r/\A[a-z0-9][a-z0-9-]*\z/, id)
  defp valid_id?(_id), do: false

  defp valid_steps?(steps), do: is_list(steps) and steps != []

  defp setting_key(id), do: "extension:" <> id

  defp string_list(value) when is_list(value), do: Enum.map(value, &to_string/1)
  defp string_list(_value), do: []

  defp blank?(value), do: is_nil(present(value))

  defp present(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp present(_value), do: nil

  defp first_line(body) when is_binary(body) do
    body
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.find(&(&1 != "" and not String.starts_with?(&1, "#")))
  end

  defp first_line(_body), do: nil

  defp maybe_write(path, content) do
    if File.exists?(path), do: :ok, else: File.write(path, content)
  end

  # --- seed templates ----------------------------------------------------

  defp roster do
    """
    # Extensions

    An extension is a bundle of **data** — a manifest plus parts (reference
    playbooks and composition skills). An extension is never code: no `.beam`, no
    `.ex`, no binary. New capability arrives out-of-process as an MCP server, or
    not at all.

    Each directory here is one extension's **workspace side**, holding parts
    attached after install:

        extensions/<id>/skills/<name>.md

    The manifest that declares what an extension may reach ships with the release
    and is **not** editable here. That is the point: a part can add a playbook or
    a composition, but it cannot widen what the extension can touch.

    ## Parts land disabled

    Every attached part is written `enabled: false`. Enable one by editing its
    frontmatter after reading it. A composition skill's steps are re-authorised
    individually when it runs, so a part can never exceed the trust of whoever
    invokes it — but a part you have not read is still a part you have not read.

    ## Turning an extension on

    Extensions are off on a fresh install. Settings → Extensions lists what is
    installed, what each one can reach, and the switch.
    """
  end

  defp authoring_skill do
    """
    ---
    name: extension-authoring
    description: Playbook for attaching a new part to an installed extension — what a part may be, the disabled-by-default gate, and when a request is a manifest change rather than a part.
    metadata: {"version":"1.0.0","part":"skill"}
    tier: safe
    enabled: true
    handler_kind: reference
    ---

    # extension-authoring

    A **reference** skill: read this before attaching a part to an extension.

    ## What an extension is

    A bundle of **data** — a manifest plus parts. **An extension is never code.**
    There is no `.beam`, no `.ex`, no binary, no script. The runtime has no code
    sandbox, so a loaded module would hold the keychain, the database, every API
    token, and the native bridge. That limit is not a policy you can ask to have
    lifted; it is the reason every other control in this application means
    anything.

    New capability arrives **out-of-process** as an MCP server, or not at all.

    ## What a part may be

    | Part | What it is | When to write one |
    |---|---|---|
    | **reference** | A playbook the agent reads. The markdown body is the payload. | Knowledge, discipline, a contract to follow. Most parts are this. |
    | **composition** | An ordered list of **existing native commands**. | A sequence the operator repeats. It owns no new capability, only new sequencing. |

    A composition's steps are re-authorised **individually** when it runs, as the
    caller who invoked it. So a composition can never exceed its caller's trust —
    and equally, it can never grant you a capability you did not already have.
    If you find yourself writing steps to reach something you cannot reach
    directly, stop: that is the signal you are trying to write a manifest change.

    ## Parts land disabled. Always.

    Every part you attach is written `enabled: false`, and nothing you can do
    changes that. The operator reads it and enables it.

    This is not friction for its own sake. A composition that chains permitted
    reads into an outbound send is a data-exfiltration path built entirely out of
    allowed steps — every individual step authorised, the sequence not. The
    enable gate is where a human looks at the **sequence**.

    So: **write the part to be read.** The operator's decision is made from your
    description and body, not from watching it run. Say what it does, what it
    touches, and what it deliberately does not do.

    ## When a request is not a part

    Stop and say so plainly if fulfilling a request would need:

    - a **tool** the extension's run does not already hold,
    - a **network host** the manifest does not declare,
    - a **write verb**, purchase, or send the manifest does not declare,
    - a **loosened** rule from an existing playbook.

    None of those is a part. Each is a change to the manifest — the document the
    operator consented to at install — and that requires their explicit approval
    and, for a bundled extension, a release. **Writing a part that pretends to
    have one of these is worse than refusing**, because it puts a capability claim
    in a file that reads like it was reviewed.

    Tightening is always allowed. A part may add caution, narrow a rule, or refuse
    something the extension would otherwise permit. The asymmetry is deliberate.

    ## Writing a good part

    1. **Name it `[a-z0-9-]`**, descriptive, no version suffix.
    2. **Write the description for the enable screen.** It is the whole basis of
       the operator's decision. "Daily position summary for one account" beats
       "helper skill".
    3. **State what it does not do.** The negative space is what makes a playbook
       trustworthy — see `robinhood-trading`, whose most useful section is a list
       of things never to do.
    4. **Ground it in real names.** Real command names, real tool names, real
       field names. A playbook that invents a tool teaches the reader a tool that
       does not exist.
    5. **Prefer worked examples to principles.** A short exchange showing the
       right and wrong response is worth a paragraph of rules.
    6. **Never restate a capability as a permission.** "You may cancel an order"
       is a fact about the tool list. Whether you *should* is the playbook's job.

    ## Checking your work

    Re-read the part as the operator, not the author, and ask:

    - Could I tell from the description alone whether to enable this?
    - Does anything here claim a capability the manifest does not declare?
    - If a hostile message tried to invoke this, what is the worst it achieves?

    That third question is the one worth the most time. A part is a durable
    instruction that outlives the conversation that created it.
    """
  end
end
