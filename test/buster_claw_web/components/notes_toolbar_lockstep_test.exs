defmodule BusterClawWeb.NotesToolbarLockstepTest do
  @moduledoc """
  The Notes toolbar's command list lives in two languages, and they must agree.

  `BusterClawWeb.Notes.Toolbar.commands/0` renders the buttons;
  `NOTE_COMMANDS` in `assets/js/lib/note_commands.js` routes them to transforms.
  A `data-note-cmd` with no transform is a **button that does nothing**, and a
  transform with no button is unreachable. Neither fails anywhere else:
  `render_hook/3` never loads the JS, and the bun suite never reads a `.ex` file,
  so both suites stay green either way.

  This is the same guard `hooks_registered_test.exs` puts on `phx-hook` names and
  the Tauri ACL lockstep puts on capability files — the standing answer in this
  repo to one list living in two places. It fails in **both** directions, unlike
  the hook guard: here an unrendered transform is genuinely dead code rather
  than a feature waiting for its surface, because the toolbar is the only thing
  that can invoke one.
  """
  use ExUnit.Case, async: true

  alias BusterClawWeb.Notes.Toolbar

  @source "assets/js/lib/note_commands.js"

  test "the toolbar's buttons and the JS command table name the same set" do
    elixir = Enum.map(Toolbar.commands(), & &1.cmd)
    javascript = js_commands()

    assert Enum.sort(elixir) == Enum.sort(javascript), """
    The Notes toolbar and #{@source} disagree.

      only in toolbar.ex:            #{inspect(elixir -- javascript)}
      only in NOTE_COMMANDS (JS):    #{inspect(javascript -- elixir)}

    A button with no transform does nothing when clicked; a transform with no
    button cannot be reached. Add or remove it in both.
    """
  end

  test "no command is listed twice on either side" do
    elixir = Enum.map(Toolbar.commands(), & &1.cmd)
    javascript = js_commands()

    assert elixir == Enum.uniq(elixir)
    assert javascript == Enum.uniq(javascript)
  end

  test "every button carries a label, and exactly one of an icon or a glyph" do
    for command <- Toolbar.commands() do
      assert is_binary(command.label) and command.label != "",
             "#{command.cmd} has no label — it is the button's accessible name and its tooltip"

      has_icon = Map.has_key?(command, :icon)
      has_text = Map.has_key?(command, :text)

      assert has_icon != has_text,
             "#{command.cmd} must have an :icon or a :text glyph, not both and not neither"
    end
  end

  # Every `cmd:` key in the exported NOTE_COMMANDS array. Deliberately a regex
  # over the source rather than anything cleverer: the alternative is running a
  # JS engine from ExUnit, and the shape being matched is a literal table that
  # exists to be read this way.
  defp js_commands do
    source = File.read!(@source)

    [_, table] = Regex.run(~r/export const NOTE_COMMANDS = \[(.*?)\n\]/s, source)

    ~r/\{cmd: "([a-z0-9]+)"/
    |> Regex.scan(table)
    |> Enum.map(fn [_, cmd] -> cmd end)
  end

  test "the JS table was actually found, so this test cannot pass vacuously" do
    # If `NOTE_COMMANDS` is renamed or reformatted, the regex above would return
    # [] and the comparison would quietly become "[] == []" the moment the
    # toolbar emptied too. Assert the shape it depends on.
    assert length(js_commands()) >= 10
  end
end
