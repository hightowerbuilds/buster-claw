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

  describe "the agent slot" do
    # A second dynamic slot, and the reason it exists is the reason these tests
    # keep checking the operator's: there was ONE slot, `set_custom/3` overwrites
    # it wholesale, and an agent writing a colour would have deleted a theme the
    # operator built with a slider and named.
    defp monokai do
      TerminalTheme.fixed_presets()
      |> Enum.find(&(&1.key == "monokai"))
      |> Map.fetch!(:palette)
    end

    test "nothing painted means no agent theme and no extra key" do
      assert TerminalTheme.agent() == nil
      assert TerminalTheme.agent_key() == "agent"
      assert TerminalTheme.keys() == TerminalTheme.preset_keys()
    end

    test "a paint appears in the picker with a swatch of its own colours" do
      assert {:ok, theme} = TerminalTheme.set_agent("Hazard", %{"background" => "#010203"})

      assert theme.key == TerminalTheme.agent_key()
      assert theme.label == "Hazard"
      assert theme.swatch.bg == "#010203"
      assert TerminalTheme.valid?(TerminalTheme.agent_key())
      assert List.last(TerminalTheme.keys()) == TerminalTheme.agent_key()
    end

    test "both dynamic slots can exist at once, the operator's first" do
      TerminalTheme.set_custom("Mine", TerminalTheme.generate(200))
      TerminalTheme.set_agent("Theirs", %{})

      assert TerminalTheme.keys() == TerminalTheme.preset_keys() ++ ["custom", "agent"]
    end

    test "an agent write leaves the operator's slot completely untouched" do
      # The whole point of D3, asserted at the level the slots are actually
      # separated at — the Settings rows — rather than by trusting that nobody
      # calls `set_custom/3` from the agent path.
      TerminalTheme.set_custom("Mine", TerminalTheme.generate(200), 200)

      before = TerminalTheme.custom()
      rows = custom_rows()

      assert {:ok, _theme} = TerminalTheme.set_agent("Theirs", %{"background" => "#010203"})

      assert TerminalTheme.custom() == before
      assert custom_rows() == rows
      assert TerminalTheme.custom_name() == "Mine"
      assert TerminalTheme.custom_hue() == 200
      refute TerminalTheme.custom().palette["background"] == "#010203"

      # And the reverse, since "separate" has two directions.
      TerminalTheme.clear_agent()
      assert TerminalTheme.custom() == before
      assert custom_rows() == rows
    end

    test "a partial paint merges over a preset rather than being refused" do
      # The one place this diverges from `set_custom/3`: the editor always holds a
      # complete palette, the agent has no form at all.
      assert {:ok, theme} = TerminalTheme.set_agent("Ember", %{"foreground" => "#ff8800"})

      assert theme.palette["foreground"] == "#ff8800"
      assert theme.palette["background"] == monokai()["background"]
      assert map_size(theme.palette) == length(TerminalTheme.fields())

      # And why the base cannot simply be the default theme: it has no palette to
      # merge onto. This is the assertion that would fail if someone "tidied"
      # @agent_base_key into `default()`.
      assert TerminalTheme.palette(TerminalTheme.default()) == nil
    end

    test "successive paints accumulate on the agent's own palette" do
      assert {:ok, _theme} = TerminalTheme.set_agent("One", %{"foreground" => "#ff8800"})
      assert {:ok, theme} = TerminalTheme.set_agent(nil, %{"cursor" => "#00ff00"})

      assert theme.palette["foreground"] == "#ff8800"
      assert theme.palette["cursor"] == "#00ff00"

      # A nil name keeps whatever the slot is already called, so a repaint does not
      # have to re-state a name it did not change.
      assert theme.label == "One"
    end

    test "an empty paint is a rename, not an error" do
      TerminalTheme.set_agent("One", %{"foreground" => "#ff8800"})

      assert {:ok, theme} = TerminalTheme.set_agent("Two", %{})
      assert theme.label == "Two"
      assert theme.palette["foreground"] == "#ff8800"
    end

    test "a name is optional, trimmed and bounded" do
      assert {:error, :invalid_name} = TerminalTheme.set_agent("   ", %{})
      assert {:error, :invalid_name} = TerminalTheme.set_agent(String.duplicate("x", 41), %{})

      assert {:ok, theme} = TerminalTheme.set_agent(nil, %{})
      assert theme.label == "Agent"

      assert {:ok, theme} = TerminalTheme.set_agent("  Trimmed  ", %{})
      assert theme.label == "Trimmed"
    end

    test "a bad colour is refused whole, and writes nothing" do
      assert {:error, :invalid_colors} = TerminalTheme.set_agent("X", %{"red" => "#fff"})
      assert {:error, :invalid_colors} = TerminalTheme.set_agent("X", %{"red" => "red"})

      assert {:error, :invalid_colors} =
               TerminalTheme.set_agent("X", %{"red" => "#aabbcc; background: url(x)"})

      assert {:error, :invalid_colors} = TerminalTheme.set_agent("X", "not a map")

      assert TerminalTheme.agent() == nil
    end

    test "a field name that is not a field is named, not ignored" do
      # Merging costs the typo detector `set_custom/3` gets for free: an unknown
      # key is simply not merged, so the base palette would validate, clear the
      # floor and save — reporting `{:ok, …}` for a paint that changed nothing.
      assert {:error, {:unknown_field, "foregruond"}} =
               TerminalTheme.set_agent("X", %{"foregruond" => "#ff8800"})

      assert TerminalTheme.agent() == nil
    end

    test "it survives being read back, and reaches the browser payload" do
      TerminalTheme.set_agent("Ember", %{"background" => "#010203"})

      assert TerminalTheme.palette("agent")["background"] == "#010203"
      assert Jason.decode!(TerminalTheme.payload_json())["agent"]["background"] == "#010203"
    end

    test "a stored palette that has gone bad resolves to no agent theme" do
      TerminalTheme.set_agent("Ember", %{})
      BusterClaw.Settings.put("terminal_agent_theme_colors", ~s({"background":"nope"}))

      assert TerminalTheme.agent() == nil
      assert TerminalTheme.keys() == TerminalTheme.preset_keys()

      BusterClaw.Settings.put("terminal_agent_theme_colors", "not json at all")
      assert TerminalTheme.agent() == nil
    end

    test "clearing forgets it, idempotently" do
      TerminalTheme.set_agent("Ember", %{})
      assert TerminalTheme.agent()

      assert TerminalTheme.clear_agent() == :ok
      assert TerminalTheme.agent() == nil
      assert TerminalTheme.agent_name() == "Agent"
      assert TerminalTheme.clear_agent() == :ok
    end

    test "painting does not announce an operator edit" do
      # `{:terminal_theme, custom()}` means "the operator's saved palette changed"
      # and carries `custom()` as its payload. Firing it here would announce an
      # edit that did not happen; live apply for a socket-less writer is
      # `TerminalPaint.announce/2`, on its own topic.
      TerminalTheme.subscribe()

      TerminalTheme.set_agent("Ember", %{})
      TerminalTheme.clear_agent()

      refute_receive {:terminal_theme, _payload}
    end

    defp custom_rows do
      Map.new(
        ~w(terminal_custom_theme_name terminal_custom_theme_colors terminal_custom_theme_hue),
        &{&1, BusterClaw.Settings.get(&1)}
      )
    end
  end

  describe "the legibility floor" do
    # What this prevents is not ugliness but DISAPPEARANCE: an agent that can set
    # `foreground` to `background` can hide its own output from the operator
    # watching it work.
    test "every shipped preset that has a palette passes" do
      # The test that would have caught the first draft of the rule — a per-colour
      # ANSI floor would have refused both of these.
      presets = TerminalTheme.fixed_presets()

      # Not vacuously green: this repo has shipped a guard over an empty
      # collection before.
      assert length(presets) >= 2

      for preset <- presets do
        assert TerminalTheme.legibility(preset.palette) == :ok,
               "#{preset.key} is refused by the floor its own numbers set"
      end
    end

    test "and so does every palette the slider can generate" do
      # The operator's generator is not gated by the floor, but a hue that could
      # produce something the agent slot would refuse means the two disagree about
      # what a usable terminal is.
      for hue <- 0..359 do
        assert TerminalTheme.legibility(TerminalTheme.generate(hue)) == :ok,
               "hue #{hue} generates a palette the floor refuses"
      end
    end

    test "foreground at background is refused, by name and by measurement" do
      background = monokai()["background"]

      assert {:error, {:illegible, "foreground", 1.0}} =
               TerminalTheme.legibility(Map.put(monokai(), "foreground", background))
    end

    test "cursor at background is refused" do
      background = monokai()["background"]

      assert {:error, {:illegible, "cursor", 1.0}} =
               TerminalTheme.legibility(Map.put(monokai(), "cursor", background))
    end

    test "every ANSI colour at background is refused" do
      # The nastiest of the three, because plain text keeps working: `ls`,
      # `git status` and the agent's own status lines go blank while the terminal
      # still looks like it is doing something.
      background = monokai()["background"]
      blanked = Enum.reduce(ansi_names(), monokai(), &Map.put(&2, &1, background))

      assert {:error, {:illegible, field, 1.0}} = TerminalTheme.legibility(blanked)
      assert field in ansi_names()
    end

    test "the ANSI rule counts, and ten of sixteen is the line" do
      # The count IS the design, so the boundary is worth pinning: six blanked
      # colours leave ten and pass, a seventh does not.
      legible = Enum.reduce(ansi_names(), monokai(), &Map.put(&2, &1, "#ffffff"))
      background = monokai()["background"]

      blank = fn count ->
        Enum.reduce(Enum.take(ansi_names(), count), legible, &Map.put(&2, &1, background))
      end

      assert TerminalTheme.legibility(blank.(6)) == :ok
      assert {:error, {:illegible, _field, 1.0}} = TerminalTheme.legibility(blank.(7))
    end

    test "an ANSI black identical to the background is permitted, on purpose" do
      # Measured here with the test's own WCAG implementation rather than the
      # module's, so this asserts the numbers the rule was chosen from rather than
      # asserting that the code agrees with itself.
      assert monokai()["black"] == monokai()["background"]
      assert wcag_ratio(monokai()["black"], monokai()["background"]) == 1.0

      nord =
        TerminalTheme.fixed_presets() |> Enum.find(&(&1.key == "nord")) |> Map.fetch!(:palette)

      assert wcag_ratio(nord["black"], nord["background"]) == 1.24
      assert wcag_ratio(nord["brightBlack"], nord["background"]) == 1.69

      # That is not a flaw in those themes; it is what ANSI black is in a dark
      # terminal. Exempting `black` by name instead of counting would still have
      # refused Nord for its bright black.
      assert TerminalTheme.legibility(monokai()) == :ok
      assert TerminalTheme.legibility(nord) == :ok
    end

    test "a hideous but legible palette is accepted — that is the toy working" do
      assert TerminalTheme.legibility(hideous()) == :ok
      assert {:ok, _theme} = TerminalTheme.set_agent("Regrettable", hideous())
    end

    test "the worst offender is the biggest shortfall, not the lowest ratio" do
      # #555555 scores 1.99 against Monokai's background and #535353 scores 1.93.
      # The cursor has the LOWER raw ratio, but it only has to clear 2.0 while the
      # foreground has to clear 4.5 — so the foreground is the worse failure and
      # the one the model needs to be sent at.
      palette =
        monokai()
        |> Map.put("foreground", "#555555")
        |> Map.put("cursor", "#535353")

      assert wcag_ratio("#535353", monokai()["background"]) <
               wcag_ratio("#555555", monokai()["background"])

      assert {:error, {:illegible, "foreground", 1.99}} = TerminalTheme.legibility(palette)
    end

    test "an incomplete or malformed palette answers invalid_colors rather than raising" do
      # Legibility is only meaningful on a palette that would pass validation, and
      # a command handler must not get an exception for a bad argument.
      assert TerminalTheme.legibility(%{"background" => "#000000"}) ==
               {:error, :invalid_colors}

      assert TerminalTheme.legibility(Map.put(monokai(), "red", "#fff")) ==
               {:error, :invalid_colors}

      assert TerminalTheme.legibility("nope") == {:error, :invalid_colors}
    end

    test "set_agent refuses an illegible paint, and the app's own orange is one" do
      # #ff4d1c is this app's hazard accent and it misses WCAG's body-text floor
      # against Monokai by 0.02. Kept as the example because it is exactly the
      # request the roadmap imagines — "make the foreground orange" — and it proves
      # the refusal is correctable rather than a wall: the ratio comes back with it.
      assert {:error, {:illegible, "foreground", 4.48}} =
               TerminalTheme.set_agent("Hazard", %{"foreground" => "#ff4d1c"})

      assert TerminalTheme.agent() == nil

      assert {:ok, _theme} = TerminalTheme.set_agent("Hazard", %{"foreground" => "#ff6a3c"})
    end

    test "a refused paint does not disturb one that already landed" do
      TerminalTheme.set_agent("Good", %{"foreground" => "#ff8800"})

      assert {:error, {:illegible, "foreground", _ratio}} =
               TerminalTheme.set_agent("Bad", %{"foreground" => monokai()["background"]})

      assert TerminalTheme.agent().label == "Good"
      assert TerminalTheme.agent().palette["foreground"] == "#ff8800"
    end

    defp ansi_names, do: Enum.map(TerminalTheme.ansi_fields(), &elem(&1, 0))

    # Garish, unbalanced, and perfectly readable. Every ANSI slot is a saturated
    # primary on black, which is what "the agent may make it ugly, it may not make
    # it invisible" means in practice.
    defp hideous do
      base = %{
        "background" => "#000000",
        "foreground" => "#00ff00",
        "cursor" => "#ff00ff",
        "cursorAccent" => "#000000",
        "selectionBackground" => "#0000ff"
      }

      ansi_names()
      |> Enum.with_index()
      |> Enum.reduce(base, fn {name, index}, acc ->
        Map.put(acc, name, Enum.at(~w(#ff00ff #00ffff #ffff00 #ffffff), rem(index, 4)))
      end)
    end

    # WCAG 2.x, written out here so the floor's numbers are asserted against an
    # independent implementation rather than against the module agreeing with
    # itself.
    defp wcag_ratio(a, b) do
      la = wcag_luminance(a)
      lb = wcag_luminance(b)
      {lighter, darker} = if la >= lb, do: {la, lb}, else: {lb, la}

      Float.round((lighter + 0.05) / (darker + 0.05), 2)
    end

    defp wcag_luminance("#" <> hex) do
      {r, g, b} = channels(hex)
      0.2126 * srgb(r) + 0.7152 * srgb(g) + 0.0722 * srgb(b)
    end

    defp srgb(value) do
      channel = value / 255
      if channel <= 0.03928, do: channel / 12.92, else: :math.pow((channel + 0.055) / 1.055, 2.4)
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
