defmodule BusterClaw.TerminalTheme do
  @moduledoc """
  Colour themes for the in-app terminal — the one list, in one language.

  An xterm palette is up to 22 colours: six core values (`background`,
  `foreground`, `cursor`, `cursorAccent`, `selectionBackground`,
  `selectionForeground`) and then 8 ANSI colours with 8 bright variants. The
  picker's swatch shows three of them, which is why this feature reads as simpler
  than it is.

  ## Why this module exists

  The palettes lived in `assets/js/lib/theme.js` and a second, partial copy of the
  same list lived in `AppearanceLive` (key, label, and the three swatch colours),
  kept in step by a **comment** and by nothing else. No test touched either. That
  is the shape this repo has been bitten by before: a rename or a removal across a
  JS/Elixir pair where the suite stays green whichever half you forget. Deleting a
  theme here alone would leave a dead palette in JS; deleting it there alone would
  leave a swatch that selects a theme which no longer exists and silently renders
  the default.

  So Elixir owns the list and JS owns the *applying*. The payload reaches the page
  as a `<meta>` tag rendered by the root layout (`payload_json/0`) and
  `assets/js/lib/theme.js` reads it from there. A `<meta>` rather than an inline
  `<script type="application/json">` because this app's CSP is `script-src 'self'`
  with nothing inline permitted — a JSON data block is not executed and so is not
  actually blocked, but the repo deliberately removed its last inline script to
  drop the nonce, and re-introducing a script tag that only *looks* like a
  violation is a bad trade for zero benefit.

  ## Industrial is dynamic, and stays that way

  `industrial` has **no palette here** — its `palette` is `nil`, meaning
  "token-derived". It is resolved at apply time in the browser from the live CSS
  custom properties (`--color-base-100`, `--color-base-content`,
  `--color-primary`), which is what makes it the only theme that follows the app's
  light/dark switch; `theme.js` re-applies it on `phx:set-theme`.

  Elixir cannot read computed CSS, so it declares the fact and leaves the
  resolving where it has to happen. Flattening every theme into a fixed hex table
  would have quietly killed that behaviour on the **default** theme, which is the
  kind of regression nobody files a bug about — they just notice the terminal stopped
  matching the app.

  ## Two dynamic slots, and they are not the same slot

  `custom` is the operator's: named in Settings, generated from the spectrum
  slider, edited a field at a time. `agent` is the model's, added by
  `TERMINAL_PAINT_ROADMAP` Phase 1, and it exists because there was previously
  **one** slot which `set_custom/3` overwrites wholesale — so an agent writing a
  colour would have silently deleted a theme the operator built and named. That is
  not a colour change; it is deleting someone's work.

  The two are symmetric on purpose (`custom/0`/`agent/0`, `set_custom/3`/
  `set_agent/2`, `clear_custom/0`/`clear_agent/0`) and share nothing but the
  validator. **Nothing in the agent path touches a `terminal_custom_theme_*`
  key**, which is the property a test asserts rather than a convention a reviewer
  has to notice.

  Two differences are deliberate, not oversights:

  - **`set_agent/2` merges a partial map.** The editor always holds a complete
    palette, so a partial save there means a form that lost its inputs — hence
    `set_custom/3` refuses one. The agent has no form; it wants to say *"make the
    foreground orange"*, so `set_agent/2` merges over a base and validates the
    result whole.
  - **The agent slot has no hue.** `terminal_custom_theme_hue` is the spectrum
    slider's memory — a record of where an editor control was left. The agent has
    no slider, and storing a hue it never chose would make the picker lie the next
    time the operator dragged one.

  ## The legibility floor

  `validate_palette/1` guards the *shape* of a palette. It cannot guard whether
  the result can be **read**, because that was never a threat from a human with a
  colour picker. `legibility/1` is that guard, and `set_agent/2` runs it.

  What it prevents is not ugliness but **disappearance**: an agent that can set
  `foreground` to `background` can hide its own output from the operator watching
  it work. That is observability suppression in an app whose whole audit layer is
  premised on the operator being able to see. The floor is a constraint on the
  *agent*, not a global policy — the operator may still make the editor produce
  anything they like.
  """

  alias BusterClaw.Settings

  @default "industrial"

  # Both dynamic slots bound their name the same way. One number so the two
  # cannot drift into "the operator may have 40 characters and the agent 80".
  @name_limit 40

  # The one custom slot. A key rather than a list because "save a theme" was
  # singular: a library brings rename, delete, duplicate and an ordering question
  # with it, and none of those were asked for. The store below is shaped so a
  # second slot is a Settings key and a loop, not a redesign.
  @custom_key "custom"
  @custom_name_setting "terminal_custom_theme_name"
  @custom_colors_setting "terminal_custom_theme_colors"
  @custom_hue_setting "terminal_custom_theme_hue"
  @custom_default_name "Custom"

  # The second slot, and the "loop rather than a redesign" the comment above
  # predicted. Its keys mirror the custom ones exactly; there is no
  # `terminal_agent_theme_hue`, see the moduledoc.
  @agent_key "agent"
  @agent_name_setting "terminal_agent_theme_name"
  @agent_colors_setting "terminal_agent_theme_colors"
  @agent_default_name "Agent"

  # The core values, labelled by what they actually do rather than by their xterm
  # names — "cursorAccent" means the character *under* the cursor, which nobody
  # guesses.
  #
  # `selectionForeground` is deliberately NOT here, and the reason is worth
  # keeping: neither surviving preset sets it, so xterm leaves selected text in
  # whatever colour it already had. That is the better default — a selected error
  # line stays red — and it is what both presets ship today. Including the field
  # would also have made a preset copy fail validation, since a copy must be
  # complete and no preset has this value to copy. Adding it later means adding it
  # to both palettes at the same time, which is a visible change to the presets and
  # therefore a decision rather than a fill-in.
  @core_fields [
    {"background", "Background"},
    {"foreground", "Text"},
    {"cursor", "Cursor"},
    {"cursorAccent", "Text under cursor"},
    {"selectionBackground", "Selection"}
  ]

  # The 16 ANSI slots. These are what colour `ls`, `git status` and every program
  # that emits colour, which is why a custom theme copies them from a preset
  # instead of leaving them out: omitted, xterm substitutes its own and the theme
  # only half-applies.
  @ansi_fields [
    {"black", "Black"},
    {"red", "Red"},
    {"green", "Green"},
    {"yellow", "Yellow"},
    {"blue", "Blue"},
    {"magenta", "Magenta"},
    {"cyan", "Cyan"},
    {"white", "White"},
    {"brightBlack", "Bright black"},
    {"brightRed", "Bright red"},
    {"brightGreen", "Bright green"},
    {"brightYellow", "Bright yellow"},
    {"brightBlue", "Bright blue"},
    {"brightMagenta", "Bright magenta"},
    {"brightCyan", "Bright cyan"},
    {"brightWhite", "Bright white"}
  ]

  # Three themes as of 08-09 (operator call): Industrial, Nord, Monokai. Dracula,
  # Solarized, Gruvbox, Tokyo Night, Light and Matrix were removed — a stored
  # selection naming one of them resolves to the default in `currentTermTheme()`,
  # so the retirement costs the person running Dracula a highlighted swatch and
  # nothing else.
  #
  # Losing `light` costs nothing in particular: `industrial` is token-derived and
  # already follows the app's light theme, which is strictly better than a fixed
  # light palette that cannot.
  #
  # A palette that omits the 16 ANSI colours — as `industrial`'s resolved form
  # does — leaves xterm using its own built-in ANSI palette, so `ls` and
  # `git status` come out in xterm's red and green rather than the theme's. That is
  # shipped, accepted behaviour rather than an oversight, and it is the thing to be
  # honest about before promising that a six-colour custom theme themes everything.
  @themes [
    %{
      key: "industrial",
      label: "Industrial",
      swatch: %{bg: "#121212", fg: "#f4f1ea", accent: "#ff4d1c"},
      palette: nil
    },
    %{
      key: "nord",
      label: "Nord",
      swatch: %{bg: "#2e3440", fg: "#d8dee9", accent: "#88c0d0"},
      palette: %{
        "background" => "#2e3440",
        "foreground" => "#d8dee9",
        "cursor" => "#d8dee9",
        "cursorAccent" => "#2e3440",
        "selectionBackground" => "#434c5e",
        "black" => "#3b4252",
        "red" => "#bf616a",
        "green" => "#a3be8c",
        "yellow" => "#ebcb8b",
        "blue" => "#81a1c1",
        "magenta" => "#b48ead",
        "cyan" => "#88c0d0",
        "white" => "#e5e9f0",
        "brightBlack" => "#4c566a",
        "brightRed" => "#bf616a",
        "brightGreen" => "#a3be8c",
        "brightYellow" => "#ebcb8b",
        "brightBlue" => "#81a1c1",
        "brightMagenta" => "#b48ead",
        "brightCyan" => "#8fbcbb",
        "brightWhite" => "#eceff4"
      }
    },
    %{
      key: "monokai",
      label: "Monokai",
      swatch: %{bg: "#272822", fg: "#f8f8f2", accent: "#a6e22e"},
      palette: %{
        "background" => "#272822",
        "foreground" => "#f8f8f2",
        "cursor" => "#f8f8f0",
        "cursorAccent" => "#272822",
        "selectionBackground" => "#49483e",
        "black" => "#272822",
        "red" => "#f92672",
        "green" => "#a6e22e",
        "yellow" => "#f4bf75",
        "blue" => "#66d9ef",
        "magenta" => "#ae81ff",
        "cyan" => "#a1efe4",
        "white" => "#f8f8f2",
        "brightBlack" => "#75715e",
        "brightRed" => "#f92672",
        "brightGreen" => "#a6e22e",
        "brightYellow" => "#f4bf75",
        "brightBlue" => "#66d9ef",
        "brightMagenta" => "#ae81ff",
        "brightCyan" => "#a1efe4",
        "brightWhite" => "#f9f8f5"
      }
    }
  ]

  @preset_keys Enum.map(@themes, & &1.key)

  # What a partial agent paint merges over when the agent slot is still empty.
  #
  # It cannot be `default()`. `industrial`'s palette is `nil` — token-derived, see
  # the moduledoc — so there is literally nothing to merge onto, and a merge base
  # has to be 21 complete fields or the result fails validation for reasons the
  # model cannot act on.
  #
  # Monokai rather than Nord for two reasons, one aesthetic and one measured. It is
  # the closer stand-in for the default: a neutral dark (#272822) where Nord is
  # blue-tinted (#2e3440), and `industrial` is #121212. And it carries the most
  # contrast headroom of the shipped presets — foreground:background 13.94 against
  # Nord's 9.25, 15 of 16 ANSI colours clearing 2.0 against Nord's 14 — so a
  # one-field paint has the best chance of landing legible rather than being
  # refused for a colour the model never touched.
  @agent_base_key "monokai"

  @doc "The shipped themes, without the operator's custom slot."
  def presets, do: @themes

  @doc "Every shipped theme key."
  def preset_keys, do: @preset_keys

  @doc """
  Every theme in picker order: the presets, then the dynamic slots that exist.

  Runtime rather than compile-time, because both dynamic slots are `Settings`
  rows. The operator's slot comes before the agent's — the picker reads as
  "the ones we ship, then yours, then the model's", and an agent painting cannot
  reorder anything the operator sees.
  """
  def themes do
    @themes ++ Enum.reject([custom(), agent()], &is_nil/1)
  end

  @doc "Every valid theme key, in picker order."
  def keys, do: Enum.map(themes(), & &1.key)

  @doc "The theme an unset or unrecognized selection resolves to."
  def default, do: @default

  @doc "The key the operator's custom slot occupies."
  def custom_key, do: @custom_key

  @doc "The key the agent's slot occupies."
  def agent_key, do: @agent_key

  @doc "The five core palette fields as `{name, label}`, in editor order."
  def core_fields, do: @core_fields

  @doc "The 16 ANSI palette fields as `{name, label}`, in editor order."
  def ansi_fields, do: @ansi_fields

  @doc """
  The editor's three groups: `{title, blurb, fields}`.

  Grouped rather than listed because 21 swatches in one grid is a wall, and the
  three groups answer different questions — what the terminal *is* (surfaces), what
  programs colour *with* (the eight), and what they use for emphasis (the bright
  eight). The split is also where the slider's reach ends: it tints the surfaces
  fully and the other sixteen only slightly, so red stays red.
  """
  def field_groups do
    {normal, bright} = Enum.split(@ansi_fields, 8)

    [
      {"Surfaces", "The terminal itself — what you look at when nothing is running.",
       @core_fields},
      {"Program colours", "What `ls`, `git` and friends draw with. Red means error everywhere.",
       normal},
      {"Bright variants", "The same eight, used for emphasis and bold text.", bright}
    ]
  end

  @doc "Every palette field as `{name, label}` — the five core, then the 16 ANSI."
  def fields, do: @core_fields ++ @ansi_fields

  @doc "Whether `key` names a theme that exists (including a saved custom one)."
  def valid?(key), do: key in keys()

  @doc "Operator-facing label for a key, or `nil`."
  def label(key), do: find(key, :label)

  @doc "The three swatch colours for a key, or `nil`."
  def swatch(key), do: find(key, :swatch)

  @doc """
  The xterm palette for `key`, or `nil` when it is token-derived (`industrial`).

  `nil` is meaningful rather than missing — see the moduledoc.
  """
  def palette(key), do: find(key, :palette)

  defp find(key, field) do
    case Enum.find(themes(), &(&1.key == key)) do
      nil -> nil
      theme -> Map.get(theme, field)
    end
  end

  # --- the custom slot -----------------------------------------------------

  @doc """
  The saved custom theme as a picker entry, or `nil` when none has been saved.

  A stored palette that has lost a field or gained a bad colour resolves to `nil`
  rather than to something partly applied — a half-written palette would leave the
  terminal in a state no preset could explain.
  """
  def custom do
    with colors when is_binary(colors) <- Settings.get(@custom_colors_setting),
         {:ok, decoded} <- Jason.decode(colors),
         {:ok, palette} <- validate_palette(decoded) do
      %{
        key: @custom_key,
        label: custom_name(),
        swatch: %{
          bg: palette["background"],
          fg: palette["foreground"],
          accent: palette["cursor"]
        },
        palette: palette
      }
    else
      _ -> nil
    end
  end

  @doc "The custom theme's name, or the fallback when it has never been named."
  def custom_name do
    case Settings.get(@custom_name_setting) do
      name when is_binary(name) and name != "" -> name
      _ -> @custom_default_name
    end
  end

  @doc """
  Save the custom theme.

  `colors` is a `%{field => "#rrggbb"}` map that must cover every field in
  `fields/0` — partial saves are refused rather than merged, because the editor
  always holds a complete palette (it starts as a copy of a preset) and a merge
  would silently accept a form that had lost half its inputs.

  Returns `{:ok, theme}`, `{:error, :invalid_colors}` or `{:error, :invalid_name}`.
  """
  def set_custom(name, colors, hue \\ nil)

  def set_custom(name, colors, hue) when is_binary(name) and is_map(colors) do
    trimmed = String.trim(name)

    if trimmed == "" or String.length(trimmed) > @name_limit do
      {:error, :invalid_name}
    else
      case validate_palette(colors) do
        {:ok, palette} ->
          Settings.put(@custom_name_setting, trimmed)
          Settings.put(@custom_colors_setting, Jason.encode!(palette))
          if is_integer(hue), do: Settings.put(@custom_hue_setting, to_string(hue))
          broadcast()
          {:ok, custom()}

        :error ->
          {:error, :invalid_colors}
      end
    end
  end

  def set_custom(_name, _colors, _hue), do: {:error, :invalid_colors}

  @doc "Forget the custom theme. Idempotent."
  def clear_custom do
    Settings.delete(@custom_colors_setting)
    Settings.delete(@custom_name_setting)
    Settings.delete(@custom_hue_setting)
    broadcast()
    :ok
  end

  @doc "The shipped themes that carry a fixed palette — everything but `industrial`."
  def fixed_presets, do: Enum.filter(@themes, &(&1.palette != nil))

  # --- the agent slot ------------------------------------------------------

  @doc """
  The agent's saved theme as a picker entry, or `nil` when it has never painted.

  Same rule as `custom/0`: a stored palette that has lost a field or gained a bad
  colour resolves to `nil` rather than to something partly applied.

  Deliberately **not** re-checked against `legibility/1` here. Reading is not the
  point of enforcement — `set_agent/2` is, and it is the only writer. Making the
  reader re-judge would mean a floor the operator could tighten under a palette
  they were already looking at, which is the "seeded defaults have no upgrade
  path" trap in reverse.
  """
  def agent do
    with colors when is_binary(colors) <- Settings.get(@agent_colors_setting),
         {:ok, decoded} <- Jason.decode(colors),
         {:ok, palette} <- validate_palette(decoded) do
      %{
        key: @agent_key,
        label: agent_name(),
        swatch: %{
          bg: palette["background"],
          fg: palette["foreground"],
          accent: palette["cursor"]
        },
        palette: palette
      }
    else
      _ -> nil
    end
  end

  @doc "The agent theme's name, or the fallback when it has never been named."
  def agent_name do
    case Settings.get(@agent_name_setting) do
      name when is_binary(name) and name != "" -> name
      _ -> @agent_default_name
    end
  end

  @doc """
  Paint the agent's slot. **Never touches the operator's.**

  `colors` may be **partial** — this is the one place that diverges from
  `set_custom/3`, and the moduledoc says why. Whatever is given is merged over a
  base and the *result* is validated whole:

    * the agent's own current palette, if it has painted before — so successive
      paints accumulate rather than each one starting from scratch;
    * otherwise `#{@agent_base_key}`, for the reasons at `@agent_base_key`.

  `name` may be `nil`, meaning "keep whatever this slot is already called" (and
  `#{@agent_default_name}` when it has never been named), so a repaint does not
  have to re-state a name it did not change.

  The merged palette must pass `validate_palette/1` **and** `legibility/1`.
  Refusal is whole-palette, matching the rest of this module: a failure returns
  the reason rather than writing a partial theme.

  Returns `{:ok, theme}`, `{:error, :invalid_colors}`, `{:error, :invalid_name}`,
  `{:error, {:unknown_field, name}}` or `{:error, {:illegible, field, ratio}}`.
  """
  def set_agent(name, colors) when is_map(colors) do
    with {:ok, label} <- agent_label(name),
         {:ok, colors} <- known_fields_only(colors),
         {:ok, palette} <- validate_palette(merge_over_agent_base(colors)),
         :ok <- legibility(palette) do
      Settings.put(@agent_name_setting, label)
      Settings.put(@agent_colors_setting, Jason.encode!(palette))
      {:ok, agent()}
    else
      # `validate_palette/1`'s bare `:error`, kept in its vocabulary here.
      :error -> {:error, :invalid_colors}
      {:error, reason} -> {:error, reason}
    end
  end

  def set_agent(_name, _colors), do: {:error, :invalid_colors}

  @doc "Forget the agent's theme. Idempotent. Leaves the operator's slot alone."
  def clear_agent do
    Settings.delete(@agent_colors_setting)
    Settings.delete(@agent_name_setting)
    :ok
  end

  # No `broadcast/0` on either agent write, and that is a decision.
  # `{:terminal_theme, custom()}` means "the operator's saved palette changed" and
  # carries `custom()` as its payload — firing it here would announce an edit that
  # did not happen. Live apply for a socket-less writer is
  # `BusterClaw.TerminalPaint.announce/2`, which is a different message on a
  # different topic on purpose (see that module).

  # Merging costs the typo detector that `set_custom/3` gets for free.
  #
  # There, every field must be present, so a misspelled key shows up as a missing
  # one and the save is refused. Here a misspelled key is simply not merged: the
  # base palette validates, clears the floor, saves — and the model is told
  # `{:ok, …}` for a paint that changed nothing. A silent no-op is the worst
  # possible answer to give something with no eyes, so the unknown key is named.
  defp known_fields_only(colors) do
    known = MapSet.new(fields(), &elem(&1, 0))

    case Enum.find(Map.keys(colors), &(not MapSet.member?(known, &1))) do
      nil -> {:ok, colors}
      unknown -> {:error, {:unknown_field, unknown}}
    end
  end

  defp merge_over_agent_base(colors) do
    base =
      case agent() do
        nil -> palette(@agent_base_key)
        theme -> theme.palette
      end

    Map.merge(base, colors)
  end

  defp agent_label(nil), do: {:ok, agent_name()}

  defp agent_label(name) when is_binary(name) do
    trimmed = String.trim(name)

    if trimmed == "" or String.length(trimmed) > @name_limit do
      {:error, :invalid_name}
    else
      {:ok, trimmed}
    end
  end

  defp agent_label(_name), do: {:error, :invalid_name}

  # --- the legibility floor ------------------------------------------------

  # Body text the operator reads continuously — WCAG 2.x's own number, and the
  # only one here that is derived rather than chosen.
  @foreground_floor 4.5

  # A position marker, not prose. It has to be findable, not readable.
  @cursor_floor 2.0

  # The ANSI rule COUNTS rather than requires, and the count is the design.
  #
  # Measured before writing it, and the measurement killed the first draft: with a
  # flat per-colour floor, **Monokai's ANSI `black` is byte-identical to its
  # background** (ratio 1.00) and Nord's scores 1.24 — so "every ANSI colour
  # clears 2.0" would have refused both shipped presets. Nord's `brightBlack`
  # (1.69) would have taken it out twice over. That is not a flaw in those themes;
  # it is what ANSI black *is* in a dark terminal.
  #
  # Do not "fix" this by exempting `black` by name. The threat was never one dim
  # colour, it was **every colour at background** — which blanks `ls`, `git status`
  # and the agent's own status lines while plain text keeps working, so the
  # terminal still looks like it is doing something. Requiring 10 of 16 permits a
  # black and a dim bright-black beside it and still makes a wholesale blackout
  # impossible. The shipped presets clear it with room: Monokai 15, Nord 14.
  @ansi_floor 2.0
  @ansi_required 10

  @doc """
  Whether a palette can be read at all: `:ok` or `{:error, {:illegible, field, ratio}}`.

  WCAG 2.x relative luminance, contrast `(L1 + 0.05) / (L2 + 0.05)`:

  | Pair | Floor |
  |---|---|
  | `foreground` : `background` | #{@foreground_floor} |
  | `cursor` : `background` | #{@cursor_floor} |
  | the 16 ANSI colours | at least #{@ansi_required} of 16 clear #{@ansi_floor} |

  Deliberately silent on three things. It does not check contrast **between** ANSI
  colours — red on green is hideous and readable, which is the operator's problem
  and the model's joke. It does not check `selectionBackground` or `cursorAccent`,
  since neither carries the agent's output. And it is not a global policy: the
  operator may still hand-edit anything they like in the theme editor.

  `field` names the **worst offender**, ranked by how far short of its own floor it
  falls rather than by raw ratio, because 3.0 against 4.5 is a worse failure than
  1.9 against 2.0 and the model needs to be sent at the right one. `ratio` is the
  measurement, rounded, so a refusal is correctable rather than a guessing game.

  A palette that is not complete and well-formed answers `{:error, :invalid_colors}`
  — legibility is only meaningful on one that would pass `validate_palette/1`.
  """
  def legibility(colors) when is_map(colors) do
    case validate_palette(colors) do
      {:ok, palette} -> worst_offender(palette)
      :error -> {:error, :invalid_colors}
    end
  end

  def legibility(_colors), do: {:error, :invalid_colors}

  defp worst_offender(palette) do
    background = palette["background"]

    failures =
      Enum.reject(
        [
          below_floor(palette["foreground"], background, "foreground", @foreground_floor),
          below_floor(palette["cursor"], background, "cursor", @cursor_floor),
          ansi_shortfall(palette, background)
        ],
        &is_nil/1
      )

    case failures do
      [] ->
        :ok

      _ ->
        {field, ratio, _floor} = Enum.min_by(failures, fn {_f, r, floor} -> r / floor end)
        {:error, {:illegible, field, Float.round(ratio, 2)}}
    end
  end

  defp below_floor(hex, background, field, floor) do
    ratio = contrast(hex, background)
    if ratio < floor, do: {field, ratio, floor}, else: nil
  end

  # The named field is the MARGINAL one — the 10th best, i.e. `@ansi_required` —
  # not the worst. Naming the worst would name `black` in every dark theme written,
  # and black is the colour the count exists to permit; sending the model to fix it
  # would be sending it to fix the wrong thing. The 10th-best is the colour whose
  # ratio actually decides the check, and raising it (and anything below it) is the
  # correction that works.
  defp ansi_shortfall(palette, background) do
    {field, ratio} =
      @ansi_fields
      |> Enum.map(fn {field, _label} -> {field, contrast(palette[field], background)} end)
      |> Enum.sort_by(&elem(&1, 1), :desc)
      |> Enum.at(@ansi_required - 1)

    if ratio < @ansi_floor, do: {field, ratio, @ansi_floor}, else: nil
  end

  defp contrast(a, b) do
    {lighter, darker} =
      case {relative_luminance(a), relative_luminance(b)} do
        {la, lb} when la >= lb -> {la, lb}
        {la, lb} -> {lb, la}
      end

    (lighter + 0.05) / (darker + 0.05)
  end

  # WCAG 2.x relative luminance. Every value reaching here has already cleared
  # `normalize_hex/1`, so the `#rrggbb` shape is a given rather than a check.
  defp relative_luminance("#" <> hex) do
    0.2126 * linear(hex, 0) + 0.7152 * linear(hex, 2) + 0.0722 * linear(hex, 4)
  end

  defp linear(hex, offset) do
    channel = String.to_integer(String.slice(hex, offset, 2), 16) / 255

    if channel <= 0.03928,
      do: channel / 12.92,
      else: :math.pow((channel + 0.055) / 1.055, 2.4)
  end

  # --- generating a palette from one number --------------------------------

  @doc "The hue range the spectrum slider spans."
  def hue_range, do: 0..359

  @doc "The hue a never-generated custom theme starts at — the app's hazard orange."
  def default_hue, do: 14

  @doc "The hue the saved custom theme was generated at, or `default_hue/0`."
  def custom_hue do
    with value when is_binary(value) <- Settings.get(@custom_hue_setting),
         {hue, ""} <- Integer.parse(value),
         true <- hue in hue_range() do
      hue
    else
      _ -> default_hue()
    end
  end

  # Canonical hues for the eight named colours. These barely move, because their
  # meanings do not: red is error output in every program ever written, and a
  # "spectrum" that slid red round to green would produce a theme that lies.
  @ansi_hues %{
    "black" => nil,
    "red" => 358,
    "green" => 122,
    "yellow" => 45,
    "blue" => 214,
    "magenta" => 300,
    "cyan" => 186,
    "white" => nil
  }

  # How far a program colour is pulled toward the chosen hue. Enough that the
  # palette reads as one family, far too little to change what a colour means.
  @ansi_pull 0.15

  @doc """
  A complete palette generated from one hue.

  The whole point of the slider: `hue` tints the **surfaces** completely —
  background, text, cursor and selection are that hue at fixed saturation and
  lightness — while the sixteen program colours keep their canonical hues and are
  pulled only #{trunc(@ansi_pull * 100)}% toward it. So dragging the slider changes
  the terminal's whole mood without ever making `red` something other than red.

  Deterministic: the same hue always produces the same palette, which is what lets
  the slider be re-draggable rather than a one-shot roll.

  Dark by construction. A light generated theme is a different scheme (the
  lightnesses invert and the pull has to change), not a parameter — and every
  surviving preset is dark. Someone who wants a light terminal can still set the
  background by hand.
  """
  def generate(hue) when is_integer(hue) do
    h = Integer.mod(hue, 360)

    surfaces = %{
      "background" => hsl(h, 0.18, 0.07),
      "foreground" => hsl(h, 0.12, 0.88),
      "cursor" => hsl(h, 0.85, 0.60),
      "cursorAccent" => hsl(h, 0.18, 0.07),
      "selectionBackground" => hsl(h, 0.30, 0.22)
    }

    Enum.reduce(@ansi_fields, surfaces, fn {field, _label}, acc ->
      Map.put(acc, field, ansi_color(field, h))
    end)
  end

  defp ansi_color("brightBlack", h), do: hsl(h, 0.12, 0.42)
  defp ansi_color("brightWhite", h), do: hsl(h, 0.08, 0.96)
  defp ansi_color("black", h), do: hsl(h, 0.16, 0.16)
  defp ansi_color("white", h), do: hsl(h, 0.10, 0.80)

  defp ansi_color("bright" <> rest, h) do
    name = String.downcase(String.slice(rest, 0, 1)) <> String.slice(rest, 1..-1//1)
    hsl(pulled_hue(name, h), 0.72, 0.72)
  end

  defp ansi_color(name, h), do: hsl(pulled_hue(name, h), 0.58, 0.62)

  # Move `canonical` a fraction of the SHORT way round the wheel toward `h`. The
  # short way matters: red is 358 and a hue of 20 is 22 degrees away, not 338.
  defp pulled_hue(name, h) do
    canonical = Map.fetch!(@ansi_hues, name)
    delta = Integer.mod(h - canonical + 180, 360) - 180
    Integer.mod(canonical + round(delta * @ansi_pull), 360)
  end

  # HSL to #rrggbb. Written here rather than pulled in because it is fifteen lines
  # and the alternative is a dependency for one function.
  defp hsl(h, s, l) do
    c = (1 - abs(2 * l - 1)) * s
    hp = h / 60
    x = c * (1 - abs(:math.fmod(hp, 2) - 1))

    {r1, g1, b1} =
      case trunc(hp) do
        0 -> {c, x, 0.0}
        1 -> {x, c, 0.0}
        2 -> {0.0, c, x}
        3 -> {0.0, x, c}
        4 -> {x, 0.0, c}
        _ -> {c, 0.0, x}
      end

    m = l - c / 2
    "#" <> channel(r1 + m) <> channel(g1 + m) <> channel(b1 + m)
  end

  defp channel(value) do
    value
    |> max(0.0)
    |> min(1.0)
    |> Kernel.*(255)
    |> round()
    |> Integer.to_string(16)
    |> String.downcase()
    |> String.pad_leading(2, "0")
  end

  # Every field present, every value a #rrggbb literal. Strict on both counts: the
  # values are handed to xterm AND interpolated into the swatch's `style`
  # attribute, so an unvalidated one is a markup question rather than a styling
  # one, and a missing one is a theme that applies to some of the terminal.
  #
  # (`BusterClaw.Appearance` has the same hex rule as a private helper for its
  # 3-colour shader palettes. Two copies of one regex is not worth a module; a
  # third should be.)
  defp validate_palette(colors) when is_map(colors) do
    names = Enum.map(fields(), &elem(&1, 0))

    palette =
      Map.new(names, fn name ->
        {name, colors |> Map.get(name) |> normalize_hex()}
      end)

    if Enum.any?(palette, fn {_name, hex} -> is_nil(hex) end) do
      :error
    else
      {:ok, palette}
    end
  end

  defp validate_palette(_colors), do: :error

  defp normalize_hex(hex) when is_binary(hex) do
    trimmed = hex |> String.trim() |> String.downcase()
    if Regex.match?(~r/^#[0-9a-f]{6}$/, trimmed), do: trimmed, else: nil
  end

  defp normalize_hex(_hex), do: nil

  @doc "PubSub topic a custom-theme change is announced on."
  def topic, do: "terminal:theme"

  @doc "Subscribe the calling process to custom-theme changes."
  def subscribe, do: Phoenix.PubSub.subscribe(BusterClaw.PubSub, topic())

  defp broadcast do
    Phoenix.PubSub.broadcast(BusterClaw.PubSub, topic(), {:terminal_theme, custom()})
  end

  @doc """
  The `key => palette` map the browser applies, as JSON for the root layout's
  `<meta>` tag.

  `industrial` is present with a `null` palette. Present, because `theme.js`
  checks membership to tell "token-derived" apart from "not a theme at all"; and
  the whole map is emitted rather than only the selected theme so that switching
  costs no round-trip.
  """
  def payload_json do
    themes()
    |> Map.new(&{&1.key, &1.palette})
    |> Jason.encode!()
  end
end
