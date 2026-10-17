defmodule BusterClawWeb.WorkAreasRestore do
  @moduledoc "Validates saved areas and migrates a legacy grid without losing its panels."
  alias BusterClawWeb.WorkbenchOverlap, as: Overlap
  alias BusterClawWeb.WorkbenchState, as: Grid

  def restore(%{"version" => 2, "areas" => areas} = saved, initial)
      when is_list(areas) and areas != [] and length(areas) <= 64 do
    with {:ok, restored} <- restore_areas(areas),
         keys = Enum.flat_map(restored, &Grid.leaves(&1.tree)),
         true <- length(keys) == length(Enum.uniq(keys)),
         ids = Enum.map(restored, & &1.id),
         true <- length(ids) == length(Enum.uniq(ids)) and "area-1" in ids do
      max_number = restored |> Enum.map(& &1.number) |> Enum.max()
      active = if saved["active_area_id"] in ids, do: saved["active_area_id"], else: "area-1"

      %{
        initial
        | areas: restored,
          active_area_id: active,
          next_area_number: counter(saved["next_area_number"], max_number + 1),
          next_terminal_number: counter(saved["next_terminal_number"], next_terminal(keys))
      }
    else
      _ -> initial
    end
  end

  def restore(%{"version" => _}, initial), do: initial

  def restore(%{"tree" => _} = saved, initial) do
    grid = Grid.restore(saved)
    migrate(grid, Grid.leaves(grid.tree), initial)
  end

  def restore(_, initial), do: initial

  defp migrate(grid, keys, initial) when length(keys) <= 256 do
    groups = if keys == [], do: [[]], else: Enum.chunk_every(keys, 4)

    areas =
      groups
      |> Enum.with_index(1)
      |> Enum.map(fn {group, number} ->
        part = if length(groups) == 1, do: grid, else: partition(grid, group)
        area(number, part)
      end)

    active = Enum.find(areas, hd(areas), &(grid.active in Grid.leaves(&1.tree)))

    %{
      initial
      | areas: areas,
        active_area_id: active.id,
        next_area_number: length(areas) + 1,
        next_terminal_number: next_terminal(keys)
    }
  end

  defp migrate(_grid, _keys, initial), do: initial

  defp area(number, grid, mode \\ "grid") do
    Map.merge(grid, %{id: "area-#{number}", number: number, mode: mode, frames: %{}, z_order: []})
    |> Overlap.sync()
  end

  defp restore_areas(areas) do
    Enum.reduce_while(areas, {:ok, []}, fn saved, {:ok, acc} ->
      case restore_area(saved) do
        {:ok, area} -> {:cont, {:ok, acc ++ [area]}}
        :error -> {:halt, :error}
      end
    end)
  end

  defp restore_area(%{"number" => number, "id" => id, "tree" => tree} = saved)
       when is_integer(number) and number > 0 and number < 1_000_000 do
    grid = Grid.restore(saved)
    keys = Grid.leaves(grid.tree)

    if id == "area-#{number}" and length(keys) <= 4 and grid.tree == tree do
      mode = if saved["mode"] == "overlap", do: "overlap", else: "grid"
      {:ok, area(number, grid, mode) |> Overlap.restore(saved)}
    else
      :error
    end
  end

  defp restore_area(_), do: :error

  defp partition(grid, keys) do
    empty = %{Grid.new() | tree: nil, active: nil}
    part = Enum.reduce(keys, empty, &Grid.open(&2, &1))
    part = Grid.arrange(part, grid.preset)

    %{
      part
      | active: if(grid.active in keys, do: grid.active, else: List.first(keys)),
        zoom: if(grid.zoom in keys, do: grid.zoom)
    }
  end

  defp next_terminal(keys) do
    keys
    |> Enum.filter(&Grid.terminal_slot?/1)
    |> Enum.map(fn
      "terminal" -> 1
      "terminal-" <> n -> String.to_integer(n)
    end)
    |> Enum.max(fn -> 0 end)
    |> Kernel.+(1)
  end

  defp counter(value, minimum) when is_integer(value) and value >= minimum and value <= 1_000_000,
    do: value

  defp counter(_value, minimum), do: minimum
end
