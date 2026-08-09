defmodule BusterClawWeb.ChromeHook do
  @moduledoc """
  LiveView `on_mount` hook for the parts of the app chrome that every view wears.

  Two jobs.

  ## Split panes

  Records whether the current view is rendered inside a split pane (i.e. embedded
  via `live_render` with `embedded: true` in its session). `Layouts.app/1` reads
  this flag and renders the bare content (no tab strip / dock) for embedded panes.

  The flag lives in the process dictionary: each LiveView runs in its own
  process, and render happens in that same process, so there is no cross-talk
  between the parent split view and its panes.

  ## Terminal paint

  It also carries `{:terminal_theme_apply, key, palette}` out to the browser as a
  `bc-term-apply` client event. That message is the *only* way something without
  a socket — a command, a job — can change what a terminal looks like, because
  the selected theme lives in `localStorage` rather than on the server. See
  `BusterClaw.TerminalPaint` for why, and note the same `:halt` reasoning as
  below applies: nothing else may handle it.

  ## Brand art

  The dock is in the layout and the banner is on the homepage, so when an
  operator swaps a brand image the surface that changes is **not** the surface
  they changed it on — and it is usually not even the same LiveView process.
  Subscribing here does it once for every view instead of in a dozen mounts.

  Two surfaces need it, and they need it differently — worth knowing before
  changing either:

  - the **banner** lives in `StatusLive`'s own template, so it is part of that
    view's diff and `@banner_url` is enough;
  - the **dock** lives in the app layout, which Phoenix renders **once at mount
    and never diffs again**. No assign can reach it there, so it is its own
    sticky LiveView (`BusterClawWeb.DockNavLive`) — which, being a LiveView,
    gets this hook too and reads `@nav_items` from it.

  That is why both values are assigned here: this hook `:halt`s the broadcast, so
  a nested view's own `handle_info` would never run.
  """

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [attach_hook: 4, connected?: 1]

  alias BusterClaw.Pockets.Brand
  alias BusterClaw.TerminalPaint

  def on_mount(:default, _params, session, socket) do
    Process.put(:bc_embedded, session["embedded"] == true)

    if connected?(socket) do
      Phoenix.PubSub.subscribe(BusterClaw.PubSub, Brand.topic())
      # The only route a socket-less writer has to a terminal. See
      # `BusterClaw.TerminalPaint`: the selected theme is client-side, so a
      # command cannot change it by writing a Setting.
      #
      # ITS OWN topic, not `TerminalTheme`'s. Subscribing every LiveView to that
      # one delivered its `{:terminal_theme, custom}` message to views with no
      # clause for it, and TerminalLive crashed.
      TerminalPaint.subscribe()
    end

    socket =
      socket
      |> assign_brand()
      |> attach_hook(:brand_art, :handle_info, &handle_brand/2)

    {:cont, socket}
  end

  @doc "True when the current process is rendering an embedded split pane."
  def embedded?, do: Process.get(:bc_embedded, false)

  defp handle_brand(:brand_art_changed, socket), do: {:halt, assign_brand(socket)}

  # Wear this theme now. `palette` is installed under `key` first when present.
  defp handle_brand({:terminal_theme_apply, key, palette}, socket) do
    {:halt, Phoenix.LiveView.push_event(socket, "bc-term-apply", %{key: key, palette: palette})}
  end

  defp handle_brand(_message, socket), do: {:cont, socket}

  # Both surfaces are assigned HERE rather than each view fetching its own,
  # because this hook `:halt`s the message — a nested view's own `handle_info`
  # would never see it. That is not a wart to route around: one place computing
  # brand art is the reason a swap cannot half-apply.
  defp assign_brand(socket) do
    socket
    |> assign(:nav_items, BusterClawWeb.Layouts.nav_items())
    |> assign(:banner_url, Brand.image_url("home_banner"))
  end
end
