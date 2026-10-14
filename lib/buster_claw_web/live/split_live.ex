defmodule BusterClawWeb.SplitLive do
  @moduledoc """
  Renders two views side-by-side in one tab. Reached at
  `/split?left=<path>&right=<path>` when a user joins two tabs. Each pane is a
  nested `live_render` of the target view, mounted with `embedded: true` so its
  shell (tab strip / dock) is suppressed — see `BusterClawWeb.ChromeHook`.
  """
  use BusterClawWeb, :live_view

  alias BusterClawWeb.PaneRoutes
  alias BusterClawWeb.SplitField

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(BusterClaw.PubSub, BusterClaw.Appearance.topic(:terminal))
      Phoenix.PubSub.subscribe(BusterClaw.PubSub, BusterClaw.Appearance.topic(:home))
    end

    {:ok,
     socket
     |> assign(:page_title, "Split")
     |> assign(:terminal_bg, BusterClaw.Appearance.terminal_background())
     |> assign(:home_bg, BusterClaw.Appearance.home_background_state())}
  end

  @impl true
  def handle_info({:terminal_background, bg}, socket) do
    {:noreply, assign(socket, :terminal_bg, bg)}
  end

  def handle_info({:home_background, bg}, socket) do
    {:noreply, assign(socket, :home_bg, bg)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    left = pane_spec("left", params["left"])
    right = pane_spec("right", params["right"])

    # Every pane learns its company, so it can compute the field (SplitField)
    # from the same facts this view does.
    panes = %{
      "terminal" => terminal_pane?(left) or terminal_pane?(right),
      "home" => home_pane?(left) or home_pane?(right)
    }

    {:noreply,
     socket
     |> assign(:panes, panes)
     |> assign(:left, with_panes(left, panes))
     |> assign(:right, with_panes(right, panes))}
  end

  defp with_panes(nil, _panes), do: nil

  defp with_panes(%{child_session: child_session} = spec, panes),
    do: %{spec | child_session: Map.put(child_session, "split_panes", panes)}

  defp pane_spec(_side, nil), do: nil

  defp pane_spec(side, path) when is_binary(path) do
    path =
      if String.split(path, ~r/[?#]/) |> hd() == "/voice", do: "/settings?tab=speech", else: path

    pathname = path |> String.split("?") |> hd()
    url = pane_url(path)

    case PaneRoutes.fetch(pathname) do
      {:ok, {module, label}} ->
        %{
          path: path,
          module: module,
          label: label,
          url: url,
          child_session: pane_child_session(pathname, path, url, side)
        }

      :error ->
        %{path: path, module: nil, label: pathname, url: url, child_session: %{}}
    end
  end

  # Pull a `url` query param (if any) out of the pane's path.
  defp pane_url(path) do
    case URI.parse(path).query do
      nil -> nil
      query -> query |> URI.decode_query() |> Map.get("url")
    end
  end

  defp pane_params(path) do
    case URI.parse(path).query do
      nil -> %{}
      query -> URI.decode_query(query)
    end
  end

  defp pane_child_session("/settings", path, _url, side) do
    %{
      "settings_tab" => pane_params(path)["tab"],
      "settings_id_prefix" => "split-#{side}-",
      "speech_id" => "settings-speech-#{side}"
    }
  end

  defp pane_child_session("/terminal", path, _url, _side) do
    params = pane_params(path)

    %{}
    |> maybe_put("terminal_session_key", params["session"])
    |> maybe_put("terminal_label", params["label"])
  end

  # Carry a browser's existing native surface through a join or swap. Legacy
  # split URLs without an explicit surface still get independent left/right IDs.
  defp pane_child_session("/browse", path, url, side) do
    surface = PaneRoutes.browser_surface(pane_params(path), side)
    %{} |> maybe_put("url", url) |> Map.put("surface_id", surface)
  end

  defp pane_child_session(_pathname, _path, nil, _side), do: %{}
  defp pane_child_session(_pathname, _path, url, _side), do: %{"url" => url}

  defp maybe_put(map, _key, value) when value in [nil, ""], do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp pane_live_id(side, %{module: BusterClawWeb.TerminalLive, child_session: child_session}) do
    session_key = Map.get(child_session, "terminal_session_key", "main")
    "split-pane-#{side}-terminal-#{dom_id_part(session_key)}"
  end

  defp pane_live_id(side, _pane), do: "split-pane-#{side}"

  defp dom_id_part(value) do
    value
    |> to_string()
    |> String.replace(~r/[^A-Za-z0-9_-]+/, "-")
    |> String.trim("-")
    |> case do
      "" -> "main"
      id -> id
    end
  end

  @impl true
  def render(assigns) do
    {field, split_bg} = SplitField.field(assigns.panes, assigns.terminal_bg, assigns.home_bg)
    assigns = assigns |> assign(:split_field, field) |> assign(:split_bg, split_bg)

    ~H"""
    <Layouts.app flash={@flash} socket={@socket} full_bleed>
      <div
        id="split-root"
        phx-hook="SplitResizer"
        data-split-bg-field={@split_field}
        data-split-terminal-bg-active={to_string(@split_field == :terminal)}
        data-terminal-bg-active={to_string(@split_field == :terminal)}
        class={
          [
            "relative isolate flex min-h-0 flex-1 flex-col lg:flex-row",
            if(@split_bg.kind == :image, do: "bg-cover bg-center", else: nil),
            @split_field == :terminal && "bc-split-terminal-bg-active",
            # `.ic-home .ic-panel` is the homepage's veil rule; wearing the class
            # here gives every panel inside the join the same translucency.
            @split_field == :home && "ic-home"
          ]
        }
        style={split_background_style(@split_bg)}
      >
        <%!-- One background across the whole split (SplitField): the terminal's
              when a terminal pane has one set, else the homepage's when Home is in
              the join. Panes go transparent or translucent (below) and reveal this
              shared canvas, so the join reads as one continuous field. --%>
        <BusterClawWeb.ShaderCanvas.shader_canvas bg={@split_bg} prefix="split" />
        <.pane
          side="left"
          class="bc-split-left"
          pane={@left}
          socket={@socket}
          bg_active={@split_field == :terminal and terminal_pane?(@left)}
          owner={@split_field == :home and home_pane?(@left)}
          veiled={@split_field == :home and not home_pane?(@left)}
        />
        <.split_divider />
        <.pane
          side="right"
          class="bc-split-right"
          pane={@right}
          socket={@socket}
          bg_active={@split_field == :terminal and terminal_pane?(@right)}
          owner={@split_field == :home and home_pane?(@right)}
          veiled={@split_field == :home and not home_pane?(@right)}
        />
      </div>
    </Layouts.app>
    """
  end

  defp split_background_style(%{kind: :image, image_url: url}),
    do: "background-image:url('#{url}')"

  defp split_background_style(_bg), do: nil

  defp terminal_pane?(%{module: BusterClawWeb.TerminalLive}), do: true
  defp terminal_pane?(_pane), do: false

  defp home_pane?(%{module: BusterClawWeb.StatusLive}), do: true
  defp home_pane?(_pane), do: false

  # The draggable partition between the two joined panes. Dragging it resizes the
  # split (SplitResizer hook); the centered button swaps the two sides. Only shown
  # on the side-by-side (lg) layout.
  defp split_divider(assigns) do
    ~H"""
    <div
      data-split-divider
      title="Drag to resize"
      class="group relative hidden shrink-0 cursor-col-resize items-center justify-center lg:flex lg:w-3"
    >
      <span class="h-full w-px bg-base-content/15 transition group-hover:bg-primary"></span>
      <button
        type="button"
        data-split-swap
        title="Swap sides"
        aria-label="Swap sides"
        class="absolute grid size-6 cursor-pointer place-items-center rounded-full border border-base-300 bg-base-100 text-base-content/60 opacity-0 shadow-sm transition group-hover:opacity-100 hover:text-primary"
      >
        <.icon name="hero-arrows-right-left" class="size-3.5" />
      </button>
    </div>
    """
  end

  attr :side, :string, required: true
  attr :class, :string, default: nil
  attr :pane, :map, default: nil
  attr :socket, :map, required: true
  # Transparent over the terminal field (a terminal pane with its background set).
  attr :bg_active, :boolean, default: false
  # The Home pane over the home field: transparent, its own panels are the veils.
  attr :owner, :boolean, default: false
  # Any other pane over the home field: a translucent veil, so the field shows
  # through and the pane's text stays legible.
  attr :veiled, :boolean, default: false

  defp pane(assigns) do
    ~H"""
    <section
      data-split-pane={@side}
      data-split-pane-terminal={to_string(terminal_pane?(@pane))}
      data-terminal-bg-active={to_string(@bg_active)}
      data-split-pane-veiled={to_string(@veiled)}
      class={
        [
          # z-10 keeps the pane above the split's shared shader canvas (z-0).
          "relative z-10 flex min-h-0 min-w-0 flex-col overflow-hidden",
          @class,
          cond do
            @bg_active or @owner ->
              "bg-transparent"

            @veiled ->
              "rounded-lg border border-base-300 bg-base-100/70 shadow-sm backdrop-blur-[10px]"

            true ->
              "rounded-lg border border-base-300 bg-base-100 shadow-sm"
          end
        ]
      }
    >
      <%!-- Close this pane and keep the other side as a solo tab. --%>
      <button
        type="button"
        data-split-close={@side}
        title="Close this pane"
        aria-label="Close this pane"
        class="absolute right-2 top-2 z-20 grid size-6 place-items-center rounded-full border border-base-300 bg-base-100/90 text-base-content/70 shadow-sm transition hover:border-error hover:text-error"
      >
        <.icon name="hero-x-mark" class="size-3.5" />
      </button>
      <%!-- Terminal panes carry their own toolbar (label + controls), so the
            split-pane header is redundant for them — skip it so the terminal
            toolbar sits flush at the top instead of below an empty header strip. --%>
      <header
        :if={not terminal_pane?(@pane)}
        class={[
          "flex items-center justify-between gap-2 px-4 py-2",
          if(@bg_active or @veiled, do: "bg-transparent", else: "border-b border-base-300")
        ]}
      >
        <span class="truncate text-sm font-semibold">{pane_label(@pane)}</span>
      </header>
      <div class="min-h-0 flex-1 overflow-auto">
        <%= cond do %>
          <% is_nil(@pane) -> %>
            <p class="p-6 text-sm text-base-content/60">No view selected for this pane.</p>
          <% is_nil(@pane.module) -> %>
            <p class="p-6 text-sm text-base-content/60">
              "{@pane.label}" can't be opened in a split pane yet.
            </p>
          <% true -> %>
            {live_render(@socket, @pane.module,
              id: pane_live_id(@side, @pane),
              session: Map.put(@pane.child_session, "embedded", true)
            )}
        <% end %>
      </div>
    </section>
    """
  end

  defp pane_label(nil), do: "Empty"
  defp pane_label(%{label: label}), do: label
end
