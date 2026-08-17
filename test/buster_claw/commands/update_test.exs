defmodule BusterClaw.Commands.UpdateTest do
  @moduledoc """
  The guard for an **absence**.

  `UPDATE_ROADMAP`'s load-bearing decision: replacing the application binary is
  never a command, at any tier. An agent that can swap the bundle can swap the
  thing that refuses its requests — the policy engine, the trust tiers, the
  Sentinel audit, the `agent_untrusted` gate are all code *inside* the bundle
  being replaced, so no tier is low enough to make it safe.

  The enforcement is that no such command exists. That is stronger and cheaper
  than a policy check, and it is the same shape as the guards keeping a mutating
  verb out of Pockets and `TerminalTheme.set_custom/3` out of the agent's reach.

  **An absence rots silently, which is the whole reason this file exists.** The
  roadmap claimed this test was here from the moment the decision was written;
  it was not, for a day. A rule with no guard is a sentence, and the sentence was
  already being cited as if it were enforced.
  """
  use ExUnit.Case, async: true

  alias BusterClaw.Commands

  # Named by their OBJECT, not by the word "update".
  #
  # The first version of this matched the substring `update_` and immediately
  # caught `sheets_update_values` — a Google Sheets write, entirely legitimate,
  # and one of twelve catalog commands with "update" in the name. A guard that
  # cries wolf on a dozen real verbs is one somebody widens an exception list
  # for until it guards nothing.
  #
  # Twelve commands contain "update" and **none begins with it**, so a leading
  # `update_` is unclaimed and is the shape an app-updater would take.
  @forbidden [
    ~r/\Aupdate_/,
    ~r/\A(app|self|binary|bundle|release)_(update|upgrade)/,
    ~r/(update|upgrade|install)_(app|binary|bundle|release|myself)\b/,
    ~r/restart_and_update/
  ]

  test "no command anywhere in the catalog can update the application" do
    offenders =
      Commands.list_commands()
      |> Enum.map(& &1.name)
      |> Enum.filter(fn name -> Enum.any?(@forbidden, &Regex.match?(&1, name)) end)

    assert offenders == [],
           """
           These commands look like they update the application: #{inspect(offenders)}

           UPDATE_ROADMAP: installing an update is the operator's, through the desktop
           shell — never the catalog's. An agent that can replace the binary can replace
           every boundary that refuses it, and no tier is low enough to make that safe.

           If one of these is genuinely unrelated to updating the app, rename it. If it
           is related, it belongs behind the shell's IPC and a trusted-token floor, the
           way credential management does.
           """
  end

  test "the catalog carries no update-shaped verb under any tier, including safe" do
    # Asserted separately from the name check because the failure it guards is
    # different: the name check catches a verb being ADDED, this catches one
    # being added and reasoned about as harmless because it is only `:safe`.
    for command <- Commands.list_commands() do
      refute command.name =~ ~r/\b(update|upgrade)_(app|binary|bundle|release|self)\b/,
             "#{command.name} (#{command.tier}) is an application-update verb"
    end
  end

  # `sketch_update` and `note_save` and friends update DATA. The distinction this
  # file draws is the application itself, and stating it keeps the guard from
  # being widened into nonsense by someone reading only its title.
  test "updating data is fine, and the guard does not pretend otherwise" do
    names = Enum.map(Commands.list_commands(), & &1.name)

    assert "sketch_update" in names,
           "the guard should not have swept up ordinary data-updating verbs"
  end
end
