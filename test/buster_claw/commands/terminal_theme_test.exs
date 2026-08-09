defmodule BusterClaw.Commands.TerminalThemeTest do
  # async: false — these verbs broadcast on a global PubSub topic, and an
  # `assert_receive` that can pick up a concurrent test's broadcast is a test
  # that passes for the wrong reason.
  use BusterClaw.DataCase, async: false

  alias BusterClaw.Commands
  alias BusterClaw.Commands.Catalog
  alias BusterClaw.{Settings, TerminalPaint, TerminalTheme}

  # The operator's slot, by its Settings keys. Named here rather than reached
  # for through `TerminalTheme` because the whole point of the assertion is that
  # the STORE is untouched — reading it through the module under test would let
  # a bug hide behind its own accessor.
  @custom_settings ~w(
    terminal_custom_theme_name
    terminal_custom_theme_colors
    terminal_custom_theme_hue
  )

  # Everything `BusterClaw.Commands.TerminalTheme` calls inside the BusterClaw
  # namespace, exactly. `set_custom/3` and `clear_custom/0` are absent, and this
  # list is the enforcement: D3 says the agent never writes the operator's slot,
  # and a name-blind reach list holds that even for a writer nobody has named
  # yet.
  @reach [
    {BusterClaw.TerminalPaint, :announce, 2},
    {BusterClaw.TerminalTheme, :agent, 0},
    {BusterClaw.TerminalTheme, :agent_key, 0},
    {BusterClaw.TerminalTheme, :clear_agent, 0},
    {BusterClaw.TerminalTheme, :custom, 0},
    {BusterClaw.TerminalTheme, :custom_key, 0},
    {BusterClaw.TerminalTheme, :default, 0},
    {BusterClaw.TerminalTheme, :fields, 0},
    {BusterClaw.TerminalTheme, :keys, 0},
    {BusterClaw.TerminalTheme, :label, 1},
    {BusterClaw.TerminalTheme, :palette, 1},
    {BusterClaw.TerminalTheme, :set_agent, 2},
    {BusterClaw.TerminalTheme, :themes, 0},
    {BusterClaw.TerminalTheme, :valid?, 1}
  ]

  setup do
    TerminalPaint.subscribe()
    on_exit(fn -> TerminalTheme.clear_agent() end)
    :ok
  end

  # A complete, legible palette to build partial paints on top of. Monokai
  # rather than a hand-rolled one because it is shipped, and because Part IV of
  # the roadmap measured it: 13.94:1 foreground contrast, and an ANSI `black`
  # byte-identical to its background that the 10-of-16 rule is designed to
  # permit.
  defp base_palette, do: TerminalTheme.palette("monokai")

  defp save_operator_theme do
    {:ok, _theme} = TerminalTheme.set_custom("Operator's own", base_palette(), 200)
    Map.new(@custom_settings, &{&1, Settings.get(&1)})
  end

  # --- terminal_theme_list ----------------------------------------------

  test "terminal_theme_list reports every theme, both slots, and the paintable fields" do
    assert {:ok, result} = Commands.call("terminal_theme_list", %{})

    assert result.default == TerminalTheme.default()

    keys = Enum.map(result.themes, & &1.key)
    assert keys == TerminalTheme.keys()
    assert "industrial" in keys

    industrial = Enum.find(result.themes, &(&1.key == "industrial"))
    assert industrial.label == "Industrial"
    assert industrial.swatch.bg == "#121212"
    # `palette: nil` is meaningful, not missing: industrial resolves from the
    # app's live CSS tokens in the browser and has no fixed colours to report.
    assert industrial.token_derived

    assert Enum.find(result.themes, &(&1.key == "monokai")).token_derived == false

    # 21 fields — 5 core + 16 ANSI — and they are what `paint` accepts.
    assert length(result.fields) == 21
    assert %{name: "foreground", label: "Text"} in result.fields

    assert result.slots.agent == %{
             key: TerminalTheme.agent_key(),
             saved: false,
             label: nil,
             writable: true
           }

    assert result.slots.custom.writable == false
  end

  test "terminal_theme_list shows a slot as saved once it holds a palette" do
    save_operator_theme()
    assert {:ok, _painted} = Commands.call("terminal_theme_paint", %{"colors" => base_palette()})

    assert {:ok, result} = Commands.call("terminal_theme_list", %{})

    assert %{saved: true, label: "Agent", writable: true} = result.slots.agent
    assert %{saved: true, label: "Operator's own", writable: false} = result.slots.custom
  end

  # --- terminal_theme_select --------------------------------------------

  test "terminal_theme_select announces the theme so every open terminal wears it" do
    assert {:ok, result} = Commands.call("terminal_theme_select", %{"key" => "nord"})

    assert result.selected == "nord"
    assert result.label == "Nord"
    assert result.applied

    # The palette rides along rather than being looked up client-side: a page
    # that loaded before a dynamic slot was written has never heard of it.
    assert_receive {:terminal_theme_apply, "nord", %{"background" => "#2e3440"}}
  end

  test "terminal_theme_select carries a nil palette for the token-derived theme" do
    assert {:ok, _result} = Commands.call("terminal_theme_select", %{"key" => "industrial"})
    assert_receive {:terminal_theme_apply, "industrial", nil}
  end

  test "terminal_theme_select refuses an unknown key with the valid keys named" do
    assert {:error, message} = Commands.call("terminal_theme_select", %{"key" => "dracula"})

    # A refusal a caller cannot read is a refusal it cannot correct, so this is
    # a sentence and not `inspect/1` output.
    assert is_binary(message)
    assert message =~ ~s(no terminal theme called "dracula")

    for key <- TerminalTheme.keys() do
      assert message =~ key, "the refusal should name #{key} as a valid key"
    end

    refute message =~ "[\""
    refute_receive {:terminal_theme_apply, _key, _palette}
  end

  test "terminal_theme_select without a key says so, and still names the keys" do
    assert {:error, message} = Commands.call("terminal_theme_select", %{})
    assert message =~ "needs a key"
    assert message =~ "industrial"
  end

  # --- terminal_theme_paint ---------------------------------------------

  test "terminal_theme_paint writes the agent slot, selects it, and announces it" do
    assert {:ok, result} = Commands.call("terminal_theme_paint", %{"colors" => base_palette()})

    assert result.selected == TerminalTheme.agent_key()
    assert result.applied
    assert result.palette["background"] == "#272822"

    assert_receive {:terminal_theme_apply, key, palette}
    assert key == TerminalTheme.agent_key()
    assert palette["background"] == "#272822"

    # And the slot is now a real picker entry.
    assert TerminalTheme.agent().key == TerminalTheme.agent_key()
    assert TerminalTheme.valid?(TerminalTheme.agent_key())
  end

  test "terminal_theme_paint takes a PARTIAL map and merges — that is the point" do
    assert {:ok, first} = Commands.call("terminal_theme_paint", %{"colors" => base_palette()})

    assert {:ok, second} =
             Commands.call("terminal_theme_paint", %{"colors" => %{"cursor" => "#00ff88"}})

    assert second.palette["cursor"] == "#00ff88"
    assert map_size(second.palette) == 21

    # Every other field survived. The agent has no form to hold a complete
    # palette in, so a partial save here is a colour change and not a broken
    # form — the one place this deliberately diverges from `set_custom/3`.
    unchanged = Map.drop(first.palette, ["cursor"])
    assert Map.drop(second.palette, ["cursor"]) == unchanged
  end

  test "terminal_theme_paint names the theme, and keeps the name when told only colours" do
    assert {:ok, named} =
             Commands.call("terminal_theme_paint", %{
               "colors" => base_palette(),
               "name" => "Hazard"
             })

    assert named.label == "Hazard"

    assert {:ok, again} =
             Commands.call("terminal_theme_paint", %{"colors" => %{"cursor" => "#00ff88"}})

    assert again.label == "Hazard"
  end

  test "terminal_theme_paint refuses a palette the operator could not read, and says why" do
    invisible = Map.put(base_palette(), "foreground", base_palette()["background"])

    assert {:error, message} = Commands.call("terminal_theme_paint", %{"colors" => invisible})

    assert is_binary(message)
    assert message =~ "foreground"
    # The ratio it actually scored, so the model can correct the field instead
    # of guessing at one.
    assert message =~ ~r/\d(\.\d+)?:1/
    assert message =~ "4.5:1"

    # Refused whole: nothing was written and nothing was worn.
    assert TerminalTheme.agent() == nil
    refute_receive {:terminal_theme_apply, _key, _palette}
  end

  test "terminal_theme_paint refuses a malformed colour as a sentence" do
    assert {:error, message} =
             Commands.call("terminal_theme_paint", %{"colors" => %{"foreground" => "orange"}})

    assert is_binary(message)
    assert message =~ "#rrggbb"
    assert TerminalTheme.agent() == nil
  end

  test "terminal_theme_paint without colors explains what it wanted" do
    assert {:error, message} = Commands.call("terminal_theme_paint", %{})
    assert message =~ "colors map"
    assert message =~ "terminal_theme_list"
  end

  # --- terminal_theme_reset ---------------------------------------------

  test "terminal_theme_reset clears the agent slot and wears the default" do
    assert {:ok, _painted} = Commands.call("terminal_theme_paint", %{"colors" => base_palette()})
    assert TerminalTheme.agent() != nil
    assert_receive {:terminal_theme_apply, _agent_key, _agent_palette}

    assert {:ok, result} = Commands.call("terminal_theme_reset", %{})

    assert result.selected == TerminalTheme.default()
    assert result.cleared

    # CLEARS rather than restores: which theme the operator had selected lives
    # in their browser's localStorage and the server has never known it, so the
    # honest reset is a state they can recognise.
    assert TerminalTheme.agent() == nil
    refute TerminalTheme.agent_key() in TerminalTheme.keys()

    assert_receive {:terminal_theme_apply, key, _palette}
    assert key == TerminalTheme.default()
  end

  test "terminal_theme_reset is idempotent with nothing painted" do
    assert {:ok, %{cleared: true}} = Commands.call("terminal_theme_reset", %{})
    assert TerminalTheme.agent() == nil
  end

  # --- D3: the operator's slot is untouchable ---------------------------

  describe "D3 — no verb touches the operator's custom slot" do
    test "a full walk of the surface leaves the custom Settings byte-identical" do
      before = save_operator_theme()
      assert map_size(before) == 3
      assert before["terminal_custom_theme_name"] == "Operator's own"

      assert {:ok, _list} = Commands.call("terminal_theme_list", %{})
      assert {:ok, _select} = Commands.call("terminal_theme_select", %{"key" => "nord"})

      assert {:ok, _paint} =
               Commands.call("terminal_theme_paint", %{
                 "colors" => %{"cursor" => "#00ff88"},
                 "name" => "Agent's own"
               })

      assert {:ok, _reset} = Commands.call("terminal_theme_reset", %{})

      assert Map.new(@custom_settings, &{&1, Settings.get(&1)}) == before

      # And it still resolves as a theme, under its own name, with its hue.
      assert TerminalTheme.custom().label == "Operator's own"
      assert TerminalTheme.custom_hue() == 200
    end

    test "the command module's reach is exactly the agent slot and the announce" do
      assert internal_calls(BusterClaw.Commands.TerminalTheme) == @reach,
             """
             `BusterClaw.Commands.TerminalTheme` calls something new inside BusterClaw.

             This list is name-blind on purpose. TERMINAL_PAINT_ROADMAP D3: there
             is one custom slot, `set_custom/3` overwrites it wholesale, and an
             agent writing there deletes a palette the operator built and named.
             If the new call is legitimate, add it here and say in the commit why
             the terminal-theme command surface needed to reach further.
             """
    end

    test "no catalogued command names the operator's custom slot" do
      offenders =
        Catalog.entries()
        |> Enum.filter(fn entry ->
          Regex.match?(~r/custom/i, entry.name) or
            Enum.any?(Map.keys(entry.args), &Regex.match?(~r/custom/i, &1))
        end)
        |> Enum.map(& &1.name)

      assert offenders == [], "a command names the custom slot: #{inspect(offenders)}"
    end
  end

  # --- the surface, and the tier it sits at ------------------------------

  describe "the catalog entry" do
    test "the surface is exactly four verbs: one safe read and three restricted writes" do
      entries =
        Catalog.entries()
        |> Enum.filter(&String.starts_with?(&1.name, "terminal_theme_"))
        |> Enum.sort_by(& &1.name)

      assert Enum.map(entries, & &1.name) == [
               "terminal_theme_list",
               "terminal_theme_paint",
               "terminal_theme_reset",
               "terminal_theme_select"
             ],
             """
             The terminal-theme surface changed. D6 is "four verbs, and no more
             until something asks" — no import, no export, no random, no
             animation, no per-surface theming. A fifth is a decision, not a
             detail.
             """

      for entry <- entries do
        # Not gated, deliberately: a confirmation dialog for a colour is
        # theatre, and the legibility floor is what makes unattended use safe.
        refute Map.get(entry, :gated, false), "#{entry.name}: must not be gated"
      end

      assert %{type: :read, tier: :safe} = Enum.find(entries, &(&1.name == "terminal_theme_list"))

      for name <- ~w(terminal_theme_select terminal_theme_paint terminal_theme_reset) do
        entry = Enum.find(entries, &(&1.name == name))
        assert entry.type == :mutate, "#{name}: changes what the operator sees"
        assert entry.tier == :restricted, "#{name}: :safe would let any token repaint the machine"
      end
    end

    test "the read runs for an untrusted caller and the writes do not" do
      assert {:ok, _result} = Commands.call("terminal_theme_list", %{}, caller: :mcp)

      assert {:error, :requires_confirmation} =
               Commands.call("terminal_theme_select", %{"key" => "nord"}, caller: :mcp)

      assert {:error, :requires_confirmation} =
               Commands.call("terminal_theme_paint", %{"colors" => base_palette()}, caller: :mcp)

      assert {:error, :requires_confirmation} =
               Commands.call("terminal_theme_reset", %{}, caller: :mcp)

      refute_receive {:terminal_theme_apply, _key, _palette}
    end

    test "every argument the handler reads is declared in the catalog, and vice versa" do
      source =
        File.read!(Path.join(File.cwd!(), "lib/buster_claw/commands/terminal_theme.ex"))

      read =
        [
          ~r/"([a-z][a-z0-9_]*)"\s*=>/,
          ~r/args\[\s*"([a-z][a-z0-9_]*)"\s*\]/,
          ~r/Map\.(?:get|fetch|fetch!|has_key\?)\(\s*args\s*,\s*"([a-z][a-z0-9_]*)"/
        ]
        |> Enum.flat_map(&(Regex.scan(&1, source) |> Enum.map(fn [_, key] -> key end)))
        |> MapSet.new()

      declared =
        Catalog.entries()
        |> Enum.filter(&String.starts_with?(&1.name, "terminal_theme_"))
        |> Enum.flat_map(&Map.keys(&1.args))
        |> MapSet.new()

      assert read == declared,
             """
             The catalog and the handler disagree about arguments.
             handler reads: #{inspect(MapSet.to_list(read))}
             catalog declares: #{inspect(MapSet.to_list(declared))}

             An undeclared argument a handler honours is the same class of error
             as an invented verb: the model is told one contract and the code
             keeps another.
             """
    end
  end

  # --- call-graph helper -------------------------------------------------

  # Remote calls read from the module's BEAM `imports` chunk — the compiler's
  # own record of what it calls. It sees static remote calls and not `apply/3`
  # with a computed name, which is stated as a limit rather than hidden.
  defp internal_calls(module) do
    module
    |> imports()
    |> Enum.filter(fn {m, _f, _a} ->
      String.starts_with?(Atom.to_string(m), "Elixir.BusterClaw.")
    end)
    |> Enum.sort()
    |> Enum.uniq()
  end

  defp imports(module) do
    with path when is_list(path) <- :code.which(module),
         {:ok, {_module, [imports: imports]}} <- :beam_lib.chunks(path, [:imports]) do
      imports
    else
      _ -> []
    end
  end
end
