defmodule BusterClaw.TerminalPaint do
  @moduledoc """
  The one path by which something **without a browser socket** changes what a
  terminal looks like.

  Scoped as Phase 0 of `daily-growth/roadmaps/TERMINAL_PAINT_ROADMAP.md`, and it
  is Phase 0 because without it the rest of that roadmap cannot exist.

  ## Why this module has to exist

  Two facts, both read from the code rather than assumed:

  1. **The selected terminal theme is client-side only.** It lives in
     `localStorage["bc:term-theme"]` (`assets/js/lib/theme.js`). Only the custom
     *palette* is server-side, in `Settings`. So nothing on the server knows which
     theme is active, and **writing a Setting cannot change what a terminal
     looks like.**
  2. **`TerminalTheme.topic/0` had no subscribers.** Live apply runs through
     `AppearanceLive` calling `push_event` directly on the socket that made the
     edit — which works only because the editor and the terminal are in the same
     browser. A command has no socket, so that path is closed to it.

  So a change made outside a LiveView reaches a terminal by exactly one route:
  broadcast here → `BusterClawWeb.ChromeHook` (which runs for every LiveView)
  pushes a client event → `theme.js` applies it to every live xterm.

  ## The contract, stated once

  `announce/2` broadcasts `{:terminal_theme_apply, key, palette}` on `topic/0`,
  which is **this module's own topic and not `TerminalTheme`'s**.

  - `key` — the theme to select, e.g. `"agent"` or `"nord"`. Always applied.
  - `palette` — a `%{field => "#rrggbb"}` map to install under `key` first, or
    `nil` to select a theme the client already knows.

  One message covers both *select* and *paint*, because from the client's side
  they are the same act: know the palette, then wear it. A second message shape
  would have been two ways to do one thing.

  ## Why a separate topic, learned the hard way

  The first draft reused `TerminalTheme.topic/0`. `BusterClawWeb.ChromeHook`
  subscribes on behalf of **every** LiveView, so that immediately delivered
  `TerminalTheme`'s existing `{:terminal_theme, custom}` message — announcing that
  the operator edited their saved palette — to views with no clause for it.
  `TerminalLive` crashed on the first test.

  Two topics, then, and the split is meaningful rather than defensive:
  `{:terminal_theme, custom}` says *something was edited*; `{:terminal_theme_apply,
  …}` says *wear this now*. Collapsing them would also have made a save in
  Settings silently re-select, which is not what the editor does.

  It also leaves the terminal-theme roadmap's topic untouched, so a subscriber
  added there later still gets what it expects.
  """

  @topic "terminal:paint"

  @doc "PubSub topic carrying \"wear this now\". Distinct from `TerminalTheme.topic/0`."
  def topic, do: @topic

  @doc "Subscribe the calling process. `BusterClawWeb.ChromeHook` does this for every LiveView."
  def subscribe, do: Phoenix.PubSub.subscribe(BusterClaw.PubSub, @topic)

  @doc """
  Tell every open surface to wear `key`, optionally installing `palette` first.

  Returns `:ok`. Fire-and-forget by design: a browser that is not open has
  nothing to apply, and the durable state is whatever wrote it — this only
  carries the *now*.
  """
  def announce(key, palette \\ nil) when is_binary(key) do
    Phoenix.PubSub.broadcast(
      BusterClaw.PubSub,
      @topic,
      {:terminal_theme_apply, key, palette}
    )

    :ok
  end
end
