defmodule BusterClawWeb.WorkbenchHook do
  @moduledoc "Work area events and root-only URL patches, separate from panel content."
  import Phoenix.Component, only: [assign: 3]

  import Phoenix.LiveView,
    only: [attach_hook: 4, push_event: 3, push_patch: 2, stream: 4, stream_delete: 3]

  alias BusterClawWeb.WorkAreas, as: Areas
  alias BusterClawWeb.WorkbenchState, as: Grid

  def mount(socket, params, session \\ %{}) do
    routed = is_map(params)
    params = if routed, do: params, else: %{}
    requested = if params["ask"] == "page", do: "chat", else: params["panel"]
    requested = if Grid.valid_key?(requested), do: requested
    state = Areas.open(Areas.new(), requested)

    socket =
      socket
      |> assign(:workbench_requested, requested)
      |> assign(:workbench_explicit_area, Map.has_key?(params, "area"))
      |> assign(:workbench_route_area, params["area"] || session["workbench_area"] || "area-1")
      |> assign(:workbench_routed, routed)
      |> assign(:workbench_restored, false)
      |> assign(:work_areas, state)
      |> assign(:workbench, Areas.payload(state))
      |> assign(:workbench_mounted, MapSet.new(["chat", "clock" | Areas.all_keys(state)]))
      |> stream(:workbench_terminals, terminal_items(state), dom_id: &"workbench-pane-#{&1.id}")
      |> attach_hook(:workbench, :handle_event, &handle_event/3)

    if routed,
      do: attach_hook(socket, :workbench_params, :handle_params, &handle_params/3),
      else: socket
  end

  def open(socket, key) do
    state = Areas.open(socket.assigns.work_areas, key)
    socket = put_state(socket, state)

    if Grid.valid_key?(key) and key not in Areas.all_keys(state),
      do: push_event(socket, "workbench:limit", %{limit: Areas.max_areas()}),
      else: socket
  end

  defp handle_params(params, _uri, socket) do
    id = params["area"] || "area-1"
    socket = assign(socket, :workbench_route_area, id)

    socket =
      if socket.assigns.workbench_restored do
        state = socket.assigns.work_areas
        id = if Enum.any?(state.areas, &(&1.id == id)), do: id, else: "area-1"
        put_state(socket, Areas.select(state, id))
      else
        socket
      end

    {:halt, socket}
  end

  defp handle_event("restore_workbench", %{"state" => saved} = params, socket) do
    if socket.assigns.workbench_restored do
      {:halt, socket}
    else
      restored = Areas.restore(saved)

      migrating =
        is_map(saved) and not Map.has_key?(saved, "version") and
          not socket.assigns.workbench_explicit_area

      id = if migrating, do: restored.active_area_id, else: socket.assigns.workbench_route_area
      state = Areas.select(restored, id)
      key = socket.assigns.workbench_requested
      state = if params["create_terminal"] == true, do: state, else: Areas.open(state, key)
      socket = socket |> assign(:workbench_restored, true) |> put_state(state)

      if params["create_terminal"] == true,
        do: handle_event("workbench_terminal_new", %{}, socket),
        else: {:halt, socket}
    end
  end

  defp handle_event("workbench_clear_intent", _params, socket) do
    {:halt,
     push_patch(socket, to: Areas.path(socket.assigns.work_areas.active_area_id), replace: true)}
  end

  defp handle_event("workbench_focus", %{"key" => key}, socket),
    do: {:halt, put_state(socket, Areas.focus(socket.assigns.work_areas, key))}

  defp handle_event("workbench_close", %{"key" => key}, socket),
    do: {:halt, put_state(socket, Areas.close(socket.assigns.work_areas, key))}

  defp handle_event("workbench_close_area", %{"id" => id}, socket),
    do: {:halt, put_state(socket, Areas.close_area(socket.assigns.work_areas, id))}

  defp handle_event("workbench_select_area", %{"id" => id}, socket),
    do: {:halt, put_state(socket, Areas.select(socket.assigns.work_areas, id))}

  defp handle_event("workbench_terminal_new", _params, socket) do
    case Areas.open_terminal(socket.assigns.work_areas) do
      {:ok, state} ->
        {:halt, put_state(socket, state)}

      {:error, :limit} ->
        {:halt, push_event(socket, "workbench:limit", %{limit: Areas.max_areas()})}
    end
  end

  defp handle_event("workbench_zoom", %{"key" => key}, socket),
    do: {:halt, put_state(socket, Areas.zoom(socket.assigns.work_areas, key))}

  defp handle_event("workbench_layout", %{"preset" => preset}, socket),
    do: {:halt, put_state(socket, Areas.arrange(socket.assigns.work_areas, preset))}

  defp handle_event("workbench_mode", %{"mode" => mode}, socket),
    do: {:halt, put_state(socket, Areas.mode(socket.assigns.work_areas, mode))}

  defp handle_event("workbench_reset_positions", _params, socket),
    do: {:halt, put_state(socket, Areas.reset(socket.assigns.work_areas))}

  defp handle_event("workbench_move", params, socket),
    do: {:halt, put_state(socket, Areas.move(socket.assigns.work_areas, params))}

  defp handle_event("workbench_reorder", %{"order" => order} = params, socket),
    do: {:halt, mutate_layout(socket, params, &Areas.reorder(&1, order))}

  defp handle_event("workbench_resize", %{"path" => path, "ratio" => ratio} = params, socket),
    do: {:halt, mutate_layout(socket, params, &Areas.resize(&1, path, ratio))}

  defp handle_event(_event, _params, socket), do: {:cont, socket}

  defp mutate_layout(socket, params, fun) do
    state = socket.assigns.work_areas

    current? =
      Map.get(params, "area_id", state.active_area_id) == state.active_area_id and
        Map.get(params, "revision", state.revision) == state.revision

    put_state(socket, if(current?, do: fun.(state), else: state))
  end

  defp put_state(socket, state) do
    removed = Areas.terminals(socket.assigns.work_areas) -- Areas.terminals(state)

    mounted =
      Enum.reduce(Areas.all_keys(state), socket.assigns.workbench_mounted, &MapSet.put(&2, &1))

    mounted = Enum.reduce(removed, mounted, &MapSet.delete(&2, &1))
    socket = Enum.reduce(removed, socket, &stream_delete(&2, :workbench_terminals, %{id: &1}))

    socket =
      socket
      |> assign(:work_areas, state)
      |> assign(:workbench, Areas.payload(state))
      |> assign(:workbench_mounted, mounted)
      |> stream(:workbench_terminals, terminal_items(state), [])
      |> push_event("workbench:sync", Areas.payload(state))

    if socket.assigns.workbench_restored and
         socket.assigns.workbench_route_area != state.active_area_id do
      socket = assign(socket, :workbench_route_area, state.active_area_id)

      if socket.assigns.workbench_routed,
        do: push_patch(socket, to: Areas.path(state.active_area_id)),
        else:
          push_event(socket, "workbench:navigate-area", %{path: Areas.path(state.active_area_id)})
    else
      socket
    end
  end

  defp terminal_items(state), do: Enum.map(Areas.terminals(state), &%{id: &1})
end
