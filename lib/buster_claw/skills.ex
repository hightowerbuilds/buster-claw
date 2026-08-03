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
  def skill_path(name), do: Path.join(dir(), name <> ".md")

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
    maybe_write(skill_path("chart-builder"), default_chart_builder())
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

  defp default_roster do
    """
    # Skills

    Composition skills extend Buster Claw's command surface at runtime, with no
    recompile. Each skill is one markdown file here (`<name>.md`) whose `steps`
    are an ordered list of existing native commands.

    ## Two kinds (`handler_kind`)
    - `composition` — `steps` are an ordered list of existing native commands.
      Run one with `./buster-claw run <name> --json '{...}'`. Every step is
      re-authorised, so a skill can never exceed the trust of its caller.
    - `reference` — a playbook you **read** (no steps; the markdown body is the
      payload) for an authoring task the command surface doesn't cover, e.g.
      `shader-designer` for building a homepage shader pattern. Read the file,
      then produce the artifact it describes.

    ## Frontmatter
    - `name` — must equal the filename stem (`[a-z0-9-]`).
    - `description` — what it does / when to use it.
    - `tier` — `safe` or `restricted` (a declared ceiling; per-step authorization
      still applies).
    - `enabled` — `false` by default; a skill is only active when explicitly `true`.
    - `handler_kind` — `composition` or `reference`.
    - `args` — (composition) JSON map of the skill's inputs.
    - `steps` — (composition) JSON array of `{"command": "<native>", "args": {...}}`,
      run in order. In step args, `$<arg>` interpolates a skill input and `$prior`
      is the previous step's result.
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

  defp default_shader_designer do
    """
    ---
    name: shader-designer
    description: Playbook for designing a new homepage WebGPU (WGSL) shader pattern — the prelude contract, palette system, and fs_main structure, with the shipped shaders as worked examples.
    tier: safe
    enabled: true
    handler_kind: reference
    ---

    # shader-designer

    A **reference** skill: read this, then WRITE a WGSL fragment shader for a new
    homepage background pattern. You author ONE file in this workspace; the app
    compiles it live in the browser — no rebuild — and it renders only when the
    user selects it in Settings → Appearance. You propose patterns; the user
    chooses them.

    ## What a shader pattern is

    The homepage background is a full-screen WebGPU fragment shader. A custom
    pattern is one file `shaders/<name>.wgsl` in this workspace containing ONLY
    the fragment code — your own helper functions plus the entry point
    `fs_main`. The app prepends a shared prelude (the uniform contract and a
    helper library) and compiles the result live, so the moment the file exists
    it appears as a selectable design in Settings → Appearance, with a live
    preview.

    Hard constraints — a file that breaks one is ignored or fails to compile:
    - Name: lowercase `[a-z0-9-]` (e.g. `ember-drift.wgsl`). The names
      `smoke`, `waves`, `mandel`, `weather` belong to built-ins and
      are shadowed — pick something else.
    - At most 64 KB, and it must define `fn fs_main`.
    - Do NOT redeclare anything the prelude already provides (see below) — a
      duplicate declaration is a WGSL compile error.

    The four built-ins are worked examples of the same contract: `smoke`
    (domain-warped fbm), `waves`, `mandel` (fractal zoom), and `weather`
    (a ~2-minute sky clock — the most complete).
    If you have the repo checkout, read them in `assets/js/smoke/*.wgsl.js`.

    ## The prelude contract (what you get for free)

    Uniforms (struct `U` at binding 0), all `vec4<f32>`:
    - `u.res`    — `.xy` = pixel resolution.
    - `u.params` — `.x` = time in seconds, `.y` = intensity / interaction amount.
    - `u.style`  — `.z` = a speed multiplier (fold it into your time).
    - `u.post`   — `(glow, grain, scanline, vignette)` for `bg_post`.
    - `u.colA` / `u.colB` / `u.colC` — the 3-colour palette (`.xyz`): base /
      mid-accent / highlight. ALWAYS colour through these so custom palettes work.

    Vertex output you receive: `VOut { @builtin(position) pos, @location(0) uv }`,
    where `uv` is `0..1` with a bottom-left origin.

    Helpers from the prelude (use them, don't re-roll):
    - `hash(vec2) -> f32`, `fbm(vec2) -> f32` — value noise / fractal Brownian motion.
    - `grad3(t, a, b, c) -> vec3` — map a scalar through the 3-colour palette.
    - `touch() -> f32` — an interaction signal.
    - `bg_post(col, uv, res, time, post) -> vec3` — the shared tonemap + vignette +
      scanline + grain pass. Call it LAST.

    ## The shape of an fs_main

        @fragment
        fn fs_main(in: VOut) -> @location(0) vec4<f32> {
          let res = u.res.xy;
          let time = u.params.x * u.style.z;   // fold in the speed multiplier
          let uv = in.uv;
          // ...build a scalar field or colour from uv / time / fbm...
          var col = grad3(field, u.colA.xyz, u.colB.xyz, u.colC.xyz);
          col = col + vec3<f32>(touch());      // optional interaction lift
          col = bg_post(col, uv, res, time, u.post);
          return vec4<f32>(col, 1.0);
        }

    Rules of thumb:
    - Colour ONLY through `u.colA/B/C` — never hardcode colours. A custom
      pattern has no palette entry of its own: with custom colours off it gets
      the Industrial default (`#0e0e0e` base / `#ff4d1c` accent / `#f4f1ea`
      highlight), so design to read well on that trio; the user can re-tint it
      with custom colours.
    - Aspect-correct when you need round shapes: `uv * vec2(res.x/res.y, 1.0)`.
    - Keep it a *background*: subtle, looping, no harsh flashing.
    - Custom patterns render at full canvas density (built-ins get hand-tuned
      low-res tiers; yours doesn't), so keep per-pixel cost modest — prefer
      fbm-style fields over deep iteration loops or raymarching.

    ## Palette roles

    Give each palette colour a consistent role and note it in a header comment —
    e.g. `weather` uses `colA` = sky, `colB` = cloud/mid, `colC` = highlight — so a
    custom palette re-tints the pattern coherently.

    ## Shipping it (no build step)

    1. Write `shaders/<name>.wgsl` in this workspace — fragment code only: no
       prelude copy, no JS wrapper, no `export`.
    2. That's it. The pattern is now listed in Settings → Appearance → Homepage
       background; its WGSL is served from `/shaders/<name>` and compiled in the
       webview when previewed or selected.
    3. It renders only when the **user** selects it. Tell the user the pattern's
       name and what it looks like so they can try it.

    Verify: selecting it in Settings shows a live preview immediately. A WGSL
    compile error leaves the canvas blank and puts
    `unavailable:WGSL: <line>:<message>` in the preview container's
    `data-preview` attribute (`data-smoke` on the homepage) and the console. To
    iterate, edit the file and re-select the pattern — the WGSL is re-fetched
    fresh every time (served no-store).
    """
  end

  defp default_chart_builder do
    """
    ---
    name: chart-builder
    description: Playbook for authoring honest, self-contained SVG charts in Chart Build using Buster Claw's house visual language and cached data.
    tier: safe
    enabled: true
    handler_kind: reference
    ---

    # chart-builder

    A **reference** skill for Chart Build. Read this before drawing a chart. The
    app renders one fenced `svg` block above the conversation and keeps every
    revision in its transcript. This first renderer is deliberately freehand:
    the app sanitizes the markup, but it cannot verify your arithmetic, so every
    result is visibly labelled **Drawn by AI · not computed**.

    ## Output contract

    Emit exactly one complete chart in this form when creating or revising:

        ```svg
        <svg viewBox="0 0 1200 640" xmlns="http://www.w3.org/2000/svg">
          ...
        </svg>
        ```

    Hard constraints:

    - One self-contained `<svg>` with a `viewBox`; target `1200 640` unless the
      chart genuinely needs another aspect ratio.
    - Maximum 100 KB after trimming.
    - No scripts, event handlers, `<foreignObject>`, external references,
      external images, web fonts, `javascript:`, or `data:` URLs.
    - Declarative SVG only: paths, lines, rects, circles, text, gradients and
      same-document `#fragment` references.
    - Put prose outside the SVG fence. Never paste the markup into prose.

    ## Honesty rules

    These are correctness requirements, not stylistic preferences:

    1. Plot only values present in the supplied cache, delivered to you by the
       app, or given to you by the operator. Never invent, interpolate,
       forward-fill, or smooth a missing observation.
    1b. **Never plot a number you read in a search result.** You have web search
       so you can find out what a series is called, who publishes it and what
       units it uses — not so you can copy figures off a page. A transcribed
       number has no source and no as-of attached, and this renderer is already
       freehand: one unverified layer is the honest cost of drawing by hand, two
       is a chart that lies twice and warns once. When you need numbers, name the
       series and the source and ask for them.
    2. **Zero is in frame for quantitative bars.** A bar length or height is
       measured from the zero baseline; negative values extend across it.
    3. **Gaps are gaps.** Use a real date scale and break a line into separate
       paths when observations are missing. Do not connect across an unmeasured
       interval as though the path were observed.
    4. Derive axis labels from the values actually plotted. Never assert a tick
       whose geometry uses a different scale.
    5. Label units, measure, time range, observation count, and data freshness.
       If only 4 of 30 requested days exist, say "4 cached observations". When
       the app delivers a series it comes with a source and an as-of — put both
       in the subtitle, and if the delivered span is shorter than the one asked
       for, say that too. Never label a chart with the range that was requested
       rather than the range you actually plotted.
    6. Do not imply that a freehand chart is independently computed or verified.
       If exact geometry matters, provide the underlying values in prose too.
    7. Do not use a log scale for zero or negative values. If a log scale is
       requested and the data contains either, explain why it cannot be applied
       honestly without changing the dataset.
    8. **One y-axis. Never two scales on one plot.** Two measures of different
       magnitude — price and volume, dollars and percent — read as correlated
       only because you chose where to align their scales, and that correlation
       is not in the data. Draw two stacked plots sharing one x-axis, or index
       both series to 100 at the first observation and plot them on one axis.

    ## Pick the form before the colours

    Ask what the data's job is, and accept that sometimes the answer is not a
    chart. One number with no history is a **stat tile** — a large value, a
    label, and an as-of line — not a one-bar bar chart and not a two-slice pie.
    Magnitude across categories is bars; change over a real time axis is a line;
    part-to-whole at a glance is a pie only at six segments or fewer, and never
    for comparing close values (use bars). Past roughly seven colour classes
    carrying meaning, ship a table instead.

    ## House visual language

    The UI is industrial, high-contrast and restrained. The chart carries its own
    dark canvas, so it does not respond to a light theme; every value below was
    validated against that canvas, not eyeballed.

    Chrome and ink:

    - canvas: `#111315`
    - gridline (hairline): `#24282d`
    - baseline / axis rule: `#3a4047`
    - primary text: `#f2efe8`
    - secondary text: `#a8adb4`
    - muted text (axis ticks): `#7f858c`

    Series colours — a fixed order. Assign slot 1, then 2, then 3, in sequence.
    **Never cycle, and never invent a sixth hue**: a sixth series folds into
    "Other", or the chart becomes small multiples.

    | slot | hue | hex |
    |------|--------|-----------|
    | 1 | hazard | `#ff4407` |
    | 2 | cyan | `#00a1ce` |
    | 3 | violet | `#9417ff` |
    | 4 | magenta | `#e10095` |
    | 5 | yellow | `#ac9000` |

    This order clears every gate on the dark canvas: worst adjacent CVD ΔE 16.0
    (target ≥ 8) and worst adjacent normal-vision ΔE 23.4 (floor ≥ 15), with all
    five slots at or above 3:1 contrast. The **order is the colourblind-safety
    mechanism, not decoration** — do not reorder it, and do not assign colour by
    a series' rank or size, or a filter that drops a series would repaint the
    survivors. Scatter and bubble charts, where any two marks can end up
    adjacent, are capped at **the first four slots**; past four, facet.

    Direction colours are reserved and mean only up/down — never "series 4":

    - positive / up: `#43d17a`
    - negative / down: `#ff5c70`

    **A chart that encodes direction does not use slot 1.** The hazard orange
    sits ΔE 8.2 from the down-red — close enough to confuse a down candle with a
    price line — so on any chart carrying the direction pair, start series
    assignment at slot 2. Slot 4 magenta sits at the ΔE 15.0 floor against the
    down-red; if a directional chart needs a fourth series, fold or facet rather
    than reaching for it.

    Sequential magnitude (a heatmap, a density) is **one hue, light to dark** —
    never a rainbow. Polarity around a baseline is two opposite hues with a
    **neutral grey midpoint** (`#3a4047`); a hue at the midpoint destroys the
    "nothing happening here" reading.

    Type is one sans stack everywhere, including the title:
    `ui-sans-serif, system-ui, sans-serif`. Axis ticks and any column of numbers
    take `font-variant-numeric: tabular-nums` so digits align; a large standalone
    figure does not — equal-width digits make it look loose.

    ## Marks and chrome

    The data is the only thing allowed to be loud.

    - Bars: **at most 24px thick** — never fill the band; leave the remainder as
      air. Round the data-end by 4px and keep the baseline end square.
    - Lines: **2px**, round join and cap. Markers and end-dots at least 8px
      across (r ≥ 4).
    - Area fills: the series hue at about **10% opacity**. A saturated block of
      colour is never correct at this size.
    - Gridlines and axis rules: **1px, solid, one step off the canvas**. Never
      dashed — dashing reads as "projection" or "threshold" when it is just a
      grid.
    - Separate touching marks with a **2px gap in the canvas colour**, and ring
      overlapping dots with 2px of canvas. Never draw a border around a mark to
      separate it; that adds ink that is not data.
    - No 3D, no drop shadows, no gradient that encodes nothing, no animation.

    ## Labels and the legend

    - **Two or more series always get a legend**, so identity never rests on
      colour-matching alone. A single series gets none — the title already names
      it, and a one-swatch box just restates it.
    - **Label selectively. Never put a number on every point.** Label the
      endpoint, the extreme, or the one series the chart is about, and let the
      axis carry the rest. Flood the chart and the labels stop being read.
    - **Text never wears the series colour.** Values, labels, legend text and
      ticks use the ink tokens above; the colour lives in the mark beside them.
      The one exception is a label set inside a filled shape, where you pick ink
      or white by the fill's luminance.
    - Only put a label inside a bar when it fits with padding on both sides.
      Otherwise move it past the bar's end. Never clip a label to make it fit.
    - **You have no hover layer.** The SVG is sanitized: no scripts, no event
      handlers, so there are no tooltips and nothing can be revealed on demand.
      Every value a reader needs must be visible in the chart or written in the
      prose beside it. This is the reason the direct-label and prose-values rules
      above are not optional here.

    Keep a dependable plot box inside the viewBox:

        left = 110, right = 1140, top = 100, bottom = 550
        plot_width = 1030, plot_height = 450

    Title belongs near `(60, 48)`, subtitle near `(60, 74)`, and source/as-of
    copy below the plot. Do not let marks or labels clip the viewBox.

    ## Arithmetic: line and scatter charts

    For values `v` in `[v_min, v_max]` and plot bounds above:

        y(v) = bottom - ((v - v_min) / (v_max - v_min)) * plot_height

    For real dates `d` between `d_min` and `d_max`, first convert them to elapsed
    days from `d_min`:

        x(d) = left + (days(d_min, d) / days(d_min, d_max)) * plot_width

    Example: values 20, 50, 35 over day offsets 0, 2, 5. With a zero-inclusive
    domain `[0, 50]`, their y coordinates are 370, 100, 235. Their x coordinates
    are 110, 522, 1140. The two-day and three-day intervals are visibly
    different widths. If day offsets 3 and 4 were expected but absent, do not
    manufacture points; label the coverage and break the path if the absence is
    a true measurement gap.

    A flat series (`v_min == v_max`) needs a deliberate padded domain; never
    divide by zero. State the constant value directly.

    ## Arithmetic: bar charts

    Use a domain that includes zero:

        domain_min = min(0, smallest_value)
        domain_max = max(0, largest_value)

    For a vertical bar, `zero_y = y(0)`, `value_y = y(v)`, then:

        rect_y = min(zero_y, value_y)
        rect_height = abs(zero_y - value_y)

    Example: values `-20, 40, 80` use `[-20, 80]`, not `[40, 80]`. With the
    standard 450px plot height, zero is y=460; the bars are respectively 90px
    below zero, 180px above it, and 360px above it. Label exact values at their
    ends so geometry and numbers can be checked against each other.

    Horizontal bars use the same rule on x. Sort only when the operator asks or
    when category order carries no meaning; never reorder dates.

    ## Arithmetic: candlesticks

    A candle requires all four OHLC values for the same interval. Do not derive a
    candle from closes alone.

    - wick: vertical line from `y(high)` to `y(low)`
    - body top: `min(y(open), y(close))`
    - body height: `max(2, abs(y(open) - y(close)))`
    - rising (`close >= open`): positive colour
    - falling (`close < open`): negative colour

    Example OHLC `open=100, high=110, low=95, close=105` on domain `[90, 115]`
    maps to y values 370, 190, 460, 280. The wick spans 190→460; the body spans
    280→370 and is positive. Show the interval and do not mix daily and weekly
    candles on one axis.

    If cached rows carry only `close`, say that candlesticks are unavailable and
    offer an honest line chart. Never synthesize open/high/low from a close.

    ## Iteration

    Treat the newest chart as a revision of the previous one unless the operator
    asks for a separate view. Preserve the underlying values while changing
    presentation. If a request such as "make the bars horizontal" changes only
    orientation, recompute the geometry from the same values; do not copy pixel
    lengths by eye. Briefly name any data or coverage limitation outside the SVG.
    """
  end
end
