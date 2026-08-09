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
  """

  alias BusterClaw.Settings

  @default "industrial"

  # The one custom slot. A key rather than a list because "save a theme" was
  # singular: a library brings rename, delete, duplicate and an ordering question
  # with it, and none of those were asked for. The store below is shaped so a
  # second slot is a Settings key and a loop, not a redesign.
  @custom_key "custom"
  @custom_name_setting "terminal_custom_theme_name"
  @custom_colors_setting "terminal_custom_theme_colors"
  @custom_hue_setting "terminal_custom_theme_hue"
  @custom_default_name "Custom"

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

  @doc "The shipped themes, without the operator's custom slot."
  def presets, do: @themes

  @doc "Every shipped theme key."
  def preset_keys, do: @preset_keys

  @doc """
  Every theme in picker order, the custom slot last when one has been saved.

  Runtime rather than compile-time, because the custom slot is a `Settings` row.
  """
  def themes do
    case custom() do
      nil -> @themes
      theme -> @themes ++ [theme]
    end
  end

  @doc "Every valid theme key, in picker order."
  def keys, do: Enum.map(themes(), & &1.key)

  @doc "The theme an unset or unrecognized selection resolves to."
  def default, do: @default

  @doc "The key the custom slot occupies."
  def custom_key, do: @custom_key

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

    if trimmed == "" or String.length(trimmed) > 40 do
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
