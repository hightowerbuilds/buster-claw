defmodule BusterClaw.Browser.BridgeLockstepTest do
  @moduledoc """
  The browser bridge is a contract between two languages, and nothing checked it.

  `BusterClaw.Browser.Bridge` guards `request/3` with `action in @actions`, then
  broadcasts the action to the `Browser` JS hook, which dispatches on a chain of
  `action === "..."` branches. Elixir accepts ten actions; the hook implements
  ten branches; the only thing keeping those two lists equal was that nobody had
  edited one without the other yet.

  A mismatch does not fail here or in CI. It fails in the browser, at the moment
  a user asks for that action, as `{error: "unknown browser command"}` — the JS
  `else` arm. Every Elixir test passes, because `render_hook` never runs the
  hook's real JavaScript. This repo has already been bitten by exactly that
  shape: a rename swept across `.ex` files severed a hook contract and the suite
  stayed green.

  So this test does what `desktop/tauri/tests/acl_lockstep.rs` does for the
  Rust/Tauri surfaces — reads the two sources as text and compares the sets.
  """
  use ExUnit.Case, async: true

  @bridge_path "lib/buster_claw/browser/bridge.ex"
  @hook_path "assets/js/hooks/browser.js"

  # `@actions ~w(current read ...)a`
  defp elixir_actions do
    source = File.read!(@bridge_path)

    captures =
      Regex.run(~r/@actions\s+~w\(([^)]+)\)a/, source) ||
        flunk("#{@bridge_path} no longer declares `@actions ~w(...)a` — parser needs updating")

    captures
    |> Enum.at(1)
    |> String.split()
    |> MapSet.new()
  end

  # `} else if (action === "click") {`
  defp js_actions do
    @hook_path
    |> File.read!()
    |> then(&Regex.scan(~r/action\s*===\s*"([a-z_]+)"/, &1))
    |> Enum.map(&Enum.at(&1, 1))
    |> MapSet.new()
  end

  describe "the Elixir bridge and the JS hook agree on the action set" do
    test "neither parser silently matched nothing" do
      # The tripwire the docs-drift gate taught us to write: an extraction that
      # quietly returns an empty set turns this whole file into a no-op that
      # passes forever.
      assert MapSet.size(elixir_actions()) > 5,
             "parsed suspiciously few actions from #{@bridge_path} — parser broken?"

      assert MapSet.size(js_actions()) > 5,
             "parsed suspiciously few actions from #{@hook_path} — parser broken?"
    end

    test "every action Elixir will send, the hook handles" do
      missing = MapSet.difference(elixir_actions(), js_actions())

      assert MapSet.equal?(missing, MapSet.new()),
             """
             #{@bridge_path} accepts #{inspect(MapSet.to_list(missing))}, but
             #{@hook_path} has no `action === "..."` branch for it.

             At runtime the hook's else arm answers {error: "unknown browser
             command"} and the caller sees a generic failure. Add the branch, or
             drop the action from @actions.
             """
    end

    test "every branch the hook implements, Elixir can actually send" do
      orphaned = MapSet.difference(js_actions(), elixir_actions())

      assert MapSet.equal?(orphaned, MapSet.new()),
             """
             #{@hook_path} handles #{inspect(MapSet.to_list(orphaned))}, which
             #{@bridge_path} will never send — `request/3`'s guard rejects it.

             Dead branches are how a reader concludes a feature exists. Remove
             them, or add the action to @actions.
             """
    end
  end
end
