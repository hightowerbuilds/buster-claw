defmodule BusterClaw.WorkspaceSeedLockstepTest do
  @moduledoc """
  Every `seed: {module, fun}` in the workspace registry must name a function that
  exists — and nothing else in the repo can tell you when one stops existing.

  `BusterClaw.Workspace` declares its seeds as `{module, :atom}` tuples and
  `run_seed/1` invokes them with `apply(module, fun, [])`. That indirection makes
  a renamed, deleted, or privatised seed invisible three times over: invisible to
  a grep for `fun(` because no call site spells the name, invisible to
  `mix compile --warnings-as-errors` because an atom is just an atom, and
  invisible to the whole suite because no test seeds a workspace through the
  registry. It fails once, at runtime, the first time a real workspace is
  seeded — and `run_seed/1` *rescues* the UndefinedFunctionError and downgrades
  it to a `Logger.warning`, so even then the folder is simply missing and nobody
  is told why.

  This is not hypothetical. A dead-code sweep this week nearly converted
  `write_readme/0` — registered as `seed: {__MODULE__, :write_readme}` — to
  `defp`. It would have compiled clean, passed every test, and stopped writing
  the workspace README.

  So this does for the seed registry what `desktop/tauri/tests/acl_lockstep.rs`
  does for the Tauri command surface and `hooks_registered_test.exs` does for the
  JS hook registry: reads the list from the module that owns it and asserts each
  reference resolves. The list is never copied here — a copy is the drift.
  """
  use ExUnit.Case, async: true

  alias BusterClaw.Workspace

  # `run_seed/1` calls `apply(module, fun, [])`, so every seed is arity 0.
  @seed_arity 0

  defp seeded_entries do
    Enum.filter(Workspace.entries(), &(&1.seed != nil))
  end

  describe "workspace seed lockstep guard" do
    test "the guard cannot pass vacuously" do
      # The failure mode this repo keeps meeting: a collection empties, or its
      # accessor changes shape, and the guard below goes green by iterating
      # nothing. If this trips, fix the enumeration — do not delete the test.
      seeded = seeded_entries()

      assert length(seeded) > 5,
             """
             Found only #{length(seeded)} entries with a `seed:` in
             BusterClaw.Workspace.entries/0, which is fewer than this registry has
             ever had. Either the registry was gutted or `entries/0` no longer
             returns maps with a `:seed` key — in which case the lockstep test
             below is asserting nothing at all.
             """
    end

    test "every registered seed function is exported by its module" do
      broken =
        for %{name: name, seed: {module, fun}} <- seeded_entries(),
            Code.ensure_loaded(module) != {:module, module} or
              not function_exported?(module, fun, @seed_arity) do
          "    #{name}  →  #{inspect(module)}.#{fun}/#{@seed_arity}"
        end

      assert broken == [], """
      These workspace entries name a seed function that does not exist:

      #{Enum.join(broken, "\n")}

      `BusterClaw.Workspace.run_seed/1` invokes each seed as
      `apply(module, fun, [])`, so the reference is an atom and nothing else in
      this repo can check it — not a grep for the name, not the compiler, not the
      rest of the suite. It fails when a real workspace is seeded, and
      `run_seed/1` rescues the error into a log line, so the only symptom is a
      folder that never appears.

      Fix one of the two sides:
        * the function was renamed or made private → give it back a public
          zero-arity `def` and point the `seed:` tuple at its current name, or
        * the entry no longer needs seeding → set `seed: nil` and say in the
          comment which write site creates it inline.
      """
    end
  end
end
