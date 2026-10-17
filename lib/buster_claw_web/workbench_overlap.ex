defmodule BusterClawWeb.WorkbenchOverlap do
  @moduledoc "Normalized floating frames, independent of the saved grid."
  alias BusterClawWeb.WorkbenchState, as: Grid

  def sync(area) do
    keys = Grid.leaves(area.tree)
    frames = Map.take(Map.get(area, :frames, %{}), keys)

    frames =
      keys
      |> Enum.with_index()
      |> Enum.reduce(frames, fn {key, index}, acc ->
        Map.put_new(acc, key, seed(index))
      end)

    order = Enum.filter(Map.get(area, :z_order, []), &(&1 in keys)) |> Enum.uniq()
    Map.merge(area, %{frames: frames, z_order: order ++ (keys -- order)})
  end

  def seed(index) do
    offset = rem(index, 4) * 0.08
    %{"x" => 0.04 + offset, "y" => 0.04 + offset, "width" => 0.7, "height" => 0.7}
  end

  def frame(%{"x" => x, "y" => y, "width" => w, "height" => h})
      when is_number(x) and is_number(y) and is_number(w) and is_number(h) do
    width = clamp(w, 0.25, 1.0)
    height = clamp(h, 0.25, 1.0)

    {:ok,
     %{
       "x" => clamp(x, 0.0, 1.0 - width),
       "y" => clamp(y, 0.0, 1.0 - height),
       "width" => width,
       "height" => height
     }}
  end

  def frame(_), do: :error

  def restore(area, saved) do
    frames = if is_map(saved["frames"]), do: saved["frames"], else: %{}

    frames =
      for key <- Grid.leaves(area.tree),
          {:ok, value} <- [frame(frames[key])],
          into: %{},
          do: {key, value}

    order = if is_list(saved["z_order"]), do: Enum.take(saved["z_order"], 4), else: []
    sync(%{area | frames: frames, z_order: order})
  end

  def focus(area, key) do
    if key in Grid.leaves(area.tree),
      do: %{area | z_order: List.delete(area.z_order, key) ++ [key]},
      else: area
  end

  def move(%{mode: "overlap", zoom: nil} = area, key, value) do
    with true <- key in Grid.leaves(area.tree), {:ok, box} <- frame(value) do
      %{area | frames: Map.put(area.frames, key, box)} |> focus(key)
    else
      _ -> area
    end
  end

  def move(area, _key, _value), do: area
  def reset(area), do: sync(%{area | frames: %{}, z_order: []})
  defp clamp(value, low, high), do: max(low, min(high, value))
end
