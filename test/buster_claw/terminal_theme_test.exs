defmodule BusterClaw.TerminalThemeTest do
  # The catalog half is pure data; the custom slot writes Settings rows. The point
  # of all of it is that nothing asserted anything about terminal themes before —
  # the Elixir list and the JS palette table were two copies held together by a
  # comment.
  use BusterClaw.DataCase, async: true

  alias BusterClaw.TerminalTheme

  @js Path.expand("../../assets/js/lib/theme.js", __DIR__)

  describe "the catalog" do
    test "the default is a theme that exists, and leads the picker" do
      assert TerminalTheme.default() in TerminalTheme.keys()
      assert hd(TerminalTheme.keys()) == TerminalTheme.default()
    end

    test "every theme has a key, a label and three swatch colours" do
      for theme <- TerminalTheme.themes() do
        assert is_binary(theme.key) and theme.key != ""
        assert is_binary(theme.label) and theme.label != ""

        for channel <- [:bg, :fg, :accent] do
          assert Regex.match?(~r/^#[0-9a-f]{6}$/, Map.fetch!(theme.swatch, channel)),
                 "#{theme.key}'s #{channel} swatch is not a #rrggbb literal"
        end
      end
    end

    test "every colour in every palette is a #rrggbb literal" do
      # These strings are handed to xterm and interpolated into a `style`
      # attribute for the swatch. A malformed one is a markup question, not a
      # styling one, so the shipped palettes are held to the same rule a
      # user-entered colour will be.
      for theme <- TerminalTheme.themes(), theme.palette != nil, {name, hex} <- theme.palette do
        assert Regex.match?(~r/^#[0-9a-f]{6}$/, hex),
               "#{theme.key}'s #{name} is #{inspect(hex)}, not a #rrggbb literal"
      end
    end

    test "industrial is token-derived, and it is the only one" do
      # `nil` means "resolve from the app's live CSS tokens in the browser", which
      # is what makes it follow the light/dark switch. It is also the default, so
      # flattening it to fixed hex would silently stop the default theme tracking
      # the app.
      assert TerminalTheme.palette("industrial") == nil

      derived = Enum.filter(TerminalTheme.themes(), &(&1.palette == nil))
      assert Enum.map(derived, & &1.key) == ["industrial"]
    end

    test "a key that is not a theme answers nil rather than raising" do
      refute TerminalTheme.valid?("vaporwave")
      assert TerminalTheme.label("vaporwave") == nil
      assert TerminalTheme.swatch("vaporwave") == nil
      assert TerminalTheme.palette("vaporwave") == nil
    end
  end

  describe "the cull (08-09)" do
    test "exactly three themes survive, in picker order" do
      # Named rather than counted: the operator chose these three, and a fourth
      # arriving should be a deliberate edit with a reason, not a drift.
      assert TerminalTheme.keys() == ["industrial", "nord", "monokai"]
    end

    test "the removed presets are gone from Elixir AND from the JS" do
      # The half-done removal is the whole risk here: deleting from one language
      # leaves either a dead palette or a swatch selecting a theme that no longer
      # exists, and nothing else in the suite would notice.
      js = File.read!(@js)

      for gone <- ~w(dracula solarized gruvbox tokyo-night matrix) do
        refute TerminalTheme.valid?(gone)
        refute js =~ gone, "#{gone} still appears in theme.js"
      end

      # "light" is checked separately: it is a word that legitimately appears in
      # this file's prose about the app's light/dark switch, so a bare substring
      # search would be a false positive.
      refute TerminalTheme.valid?("light")
      refute js =~ ~s(light:)
    end

    test "a stale selection resolves to the default rather than to nothing" do
      # The Elixir half of the contract; the resolving itself is in theme.js
      # (`currentTermTheme`), which this asserts is still doing it.
      refute TerminalTheme.valid?("dracula")
      assert TerminalTheme.valid?(TerminalTheme.default())

      js = File.read!(@js)
      assert js =~ "stored in termThemes() ? stored : TERM_THEME_DEFAULT"
    end
  end

  describe "the payload the browser reads" do
    test "carries every theme, with industrial present and null" do
      decoded = Jason.decode!(TerminalTheme.payload_json())

      assert Map.keys(decoded) |> Enum.sort() == Enum.sort(TerminalTheme.keys())

      # Present-with-null, not absent: theme.js uses membership to tell
      # "token-derived" apart from "not a theme at all".
      assert Map.has_key?(decoded, "industrial")
      assert decoded["industrial"] == nil
    end

    test "a fixed theme's palette survives the round trip intact" do
      decoded = Jason.decode!(TerminalTheme.payload_json())

      assert decoded["nord"] == TerminalTheme.palette("nord")
      assert decoded["nord"]["background"] == "#2e3440"
    end
  end

  describe "the custom slot" do
    defp generated(overrides \\ %{}) do
      Map.merge(TerminalTheme.generate(200), overrides)
    end

    test "nothing saved means no custom theme and no fourth key" do
      assert TerminalTheme.custom() == nil
      assert TerminalTheme.keys() == TerminalTheme.preset_keys()
    end

    test "saving appears in the picker, last, with a swatch of its own colours" do
      assert {:ok, theme} =
               TerminalTheme.set_custom("Mine", generated(%{"background" => "#010203"}))

      assert theme.key == TerminalTheme.custom_key()
      assert theme.label == "Mine"
      assert theme.swatch.bg == "#010203"
      assert List.last(TerminalTheme.keys()) == TerminalTheme.custom_key()
      assert TerminalTheme.valid?(TerminalTheme.custom_key())
    end

    test "it survives being read back, and reaches the browser payload" do
      TerminalTheme.set_custom("Mine", generated(%{"background" => "#010203"}))

      assert TerminalTheme.palette("custom")["background"] == "#010203"
      assert Jason.decode!(TerminalTheme.payload_json())["custom"]["background"] == "#010203"
    end

    test "colours are normalized, and a bad one is refused whole" do
      assert {:ok, theme} = TerminalTheme.set_custom("Mine", generated(%{"red" => "  #AABBCC "}))
      assert theme.palette["red"] == "#aabbcc"

      # Refused rather than partly applied: these strings go to xterm AND into the
      # swatch's `style` attribute.
      assert {:error, :invalid_colors} =
               TerminalTheme.set_custom("Mine", generated(%{"red" => "red"}))

      assert {:error, :invalid_colors} =
               TerminalTheme.set_custom("Mine", generated(%{"red" => "#fff"}))

      assert {:error, :invalid_colors} =
               TerminalTheme.set_custom(
                 "Mine",
                 generated(%{"red" => "#aabbcc; background: url(x)"})
               )
    end

    test "a partial palette is refused rather than merged" do
      # The editor always holds a complete palette, so a partial save means a form
      # that lost inputs — merging would accept it silently.
      assert {:error, :invalid_colors} =
               TerminalTheme.set_custom("Mine", %{"background" => "#010203"})
    end

    test "a name is required, and bounded" do
      assert {:error, :invalid_name} = TerminalTheme.set_custom("   ", generated())

      assert {:error, :invalid_name} =
               TerminalTheme.set_custom(String.duplicate("x", 41), generated())

      assert {:ok, theme} = TerminalTheme.set_custom("  Trimmed  ", generated())
      assert theme.label == "Trimmed"
    end

    test "a stored palette that has gone bad resolves to no custom theme" do
      # Not to a partly-applied one: a half-written palette would leave the
      # terminal in a state no preset could explain.
      TerminalTheme.set_custom("Mine", generated())
      BusterClaw.Settings.put("terminal_custom_theme_colors", ~s({"background":"nope"}))

      assert TerminalTheme.custom() == nil
      assert TerminalTheme.keys() == TerminalTheme.preset_keys()

      BusterClaw.Settings.put("terminal_custom_theme_colors", "not json at all")
      assert TerminalTheme.custom() == nil
    end

    test "deleting forgets it, idempotently" do
      TerminalTheme.set_custom("Mine", generated())
      assert TerminalTheme.custom()

      assert TerminalTheme.clear_custom() == :ok
      assert TerminalTheme.custom() == nil
      assert TerminalTheme.clear_custom() == :ok
    end

    test "saving and deleting are announced" do
      TerminalTheme.subscribe()

      TerminalTheme.set_custom("Mine", generated())
      assert_receive {:terminal_theme, %{key: "custom"}}

      TerminalTheme.clear_custom()
      assert_receive {:terminal_theme, nil}
    end

    test "the field list is the five core plus the sixteen ANSI, no overlap" do
      core = Enum.map(TerminalTheme.core_fields(), &elem(&1, 0))
      ansi = Enum.map(TerminalTheme.ansi_fields(), &elem(&1, 0))

      assert length(core) == 5
      assert length(ansi) == 16
      assert core -- ansi == core
      assert Enum.map(TerminalTheme.fields(), &elem(&1, 0)) == core ++ ansi
      assert Enum.uniq(core ++ ansi) == core ++ ansi
    end

    test "a preset's palette covers exactly the field list" do
      # A preset carrying an unknown key or missing one could not be edited through
      # the same form a generated palette is. This test caught exactly that when the
      # editor still copied presets: `selectionForeground` was in the field list and
      # in neither preset, so no copy could ever be saved.
      for preset <- TerminalTheme.fixed_presets() do
        assert Enum.sort(Map.keys(preset.palette)) ==
                 Enum.sort(Enum.map(TerminalTheme.fields(), &elem(&1, 0))),
               "#{preset.key}'s palette does not match the editor's field list"
      end
    end
  end

  describe "generating from a hue" do
    test "one hue produces a complete, valid palette" do
      palette = TerminalTheme.generate(14)

      assert map_size(palette) == length(TerminalTheme.fields())

      for {field, _label} <- TerminalTheme.fields() do
        hex = Map.fetch!(palette, field)

        assert Regex.match?(~r/^#[0-9a-f]{6}$/, hex),
               "generated #{field} is #{inspect(hex)}, not a #rrggbb literal"
      end
    end

    test "it is deterministic, and it is savable" do
      # Deterministic is what lets the slider be dragged back and forth rather than
      # being a one-shot roll.
      assert TerminalTheme.generate(200) == TerminalTheme.generate(200)

      # And it must survive the same validator a hand-edited palette faces —
      # a generator that produced something unsavable would be a slider that
      # silently did nothing.
      assert {:ok, _theme} = TerminalTheme.set_custom("Generated", TerminalTheme.generate(200))
    end

    test "every hue in the range generates something savable" do
      # Cheap, and it catches the float edges: hue 0 and 360 land on the seam of the
      # HSL sector table, where an off-by-one gives a nil channel.
      for hue <- 0..359 do
        palette = TerminalTheme.generate(hue)

        assert map_size(palette) == length(TerminalTheme.fields())

        for {_field, hex} <- palette do
          assert Regex.match?(~r/^#[0-9a-f]{6}$/, hex), "hue #{hue} produced #{inspect(hex)}"
        end
      end
    end

    test "hues wrap rather than raising" do
      assert TerminalTheme.generate(360) == TerminalTheme.generate(0)
      assert TerminalTheme.generate(-10) == TerminalTheme.generate(350)
    end

    test "the slider changes the surfaces" do
      # If dragging it did not visibly change the terminal, it would be a control
      # that lies.
      a = TerminalTheme.generate(20)
      b = TerminalTheme.generate(200)

      for field <- ~w(background foreground cursor selectionBackground) do
        refute a[field] == b[field], "#{field} did not move with the hue"
      end
    end

    test "red stays red, and green stays green, at every hue" do
      # The load-bearing constraint of the whole scheme. A spectrum that slid `red`
      # round to green would produce a theme that lies about program output — red
      # means error in every program ever written.
      for hue <- [0, 60, 120, 180, 240, 300] do
        palette = TerminalTheme.generate(hue)

        assert dominant(palette["red"]) == :r, "red went wrong at hue #{hue}"
        assert dominant(palette["green"]) == :g, "green went wrong at hue #{hue}"
        assert dominant(palette["blue"]) == :b, "blue went wrong at hue #{hue}"
      end
    end

    test "a generated theme is dark, on purpose" do
      # Every surviving preset is dark and a light scheme is a different set of
      # lightnesses, not a parameter. Stated so a later "add a light mode" is a
      # decision rather than a tweak.
      for hue <- [0, 90, 180, 270] do
        palette = TerminalTheme.generate(hue)

        assert luminance(palette["background"]) < 0.2
        assert luminance(palette["foreground"]) > 0.7
      end
    end

    test "the hue is remembered so the slider knows where it is" do
      assert TerminalTheme.custom_hue() == TerminalTheme.default_hue()

      TerminalTheme.set_custom("Generated", TerminalTheme.generate(200), 200)
      assert TerminalTheme.custom_hue() == 200

      # Junk in the row resolves rather than raising.
      BusterClaw.Settings.put("terminal_custom_theme_hue", "banana")
      assert TerminalTheme.custom_hue() == TerminalTheme.default_hue()
    end

    test "clearing forgets the hue too" do
      TerminalTheme.set_custom("Generated", TerminalTheme.generate(200), 200)
      TerminalTheme.clear_custom()

      assert TerminalTheme.custom_hue() == TerminalTheme.default_hue()
    end
  end

  describe "the editor's groups" do
    test "the three groups cover every field exactly once, in order" do
      grouped = Enum.flat_map(TerminalTheme.field_groups(), fn {_t, _b, fields} -> fields end)

      assert grouped == TerminalTheme.fields()
      assert length(TerminalTheme.field_groups()) == 3
    end

    test "each group has a title, a blurb and fields" do
      for {title, blurb, fields} <- TerminalTheme.field_groups() do
        assert is_binary(title) and title != ""
        assert is_binary(blurb) and blurb != ""
        assert fields != []
      end
    end

    test "the eight and their bright variants are split, and pair up" do
      [_surfaces, {_t, _b, normal}, {_t2, _b2, bright}] = TerminalTheme.field_groups()

      assert length(normal) == 8
      assert length(bright) == 8

      # Same eight names in the same order, so the two groups read as a pair rather
      # than as sixteen unrelated swatches.
      normal_names = Enum.map(normal, &elem(&1, 0))
      bright_names = Enum.map(bright, fn {name, _label} -> name end)

      assert bright_names ==
               Enum.map(normal_names, fn name ->
                 "bright" <>
                   String.upcase(String.slice(name, 0, 1)) <> String.slice(name, 1..-1//1)
               end)
    end
  end

  # Which channel is largest — a coarse "is this still red?" that does not depend on
  # the exact saturation and lightness the scheme happens to use.
  defp dominant("#" <> hex) do
    {r, g, b} = channels(hex)

    cond do
      r >= g and r >= b -> :r
      g >= r and g >= b -> :g
      true -> :b
    end
  end

  defp luminance("#" <> hex) do
    {r, g, b} = channels(hex)
    (0.2126 * r + 0.7152 * g + 0.0722 * b) / 255
  end

  defp channels(hex) do
    {String.to_integer(String.slice(hex, 0, 2), 16),
     String.to_integer(String.slice(hex, 2, 2), 16),
     String.to_integer(String.slice(hex, 4, 2), 16)}
  end

  describe "the JS half of the contract" do
    # The failure this exists for: a palette literal creeping back into theme.js,
    # so the two lists drift again and the suite stays green — which is exactly
    # what happened before this module existed.
    test "theme.js defines no palettes of its own" do
      js = File.read!(@js)

      refute js =~ "brightMagenta",
             "theme.js is defining xterm palettes again. TerminalTheme owns the " <>
               "list; theme.js applies it."

      hexes = Regex.scan(~r/#[0-9a-fA-F]{6}/, js) |> Enum.map(&hd/1) |> Enum.uniq()

      # The industrial resolver keeps fallbacks for the CSS tokens it reads, which
      # is the one legitimate reason for a colour literal in this file.
      assert Enum.sort(hexes) == Enum.sort(["#121212", "#fafafa", "#ff4d1c"]),
             "unexpected colour literals in theme.js: #{Enum.join(hexes, ", ")}"
    end

    test "theme.js reads the payload from the meta the layout renders" do
      js = File.read!(@js)

      layout =
        File.read!(
          Path.expand("../../lib/buster_claw_web/components/layouts/root.html.heex", __DIR__)
        )

      assert js =~ ~s(meta[name="bc-term-palettes"])
      assert layout =~ ~s(name="bc-term-palettes")
      assert layout =~ "TerminalTheme.payload_json()"
    end
  end
end
