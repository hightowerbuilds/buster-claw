defmodule BusterClawWeb.WorkAreas do
  @moduledoc "Work areas own up to four panels, sharing stable panel identities."
  alias BusterClawWeb.WorkbenchOverlap, as: Overlap
  alias BusterClawWeb.WorkbenchState, as: Grid

  @max_areas 64
  def max_areas, do: @max_areas
  def capacity, do: 4

  def new do
    %{
      version: 2,
      areas: [area(1, Grid.new())],
      active_area_id: "area-1",
      next_area_number: 2,
      next_terminal_number: 1,
      revision: 0
    }
  end

  def area(number, grid, mode \\ "grid") do
    Map.merge(grid, %{
      id: "area-#{number}",
      number: number,
      mode: mode,
      frames: %{},
      z_order: []
    })
    |> Overlap.sync()
  end

  def current(state), do: Enum.find(state.areas, &(&1.id == state.active_area_id))
  def all_keys(state), do: Enum.flat_map(state.areas, &Grid.leaves(&1.tree))
  def terminals(state), do: Enum.filter(all_keys(state), &Grid.terminal_slot?/1)
  def label(%{number: 1}), do: "Work Area"
  def label(area), do: "Work Area #{area.number}"
  def path("area-1"), do: "/"
  def path(id), do: "/?area=#{id}"

  def select(state, id) do
    if Enum.any?(state.areas, &(&1.id == id)),
      do: %{state | active_area_id: id},
      else: state
  end

  def open(state, key) do
    if Grid.valid_key?(key) do
      next = open_valid(state, key)

      if Grid.terminal_slot?(key) and key in all_keys(next) do
        number =
          if key == "terminal",
            do: 1,
            else: key |> String.replace_prefix("terminal-", "") |> String.to_integer()

        %{next | next_terminal_number: max(next.next_terminal_number, number + 1)}
      else
        next
      end
    else
      state
    end
  end

  defp open_valid(state, key) do
    case Enum.find(state.areas, &(key in Grid.leaves(&1.tree))) do
      nil ->
        place(state, key)

      owner ->
        state |> select(owner.id) |> update(&(Grid.open(&1, key) |> Overlap.focus(key)), false)
    end
  end

  defp place(state, key) do
    active = current(state)

    cond do
      length(Grid.leaves(active.tree)) < capacity() ->
        update(state, &Grid.open(&1, key))

      length(state.areas) < @max_areas ->
        number = state.next_area_number
        empty = %{Grid.new() | tree: nil, active: nil}
        next = area(number, empty, active.mode)

        %{
          state
          | areas: state.areas ++ [next],
            active_area_id: next.id,
            next_area_number: number + 1
        }
        |> update(&Grid.open(&1, key))

      true ->
        state
    end
  end

  def open_terminal(state) do
    number = state.next_terminal_number
    key = if number == 1, do: "terminal", else: "terminal-#{number}"
    next = open(state, key)

    if next == state,
      do: {:error, :limit},
      else: {:ok, %{next | next_terminal_number: number + 1}}
  end

  def close(state, key) do
    case Enum.find(state.areas, &(key in Grid.leaves(&1.tree))) do
      nil -> state
      owner -> update_area(state, owner.id, &Grid.close(&1, key))
    end
  end

  def close_area(state, "area-1"), do: state

  def close_area(state, id) do
    areas = Enum.reject(state.areas, &(&1.id == id))

    if length(areas) == length(state.areas) do
      state
    else
      active = if state.active_area_id == id, do: hd(areas).id, else: state.active_area_id
      %{state | areas: areas, active_area_id: active, revision: state.revision + 1}
    end
  end

  def focus(state, key), do: update(state, &(Grid.focus(&1, key) |> Overlap.focus(key)), false)
  def zoom(state, key), do: update(state, &Grid.zoom(&1, key))
  def arrange(state, preset), do: update(state, &Grid.arrange(&1, preset))
  def reorder(state, order), do: update(state, &Grid.reorder(&1, order))
  def resize(state, path, ratio), do: update(state, &Grid.resize(&1, path, ratio))
  def reset(state), do: update(state, &Overlap.reset/1)

  def mode(state, mode) when mode in ["grid", "overlap"],
    do: update(state, &%{&1 | mode: mode, zoom: nil})

  def mode(state, _mode), do: state

  def move(state, %{"area_id" => id, "revision" => revision, "key" => key, "frame" => frame})
      when id == state.active_area_id and revision == state.revision,
      do: update(state, &Overlap.move(&1, key, frame))

  def move(state, _params), do: state

  def payload(state) do
    state
    |> Map.merge(Grid.payload(current(state)))
    |> Map.put(:terminal_count, length(terminals(state)))
    |> Map.put(:panel_capacity, capacity())
    |> Map.put(
      :area_tabs,
      Enum.map(state.areas, &%{id: &1.id, path: path(&1.id), label: label(&1)})
    )
  end

  def restore(saved), do: BusterClawWeb.WorkAreasRestore.restore(saved, new())

  defp update(state, fun, revision? \\ true),
    do: update_area(state, state.active_area_id, fun, revision?)

  defp update_area(state, id, fun, revision? \\ true) do
    areas =
      Enum.map(state.areas, fn area ->
        if area.id == id, do: area |> fun.() |> Overlap.sync(), else: area
      end)

    revision = if revision? and areas != state.areas, do: state.revision + 1, else: state.revision
    %{state | areas: areas, revision: revision}
  end
end
