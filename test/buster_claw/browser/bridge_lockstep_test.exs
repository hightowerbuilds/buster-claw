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

  alias BusterClaw.Browser.Bridge

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

  # `payload.wait_ms`, `payload.selector`, …
  defp js_payload_keys do
    @hook_path
    |> File.read!()
    |> then(&Regex.scan(~r/payload\.([a-zA-Z_]+)/, &1))
    |> Enum.map(&Enum.at(&1, 1))
    |> MapSet.new()
  end

  defp declared_payload_keys do
    Bridge.payload_contract()
    |> Map.values()
    |> List.flatten()
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

  # The action half of this contract has been checked since 07-28; the ARGUMENT
  # half was the gap the refactor roadmap named and nobody closed — "the bridge
  # test compares action NAMES; a rename of `wait_ms` on either side is still
  # silent." It is silent in the worst way: the hook reads `undefined`, the
  # command runs, and the result looks like a page that simply did not match.
  describe "the two sides agree on the payload keys, not just the verbs" do
    test "neither parser silently matched nothing" do
      assert MapSet.size(declared_payload_keys()) > 5
      assert MapSet.size(js_payload_keys()) > 5
    end

    test "every key Elixir declares, the hook reads" do
      missing = MapSet.difference(declared_payload_keys(), js_payload_keys())

      assert MapSet.equal?(missing, MapSet.new()),
             """
             Bridge declares #{inspect(MapSet.to_list(missing))} in @payload_keys,
             but #{@hook_path} never reads `payload.<key>` for it.

             The command would run with that argument dropped on the floor.
             """
    end

    test "every key the hook reads, Elixir declares" do
      orphaned = MapSet.difference(js_payload_keys(), declared_payload_keys())

      assert MapSet.equal?(orphaned, MapSet.new()),
             """
             #{@hook_path} reads #{inspect(MapSet.to_list(orphaned))}, which
             Bridge's @payload_keys never declares — so `request/3` now REFUSES
             a payload carrying it, and the hook reads undefined.

             Add it to @payload_keys, or stop reading it in the hook.
             """
    end

    test "the contract covers every action, so a new one cannot skip it" do
      actions = elixir_actions() |> MapSet.new()

      declared =
        Bridge.payload_contract() |> Map.keys() |> MapSet.new(&to_string/1)

      assert MapSet.equal?(actions, declared),
             """
             @actions and @payload_keys disagree:
               actions without a payload declaration: #{inspect(MapSet.to_list(MapSet.difference(actions, declared)))}
               declarations without an action:        #{inspect(MapSet.to_list(MapSet.difference(declared, actions)))}

             An action with no entry cannot be called at all — `payload_keys/1`
             does a Map.fetch!/2 — so this fails loudly rather than at runtime.
             """
    end
  end

  describe "request/3 refuses a payload key the hook cannot read" do
    test "an unknown key raises rather than vanishing" do
      assert_raise ArgumentError, ~r/waitMs/, fn ->
        Bridge.request(:render, %{"url" => "https://e.com/", "waitMs" => 1})
      end
    end

    test "a declared key gets past validation" do
      # The claim is only that validation lets it through; what happens after
      # depends on whether a desktop is attached, so both outcomes pass. A tiny
      # timeout keeps this from waiting out the real 8s budget.
      assert {:error, reason} =
               Bridge.request(
                 :render,
                 %{"url" => "https://e.com/", "wait_ms" => 1},
                 timeout_ms: 1
               )

      assert reason in [:browser_unavailable, :browser_timeout]
    end
  end
end
