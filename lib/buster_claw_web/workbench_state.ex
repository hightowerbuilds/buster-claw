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
  # Up to four terminals, each a slot with its own key, shell and label
  # (TERMINAL_PANELS D1/D2). The first keeps the name "terminal" and the
  # "workbench" session key so a layout and a shell from before the slots
  # existed survive untouched. The limit is this list's length — nothing counts.
  @terminal_slots ["terminal", "terminal-2", "terminal-3", "terminal-4"]
  @keys Enum.map(@panels, & &1.key) ++ tl(@terminal_slots)
  # Four arrangements. Side by side and Stacked are for up to three panels —
  # four in a row or four stacked "all the way up" is not a layout anyone wants
  # (operator, 10-15) — so at four the work area moves to Paired columns on its
  # own: two columns of two; at five, three columns with two of them stacked.
  @presets [
    {"columns", "Side by side"},
    {"rows", "Stacked"},
    {"grid", "Balanced split"},
    {"pairs", "Paired columns"}
  ]
  @preset_keys Enum.map(@presets, &elem(&1, 0))
  @linear_max 3

  def panels, do: @panels
  def keys, do: @keys
  def terminal_slots, do: @terminal_slots
  def terminal_limit, do: length(@terminal_slots)
  def terminal_slot?(key), do: key in @terminal_slots
  def terminal_count(state), do: Enum.count(leaves(state.tree), &terminal_slot?/1)

  @doc "The PTY session key a terminal slot attaches to (persisted client-side)."
  def session_key("terminal"), do: "workbench"
  def session_key("terminal-" <> n), do: "workbench-" <> n

  @doc "The pane header label. Slots beyond the first are numbered like terminal tabs."
  def label("terminal-" <> n), do: "Terminal " <> n
  def label(key), do: Enum.find_value(@panels, fn panel -> panel.key == key && panel.label end)

  @doc """
  Open the lowest free terminal slot (laid into the current arrangement, and
  focused), or `{:error, :limit}` with the state untouched when all four are open.
  """
  def open_terminal(state) do
    case Enum.find(@terminal_slots, &(&1 not in leaves(state.tree))) do
      nil -> {:error, :limit}
      slot -> {:ok, open(state, slot)}
    end
  end

  def new, do: %{tree: "chat", active: "chat", zoom: nil, preset: "columns"}

  def open(state, key) when key in @keys do
    keys = leaves(state.tree)

    if key in keys do
      %{state | active: key, zoom: nil}
    else
      keys = keys ++ [key]
      preset = effective_preset(state.preset || "columns", length(keys))
      %{state | tree: layout(keys, preset), active: key, zoom: nil, preset: preset}
    end
  end

  def open(state, _key), do: state

  def close(state, key) do
    tree = remove(state.tree, key)
    preset = state.preset && effective_preset(state.preset, length(leaves(tree)))
    tree = if preset, do: layout(leaves(tree), preset), else: tree
    active = if state.active == key, do: List.first(leaves(tree)), else: state.active
    %{state | tree: tree, active: active, zoom: nil, preset: preset}
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

    if available?(preset, length(keys)),
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
        enabled = available?(key, length(keys))
        preview = if enabled, do: keys, else: Enum.take(@keys, minimum_panels(key))

        %{
          key: key,
          label: label,
          enabled: enabled,
          hint: if(enabled, do: nil, else: hint(key, length(keys))),
          tree: layout(preview, key)
        }
      end

    state
    |> Map.put(:layouts, layouts)
    |> Map.put(:terminal_count, terminal_count(state))
    |> Map.put(:terminal_limit, terminal_limit())
  end

  @doc """
  Put the open panels in a new order — a dragged panel dropped on another's spot,
  the ones between having slid over. The arrangement's shape is kept: a preset is
  relaid from the new order; a hand-built tree keeps its partitions and only
  changes which panel sits where. Anything but a permutation of the open panels
  is ignored.
  """
  def reorder(state, order) when is_list(order) do
    keys = leaves(state.tree)

    if order != keys and Enum.sort(order) == Enum.sort(keys) do
      tree = if state.preset, do: layout(order, state.preset), else: relabel(state.tree, order)
      %{state | tree: tree}
    else
      state
    end
  end

  def reorder(state, _order), do: state

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

  defp minimum_panels("pairs"), do: 4
  defp minimum_panels("grid"), do: 3
  defp minimum_panels(_preset), do: 2

  defp available?("pairs", count), do: count >= 4
  defp available?("grid", count), do: count >= 3
  defp available?(_linear, count), do: count >= 2 and count <= @linear_max

  defp hint("pairs", _count), do: "open four panels to use"
  defp hint("grid", _count), do: "open three panels to use"
  defp hint(_linear, count) when count > @linear_max, do: "holds up to three panels"
  defp hint(_linear, _count), do: "open two panels to use"

  # The arrangement a count of panels actually gets. A row or a column of four
  # becomes pairs; pairs below four fall back to side by side; a balanced
  # split needs its third panel.
  defp effective_preset(linear, count) when linear in ["columns", "rows"] and count > @linear_max,
    do: "pairs"

  defp effective_preset("pairs", count) when count < 4, do: "columns"
  defp effective_preset("grid", count) when count < 3, do: "columns"
  defp effective_preset(preset, _count), do: preset

  defp layout(keys, "columns"), do: evenly(keys, "horizontal")
  defp layout(keys, "rows"), do: evenly(keys, "vertical")

  # Columns of two, left to right; an odd panel stands alone in the last column.
  defp layout(keys, "pairs") do
    keys
    |> Enum.chunk_every(2)
    |> Enum.map(&evenly(&1, "vertical"))
    |> evenly("horizontal")
  end

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

  defp relabel(tree, order) do
    {tree, []} = relabel_walk(tree, order)
    tree
  end

  defp relabel_walk(nil, order), do: {nil, order}
  defp relabel_walk(key, [next | rest]) when is_binary(key), do: {next, rest}

  defp relabel_walk(node, order) do
    {first, order} = relabel_walk(node["first"], order)
    {second, order} = relabel_walk(node["second"], order)
    {%{node | "first" => first, "second" => second}, order}
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
