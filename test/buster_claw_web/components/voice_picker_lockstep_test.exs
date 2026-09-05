defmodule BusterClawWeb.VoicePickerLockstepTest do
  @moduledoc """
  The voice controls live in two languages and must agree on every handle.

  `assets/js/hooks/voice.js` reaches into the markup by `data-voice-*` attribute
  — the select, the rate slider and its readout, the two buttons, and the two
  panels that swap depending on whether there is a synthesizer to talk to. The
  markup that carries those attributes is in `voice_live.ex` (the picker) and
  `chat_panel.ex` (the on/off toggle's label).

  Neither suite catches a mismatch on its own. `render_hook/3` never loads the
  JS, so a renamed attribute in a template leaves every LiveView test green while
  the control silently stops working; the bun suite never reads a `.ex` file, so
  it cannot see the other side either. That is the exact shape of the 08-09
  rename that severed a hook↔markup contract with a green suite, and the reason
  this repo answers "one list in two places" with a lockstep test —
  `hooks_registered_test.exs` for `phx-hook` names, `notes_toolbar_lockstep_test`
  for the Notes commands, `acl_lockstep.rs` for the Tauri capability files.

  It fails in both directions on purpose. A selector the hook queries with no
  markup is a dead control — `querySelector` returns `nil` and the feature
  quietly loses a button. A `data-voice-*` attribute in markup that no hook
  queries is decoration nobody reads.
  """
  use ExUnit.Case, async: true

  @hook "assets/js/hooks/voice.js"
  @templates [
    # The picker moved out of `voice_live.ex` on 09-05 when Vox became a homepage
    # sub-tab and the surface became a component rendered by two hosts. The path
    # moves in the same commit as the markup, never after: this list is the only
    # thing that knows where to look, so a stale entry turns the guard vacuous
    # rather than red.
    "lib/buster_claw_web/live/vox_component.ex",
    "lib/buster_claw_web/components/chat_panel.ex"
  ]

  test "every handle the hook reaches for exists in the markup, and vice versa" do
    queried = queried_attributes()
    rendered = rendered_attributes()

    assert queried != [], "expected #{@hook} to query some data-voice-* handles"

    assert queried == rendered, """
    #{@hook} and the voice markup disagree.

      queried by the hook, absent from markup: #{inspect(queried -- rendered)}
      in markup, queried by nothing:           #{inspect(rendered -- queried)}

    A queried handle with no markup makes querySelector return null and the
    control silently does nothing. Rename it on both sides, or delete it on both.
    """
  end

  # Only the bracketed selector form, so a future comment that merely mentions an
  # attribute name cannot be mistaken for a use of it.
  defp queried_attributes do
    @hook
    |> File.read!()
    |> then(&Regex.scan(~r/\[(data-voice-[a-z-]+)\]/, &1, capture: :all_but_first))
    |> List.flatten()
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp rendered_attributes do
    @templates
    |> Enum.flat_map(fn path ->
      path
      |> File.read!()
      |> then(&Regex.scan(~r/\b(data-voice-[a-z-]+)/, &1, capture: :all_but_first))
      |> List.flatten()
    end)
    |> Enum.uniq()
    |> Enum.sort()
  end
end
