defmodule BusterClawWeb.WorkbenchHook do
  @moduledoc "Layout events stay separate from the chat and widget event handlers."
  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [attach_hook: 4, push_event: 3]
  alias BusterClawWeb.WorkbenchState, as: State

  def mount(socket, params) do
    requested =
      if is_map(params), do: if(params["ask"] == "page", do: "chat", else: params["panel"])

    requested = if requested in State.keys(), do: requested

    socket
    |> assign(:workbench_requested, requested)
    |> assign(:workbench_restored, false)
    |> assign(:workbench, State.open(State.new(), requested))
    |> assign(
      :workbench_mounted,
      MapSet.new(["chat", "clock" | State.leaves(State.open(State.new(), requested).tree)])
    )
    |> attach_hook(:workbench, :handle_event, &handle_event/3)
  end

  def open(socket, key), do: put_state(socket, State.open(socket.assigns.workbench, key))

  defp handle_event("restore_workbench", %{"state" => saved}, socket) do
    if socket.assigns.workbench_restored do
      {:halt, socket}
    else
      state = State.restore(saved) |> State.open(socket.assigns.workbench_requested)
      {:halt, socket |> assign(:workbench_restored, true) |> put_state(state)}
    end
  end

  defp handle_event("workbench_focus", %{"key" => key}, socket),
    do: {:halt, put_state(socket, State.focus(socket.assigns.workbench, key))}

  defp handle_event("workbench_close", %{"key" => key}, socket),
    do: {:halt, put_state(socket, State.close(socket.assigns.workbench, key))}

  defp handle_event("workbench_zoom", %{"key" => key}, socket),
    do: {:halt, put_state(socket, State.zoom(socket.assigns.workbench, key))}

  defp handle_event("workbench_layout", %{"preset" => preset}, socket),
    do: {:halt, put_state(socket, State.arrange(socket.assigns.workbench, preset))}

  defp handle_event("workbench_resize", %{"path" => path, "ratio" => ratio}, socket),
    do: {:halt, put_state(socket, State.resize(socket.assigns.workbench, path, ratio))}

  defp handle_event(_event, _params, socket), do: {:cont, socket}

  defp put_state(socket, state) do
    mounted =
      Enum.reduce(State.leaves(state.tree), socket.assigns.workbench_mounted, &MapSet.put(&2, &1))

    socket
    |> assign(:workbench, state)
    |> assign(:workbench_mounted, mounted)
    |> push_event("workbench:sync", State.payload(state))
  end
end
