defmodule BusterClawWeb.RequireOnboardingTest do
  @moduledoc """
  Lockstep guard between the layouts and the onboarding gate.

  ## The bug this exists to prevent

  A child LiveView cannot redirect. `RequireOnboarding` redirects to `/setup`
  when onboarding is incomplete, so any app-wide sticky child that reaches that
  branch raises `cannot redirect from a child LiveView` — a 500 on whatever page
  mounted it.

  The hook keeps a list of views it lets through. On 08-23 that list was one
  entry short: `SoundBoardLive` was added to `root.html.heex` after the list was
  written, so **every first launch of 0.1.0 served a 500 on `/setup`** and the
  app could not be onboarded at all. It was found by installing the shipped DMG
  on a real machine, not by this suite.

  There is no runtime property that separates a statically-rendered child from a
  statically-rendered root — measured 08-23, both carry `parent_pid: nil` — so
  the hook cannot express this as a rule and has to keep a list. This file is
  what stops the list rotting: it reads the layouts and fails when they disagree.
  """
  use ExUnit.Case, async: true

  alias BusterClawWeb.RequireOnboarding

  @layouts [
    "lib/buster_claw_web/components/layouts/root.html.heex",
    "lib/buster_claw_web/components/layouts.ex"
  ]

  # `live_render(@conn, BusterClawWeb.Thing, sticky: true, id: "x")` and the
  # `@socket &&` variants in layouts.ex. Captures the module name; the
  # `sticky: true` may precede or follow other options.
  @sticky_re ~r/live_render\(\s*@?\w+\s*,\s*(BusterClawWeb\.\w+)\s*,[^)]*sticky:\s*true/

  defp sticky_in_layouts do
    @layouts
    |> Enum.flat_map(fn path ->
      path
      |> File.read!()
      |> then(&Regex.scan(@sticky_re, &1))
      # safe_concat: every module the layouts name is compiled, so the atom
      # exists. If one does not, raising here is the correct outcome — it means
      # a layout references a module that is gone.
      |> Enum.map(fn [_, mod] -> Module.safe_concat([mod]) end)
    end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  test "the scanner still finds something" do
    # Guards the guard: a regex that silently matches nothing would make every
    # assertion below vacuously true, which is the exact shape of failure this
    # file exists to catch. If the layouts change how they render children, this
    # is the test that should break first.
    found = sticky_in_layouts()

    assert length(found) >= 4,
           "expected at least 4 sticky child LiveViews in the layouts, found: #{inspect(found)}"
  end

  test "every sticky child rendered by a layout is let through the onboarding gate" do
    allowed = MapSet.new(RequireOnboarding.allowed_views())

    missing = Enum.reject(sticky_in_layouts(), &MapSet.member?(allowed, &1))

    assert missing == [],
           """
           These LiveViews are rendered as sticky children by a layout but are not
           in RequireOnboarding's allowed list:

               #{Enum.map_join(missing, "\n    ", &inspect/1)}

           A child LiveView cannot redirect. On a machine where onboarding is not
           complete, each of these will raise "cannot redirect from a child
           LiveView" and serve a 500 on EVERY page — including /setup, which makes
           the app impossible to onboard.

           Add them to @sticky_children in lib/buster_claw_web/live/require_onboarding.ex.
           """
  end

  test "the hook's declared sticky children match what the layouts actually render" do
    # The reverse direction. A module listed as sticky but no longer rendered is
    # dead configuration, and dead configuration is how the next reader loses
    # confidence that this list means anything.
    declared = MapSet.new(RequireOnboarding.sticky_children())
    rendered = MapSet.new(sticky_in_layouts())

    assert MapSet.equal?(declared, rendered),
           """
           RequireOnboarding.sticky_children/0 and the layouts disagree.

             only in the hook:     #{inspect(MapSet.to_list(MapSet.difference(declared, rendered)))}
             only in the layouts:  #{inspect(MapSet.to_list(MapSet.difference(rendered, declared)))}
           """
  end
end
