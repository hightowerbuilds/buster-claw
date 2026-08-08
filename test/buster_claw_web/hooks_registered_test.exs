defmodule BusterClawWeb.HooksRegisteredTest do
  @moduledoc """
  Every `phx-hook` named in markup must exist in the LiveSocket's hook registry.

  This is the one contract the Elixir suite cannot otherwise see. `render_hook/3`
  in LiveViewTest pushes the event straight at the component — it never loads
  `assets/js`, so a hook that markup names and `hooks/index.js` does not export
  is a *silently dead* interaction: no error, no warning, a green suite, and a
  button that does nothing in the real app. A regex rename over `.ex` files has
  already severed a JS contract in this repo exactly this way.

  The check runs one direction on purpose. Markup naming an unregistered hook is
  always a bug. A registered hook that no markup names is usually just a feature
  that has not landed yet, or one whose surface was deleted — worth noticing, but
  not worth failing a build over.
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
