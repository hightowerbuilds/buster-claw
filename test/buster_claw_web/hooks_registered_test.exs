defmodule BusterClawWeb.HooksRegisteredTest do
  @moduledoc """
  Every `phx-hook` named in markup must exist in the LiveSocket's hook registry.

  This is the one contract the Elixir suite cannot otherwise see. `render_hook/3`
  in LiveViewTest pushes the event straight at the component — it never loads
  `assets/js`, so a hook that markup names and `hooks/index.js` does not export
  is a *silently dead* interaction: no error, no warning, a green suite, and a
  button that does nothing in the real app. A regex rename over `.ex` files has
  already severed a JS contract in this repo exactly this way.

  The check runs BOTH directions. Markup naming an unregistered hook is always a
  bug. The reverse used to be advisory ("a feature that has not landed yet") —
  until the 08-08 Trading deletion left two registered hooks (`PortfolioChart`,
  `ChatWindow`, 436 lines) shipping in every page load for five days with
  nothing able to see them. Registered-but-unnamed now means "deleted feature"
  far more often than "feature in flight", so it fails the build too; a hook
  that is genuinely landing soon can arrive in the same commit as its markup.

  Colocated hooks (`phoenix-colocated`, merged in `app.js`) are outside both
  directions on purpose: they are extracted from the markup itself, so they
  cannot drift from it.
  """
  use ExUnit.Case, async: true

  @markup Path.wildcard("lib/**/*.ex")
  @registry "assets/js/hooks/index.js"

  test "every phx-hook in lib/ is exported by the JS hook registry" do
    registered = registered_hooks()

    used =
      for path <- @markup,
          [_, name] <- Regex.scan(~r/phx-hook="([A-Za-z0-9_]+)"/, File.read!(path)),
          uniq: true,
          do: {name, path}

    missing =
      for {name, path} <- used, name not in registered, do: "  #{name} (#{path})"

    assert missing == [],
           "phx-hook names with no entry in #{@registry}:\n" <>
             Enum.join(Enum.uniq(missing), "\n")
  end

  test "every hook in the JS registry is named by some phx-hook in lib/" do
    used =
      for path <- @markup,
          [_, name] <- Regex.scan(~r/phx-hook="([A-Za-z0-9_]+)"/, File.read!(path)),
          uniq: true,
          into: MapSet.new(),
          do: name

    dead = for name <- registered_hooks(), name not in used, do: "  #{name}"

    assert dead == [],
           "hooks registered in #{@registry} that no markup names — " <>
             "dead code shipped in every page load. Delete the hook and its " <>
             "registry entry (or land the markup in the same commit):\n" <>
             Enum.join(dead, "\n")
  end

  # The keys of `export const Hooks = { ... }`, which is what the LiveSocket is
  # actually handed. Imports are deliberately not consulted: an imported hook
  # that never reaches the object is just as dead as one that was never written.
  defp registered_hooks do
    body =
      @registry
      |> File.read!()
      |> String.split("export const Hooks = {")
      |> List.last()
      |> String.split("}")
      |> List.first()

    ~r/([A-Za-z0-9_]+)\s*,/
    |> Regex.scan(body)
    |> Enum.map(fn [_, name] -> name end)
  end
end
