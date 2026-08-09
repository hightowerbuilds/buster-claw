defmodule BusterClaw.TerminalThemeTest do
  # Pure data. The point of these is that nothing asserted anything about terminal
  # themes before — the Elixir list and the JS palette table were two copies held
  # together by a comment.
  use ExUnit.Case, async: true

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
