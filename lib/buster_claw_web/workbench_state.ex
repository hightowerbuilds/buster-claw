defmodule BusterClawWeb.WorkbenchState do
  @moduledoc "Bounded, serializable split layout for the work-area panels."

  @panels [
    %{key: "chat", label: "Chat", icon: "hero-chat-bubble-left-right"},
    %{key: "workspace", label: "Workspace", icon: "hero-folder"},
    %{key: "terminal", label: "Terminal", icon: "hero-command-line"},
    %{key: "pockets", label: "Pockets", icon: "hero-squares-2x2"},
    %{key: "phone", label: "Phone", icon: "hero-phone"},
    %{key: "explained", label: "Explained", icon: "hero-book-open"},
    %{key: "activity", label: "Activity", icon: "hero-bolt"},
    %{key: "clock", label: "Clock", icon: "hero-clock"}
  ]
  @keys Enum.map(@panels, & &1.key)
  @presets [{"columns", "Side by side"}, {"rows", "Stacked"}, {"grid", "Balanced split"}]
  @preset_keys Enum.map(@presets, &elem(&1, 0))

  def panels, do: @panels
  def keys, do: @keys
  def new, do: %{tree: "chat", active: "chat", zoom: nil, preset: "columns"}

  def open(state, key) when key in @keys do
    tree =
      if key in leaves(state.tree) do
        state.tree
      else
        layout(leaves(state.tree) ++ [key], state.preset || "columns")
      end

    %{state | tree: tree, active: key, zoom: nil}
  end

  def open(state, _key), do: state

  def close(state, key) do
    tree = remove(state.tree, key)
    tree = if state.preset, do: layout(leaves(tree), state.preset), else: tree
    active = if state.active == key, do: List.first(leaves(tree)), else: state.active
    %{state | tree: tree, active: active, zoom: nil}
  end

  def focus(state, key) do
    if key in leaves(state.tree), do: %{state | active: key}, else: state
  end

  def zoom(state, key) do
    if key in leaves(state.tree),
      do: %{state | active: key, zoom: if(state.zoom == key, do: nil, else: key)},
      else: state
  end

  def arrange(state, preset) when preset in @preset_keys do
    keys = leaves(state.tree)

    if length(keys) >= minimum_panels(preset),
      do: %{state | tree: layout(keys, preset), preset: preset, zoom: nil},
      else: state
  end

  def arrange(state, _preset), do: state

  # The picker previews use these same trees, so its dots cannot promise a
  # different arrangement from the one applied by the server.
  def payload(state) do
    keys = leaves(state.tree)

    layouts =
      for {key, label} <- @presets do
        enabled = length(keys) >= minimum_panels(key)
        preview = if enabled, do: keys, else: Enum.take(@keys, minimum_panels(key))
        %{key: key, label: label, enabled: enabled, tree: layout(preview, key)}
      end

    Map.put(state, :layouts, layouts)
  end

  def resize(state, path, ratio) when is_list(path) and is_number(ratio) do
    if length(path) < length(@keys) and Enum.all?(path, &(&1 in ["first", "second"])) do
      %{state | tree: resize_node(state.tree, path, max(0.15, min(0.85, ratio)))}
    else
      state
    end
  end

  def resize(state, _path, _ratio), do: state

  def restore(%{"tree" => tree} = saved) do
    with {:ok, tree} <- validate(tree, 0),
         keys = leaves(tree),
         true <- length(keys) == length(Enum.uniq(keys)) do
      active = if saved["active"] in keys, do: saved["active"], else: List.first(keys)
      zoom = if saved["zoom"] in keys, do: saved["zoom"]
      preset = if saved["preset"] in @preset_keys, do: saved["preset"]
      %{tree: tree, active: active, zoom: zoom, preset: preset}
    else
      _ -> new()
    end
  end

  def restore(_saved), do: new()
  def leaves(nil), do: []
  def leaves(key) when is_binary(key), do: [key]
  def leaves(node), do: leaves(node["first"]) ++ leaves(node["second"])

  defp minimum_panels("grid"), do: 3
  defp minimum_panels(_preset), do: 2

  defp layout(keys, "columns"), do: evenly(keys, "horizontal")
  defp layout(keys, "rows"), do: evenly(keys, "vertical")
  defp layout([], "grid"), do: nil

  defp layout(keys, "grid") do
    columns = keys |> length() |> :math.sqrt() |> ceil()
    base = div(length(keys), columns)
    extra = rem(length(keys), columns)

    {stacks, []} =
      Enum.map_reduce(0..(columns - 1), keys, fn index, remaining ->
        size = base + if(index >= columns - extra, do: 1, else: 0)
        {column, rest} = Enum.split(remaining, size)
        {evenly(column, "vertical"), rest}
      end)

    evenly(stacks, "horizontal")
  end

  defp evenly([], _axis), do: nil
  defp evenly([only], _axis), do: only

  defp evenly(items, axis) do
    midpoint = div(length(items), 2)
    {first, second} = Enum.split(items, midpoint)

    %{
      "axis" => axis,
      "ratio" => midpoint / length(items),
      "first" => evenly(first, axis),
      "second" => evenly(second, axis)
    }
  end

  defp remove(key, key), do: nil

  defp remove(node, key) when is_map(node) do
    case {remove(node["first"], key), remove(node["second"], key)} do
      {nil, second} -> second
      {first, nil} -> first
      {first, second} -> %{node | "first" => first, "second" => second}
    end
  end

  defp remove(node, _key), do: node

  defp resize_node(node, [], ratio) when is_map(node), do: %{node | "ratio" => ratio}

  defp resize_node(node, [side | rest], ratio) when is_map(node),
    do: Map.update!(node, side, &resize_node(&1, rest, ratio))

  defp resize_node(node, _path, _ratio), do: node

  defp validate(_node, depth) when depth >= length(@keys), do: :error
  defp validate(nil, 0), do: {:ok, nil}
  defp validate(key, _depth) when key in @keys, do: {:ok, key}

  defp validate(%{"axis" => axis, "ratio" => ratio, "first" => a, "second" => b}, depth)
       when axis in ["horizontal", "vertical"] and is_number(ratio) do
    with {:ok, first} <- validate(a, depth + 1),
         {:ok, second} <- validate(b, depth + 1) do
      {:ok,
       %{
         "axis" => axis,
         "ratio" => max(0.15, min(0.85, ratio)),
         "first" => first,
         "second" => second
       }}
    end
  end

  defp validate(_node, _depth), do: :error
end
