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

  @default "industrial"

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

  @keys Enum.map(@themes, & &1.key)

  @doc "Every theme as `%{key, label, swatch, palette}`, in picker order."
  def themes, do: @themes

  @doc "Every valid theme key, in picker order."
  def keys, do: @keys

  @doc "The theme an unset or unrecognized selection resolves to."
  def default, do: @default

  @doc "Whether `key` names a theme that exists."
  def valid?(key), do: key in @keys

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
    case Enum.find(@themes, &(&1.key == key)) do
      nil -> nil
      theme -> Map.get(theme, field)
    end
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
    @themes
    |> Map.new(&{&1.key, &1.palette})
    |> Jason.encode!()
  end
end
