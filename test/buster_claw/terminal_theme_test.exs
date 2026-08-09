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
    defp nord_copy(overrides \\ %{}) do
      {:ok, palette} = TerminalTheme.copy_of("nord")
      Map.merge(palette, overrides)
    end

    test "nothing saved means no custom theme and no fourth key" do
      assert TerminalTheme.custom() == nil
      assert TerminalTheme.keys() == TerminalTheme.preset_keys()
    end

    test "a copy of a preset is a complete palette" do
      # The whole reason the editor opens on a copy: 22 values, so a custom theme
      # can never be the half-applied thing where the background is yours and `ls`
      # is xterm's.
      {:ok, palette} = TerminalTheme.copy_of("nord")

      for {field, _label} <- TerminalTheme.fields() do
        assert Map.has_key?(palette, field), "a copy is missing #{field}"
      end

      assert map_size(palette) == length(TerminalTheme.fields())
    end

    test "industrial cannot be copied, and is not offered as a starting point" do
      # It is token-derived, so there are no fixed colours to copy. Offering it
      # would either snapshot whichever app theme happened to be on or produce a
      # palette missing its ANSI values.
      assert TerminalTheme.copy_of("industrial") == {:error, :not_copyable}
      refute "industrial" in Enum.map(TerminalTheme.starting_points(), & &1.key)
      assert Enum.map(TerminalTheme.starting_points(), & &1.key) == ["nord", "monokai"]
    end

    test "saving appears in the picker, last, with a swatch of its own colours" do
      assert {:ok, theme} =
               TerminalTheme.set_custom("Mine", nord_copy(%{"background" => "#010203"}))

      assert theme.key == TerminalTheme.custom_key()
      assert theme.label == "Mine"
      assert theme.swatch.bg == "#010203"
      assert List.last(TerminalTheme.keys()) == TerminalTheme.custom_key()
      assert TerminalTheme.valid?(TerminalTheme.custom_key())
    end

    test "it survives being read back, and reaches the browser payload" do
      TerminalTheme.set_custom("Mine", nord_copy(%{"background" => "#010203"}))

      assert TerminalTheme.palette("custom")["background"] == "#010203"
      assert Jason.decode!(TerminalTheme.payload_json())["custom"]["background"] == "#010203"
    end

    test "colours are normalized, and a bad one is refused whole" do
      assert {:ok, theme} = TerminalTheme.set_custom("Mine", nord_copy(%{"red" => "  #AABBCC "}))
      assert theme.palette["red"] == "#aabbcc"

      # Refused rather than partly applied: these strings go to xterm AND into the
      # swatch's `style` attribute.
      assert {:error, :invalid_colors} =
               TerminalTheme.set_custom("Mine", nord_copy(%{"red" => "red"}))

      assert {:error, :invalid_colors} =
               TerminalTheme.set_custom("Mine", nord_copy(%{"red" => "#fff"}))

      assert {:error, :invalid_colors} =
               TerminalTheme.set_custom(
                 "Mine",
                 nord_copy(%{"red" => "#aabbcc; background: url(x)"})
               )
    end

    test "a partial palette is refused rather than merged" do
      # The editor always holds a complete palette, so a partial save means a form
      # that lost inputs — merging would accept it silently.
      assert {:error, :invalid_colors} =
               TerminalTheme.set_custom("Mine", %{"background" => "#010203"})
    end

    test "a name is required, and bounded" do
      assert {:error, :invalid_name} = TerminalTheme.set_custom("   ", nord_copy())

      assert {:error, :invalid_name} =
               TerminalTheme.set_custom(String.duplicate("x", 41), nord_copy())

      assert {:ok, theme} = TerminalTheme.set_custom("  Trimmed  ", nord_copy())
      assert theme.label == "Trimmed"
    end

    test "a stored palette that has gone bad resolves to no custom theme" do
      # Not to a partly-applied one: a half-written palette would leave the
      # terminal in a state no preset could explain.
      TerminalTheme.set_custom("Mine", nord_copy())
      BusterClaw.Settings.put("terminal_custom_theme_colors", ~s({"background":"nope"}))

      assert TerminalTheme.custom() == nil
      assert TerminalTheme.keys() == TerminalTheme.preset_keys()

      BusterClaw.Settings.put("terminal_custom_theme_colors", "not json at all")
      assert TerminalTheme.custom() == nil
    end

    test "deleting forgets it, idempotently" do
      TerminalTheme.set_custom("Mine", nord_copy())
      assert TerminalTheme.custom()

      assert TerminalTheme.clear_custom() == :ok
      assert TerminalTheme.custom() == nil
      assert TerminalTheme.clear_custom() == :ok
    end

    test "saving and deleting are announced" do
      TerminalTheme.subscribe()

      TerminalTheme.set_custom("Mine", nord_copy())
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
      # The editor copies a preset and then saves it back through validation, so a
      # preset that carried an unknown key or missed one would make its own copy
      # unsavable. This test caught exactly that: `selectionForeground` was in the
      # field list and in neither preset, so no copy could ever be saved.
      for preset <- TerminalTheme.starting_points() do
        assert Enum.sort(Map.keys(preset.palette)) ==
                 Enum.sort(Enum.map(TerminalTheme.fields(), &elem(&1, 0))),
               "#{preset.key}'s palette does not match the editor's field list"
      end
    end
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
