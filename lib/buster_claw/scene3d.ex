defmodule BusterClaw.Scene3d do
  @moduledoc """
  The 3D-scene channel for the homepage chat — vocabulary and validator only.

  Claude describes a scene by emitting a fenced ```` ```scene3d … ``` ```` block
  containing **declarative JSON**, never code. `extract/1` pulls those blocks out
  of the assistant text the same way `BusterClaw.SvgViewer.extract/1` pulls
  drawings; `validate/1` turns one block into a `t:BusterClaw.Scene3d.Types.scene/0`;
  `expand/1` resolves the `grid`/`stack`/`ring` composition helpers into a flat
  primitive list. Nothing here renders anything.

  ## Why JSON and not a shader, a canvas, or three.js

  Every alternative was ruled out before this module existed (see
  `daily-growth/roadmaps/SCENE3D_ROADMAP.md`, Part I). The short version: a chat
  card renders the moment the model emits it, with no user gesture in between, so
  the channel must not carry **anything executable**. A declarative scene is data
  we interpret; a shader or a canvas script is code we run. That is the whole
  argument, and it is why the vocabulary below is deliberately closed — a scene
  can only say things this module already knows how to say.

  ## The trust boundary is `validate/1`

  This module is the only place a model-authored scene is ever inspected. Every
  stage downstream (`Geometry`, `Project`, `Svg`) is written assuming its input is
  already sane: finite numbers, bounded magnitudes, a palette index in range, no
  missing keys. So `validate/1` is **strict, not lenient** — unknown keys are
  rejected rather than ignored, because a silently-dropped key is a scene that
  renders wrong with no way for anyone to see why, and because an ignored key is
  the seam a future field gets smuggled through.

  It is also **total**: it never raises, never returns an unnamed error, and never
  calls `String.to_atom/1` on model input (that would leak the atom table one
  scene at a time). Kind names come from a fixed lookup, not from the input.

  Note the posture is *inverted* from `SvgViewer`'s. There, model-authored markup
  reaches the DOM and a sanitizer tries to outsmart it. Here we generate the SVG
  ourselves from numbers we have already bounded, so the only model-controlled
  text in the entire pipeline is `label` — one field, length-capped here and
  HTML-escaped at render.

  ## The caps are the DoS surface

  A card renders unprompted, so every unbounded quantity in the vocabulary is a
  way for one message to hang the renderer. Each cap below carries the reason it
  is the number it is. The two that matter most are the node caps: one **before**
  expansion (bounding the expander's input) and one **after** (a `3×3×3` grid of
  grids is nine characters of JSON and 729 primitives).

  ## What the vocabulary deliberately does not have

  No materials, no lights, no transforms beyond position and Euler rotation, no
  hex colours, no camera vectors. Colours are indices into the app's validated
  5-slot palette so a card cannot be authored illegible; the camera is two orbit
  angles because models get look-at matrices wrong constantly. Expressiveness is
  meant to come from the composition helpers, not from more primitives — each new
  primitive is tessellation code plus a new way to be wrong.

  `:region` is the one primitive that has since cleared that bar, because nothing
  in the set could express an arbitrary footprint: a landmass drawn as a
  `:polyline` is a hairline outline of a shape nobody can see. `role` cleared it
  for the opposite reason — it adds no geometry at all, only *how loudly* a node
  is drawn, and it exists because the palette has five saturated series hues and
  no quiet one (see `t:BusterClaw.Scene3d.Types.role/0`).

  ## What a `:region` does not check

  A region's outline is checked for arity, count, magnitude and **degeneracy**
  (zero area, or every point on one line), but deliberately **not for
  self-intersection**. The check is affordable — 128 vertices is ~8k segment
  pairs — but the trade is wrong: a bow-tie polygon still renders as *something*,
  whereas rejecting one drops the entire card silently with no feedback to the
  model. Real coastline data is also full of near-touching and repeated points
  that a strict test would refuse. The guide asks for a non-crossing outline
  instead; if it crosses anyway, the fill is ugly and that is the accepted
  failure.

  ## Error reasons

  All errors are `{:error, atom()}`. The named reasons are stable enough to test
  against: `:not_a_string`, `:too_large`, `:invalid_json`, `:not_an_object`,
  `:unknown_key`, `:missing_field`, `:bad_camera`, `:bad_nodes`, `:empty_scene`,
  `:too_many_nodes`, `:too_deep`, `:unknown_kind`, `:bad_number`, `:out_of_range`,
  `:bad_vec3`, `:bad_size`, `:bad_color`, `:bad_role`, `:bad_label`,
  `:label_too_long`, `:bad_points`, `:too_many_points`, `:bad_outline`,
  `:degenerate_outline`, `:bad_count`, `:count_too_large`, `:bad_child`,
  `:not_a_scene`.
  """

  alias BusterClaw.Scene3d.Types

  @fence ~r/```scene3d\s*(.*?)```/s

  # 32 KB per block. JSON is far denser than the SVG channel's 100 KB of markup —
  # a scene at the node cap is a couple of KB, so this is already ~10x headroom.
  @max_bytes 32_000

  # Nodes the model may *write*, counted across the whole tree including helper
  # children. Bounds the expander's input before expansion can multiply it; a
  # hand-authored diagram never approaches this.
  @max_authored_nodes 128

  # Primitives after expansion. A sphere is the densest tessellation (16x8 = 128
  # faces), so 256 primitives is ~32k polygons worst case — the practical ceiling
  # for an inline SVG card. A 6x6x6 grid (216) still fits.
  @max_nodes 256

  # Composition helpers may nest this deep. Depth 4 allows grid-of-stacks-of-rings
  # and one more; past that the multiplicative blowup outruns any legible diagram.
  @max_depth 4

  # Per-axis repeat count in a helper. 32 in a row is already unreadable, and it
  # bounds a single helper before the product check below even runs.
  @max_axis 32

  # Vertices in a polyline. 256 segments outresolves the card.
  @max_points 256

  # Vertices in a region's outline. Lower than @max_points because a region is
  # *filled*: it fans out to n-2 triangles where a polyline costs n-1 hairlines.
  # 128 puts a region at the cap at roughly the same polygon cost as one sphere
  # (16x8 = 128 faces), which is the budget the flat node cap was sized against.
  # It is also generous enough for the use case — 128 points draws a recognisable
  # island, and a coastline needing more than that is a flat map, i.e. an SVG.
  @max_outline 128

  # Label length in graphemes. Labels billboard onto a small card; past ~120
  # characters it is a paragraph, not a label. Checked after a cheap byte guard
  # so a 10 MB "label" is refused without walking it.
  @max_label 120

  # Absolute magnitude of any coordinate, size, or radius. The camera auto-fits,
  # so scene scale is arbitrary and this bounds nothing anyone wants — but it
  # keeps the bounding-box and projection math away from float ranges where
  # sums stop being meaningful.
  @max_coord 1.0e6

  @kinds %{
    "box" => :box,
    "sphere" => :sphere,
    "cylinder" => :cylinder,
    "plane" => :plane,
    "capsule" => :capsule,
    "polyline" => :polyline,
    "arrow" => :arrow,
    "region" => :region,
    "grid" => :grid,
    "stack" => :stack,
    "ring" => :ring
  }

  @helpers [:grid, :stack, :ring]

  # The two node roles. Same fixed-lookup discipline as `@kinds` — model input
  # never reaches `String.to_atom/1`.
  @roles %{
    "solid" => :solid,
    "surface" => :surface
  }

  # Shape fields per kind, and which of them are required. Helpers deliberately
  # do NOT accept `color`/`label`/`role`: a helper is a layout, and since defaults
  # are applied here we could not tell "colour omitted" from "colour 0" at
  # expansion time, so propagating one to the copies would silently lose the
  # other. Better to reject the key and make the model put it on the child.
  @shape_fields %{
    box: ~w(size),
    sphere: ~w(r),
    cylinder: ~w(r h),
    plane: ~w(size),
    capsule: ~w(r h),
    polyline: ~w(points),
    arrow: ~w(from to),
    region: ~w(outline height),
    grid: ~w(child count gap),
    stack: ~w(child count gap),
    ring: ~w(child count r)
  }

  @required_fields %{
    box: ~w(size),
    sphere: ~w(r),
    cylinder: ~w(r h),
    plane: ~w(size),
    capsule: ~w(r h),
    polyline: ~w(points),
    arrow: ~w(from to),
    region: ~w(outline),
    grid: ~w(child count),
    stack: ~w(child count),
    ring: ~w(child count r)
  }

  @common_fields ~w(kind at rotate color role label)
  @helper_fields ~w(kind at rotate)

  @default_camera %{azimuth: 35.0, elevation: 25.0}

  # ── extract ────────────────────────────────────────────────────────────────

  @doc """
  Split assistant text into `{clean_text, blocks}`. `blocks` is the list of raw
  JSON strings from each ```` ```scene3d ```` block in document order;
  `clean_text` is the reply with those blocks removed and trimmed.

  Only bodies that look like a JSON object and fit the byte cap survive — fail
  closed. This does **not** validate; `validate/1` is the trust boundary and this
  is the cheap shape check that keeps obvious junk out of it.
  """
  @spec extract(String.t()) :: {String.t(), [String.t()]}
  def extract(text) when is_binary(text) do
    blocks =
      @fence
      |> Regex.scan(text)
      |> Enum.flat_map(fn [_full, body] ->
        body = String.trim(body)

        if String.starts_with?(body, "{") and String.ends_with?(body, "}") and
             byte_size(body) <= @max_bytes,
           do: [body],
           else: []
      end)

    clean = @fence |> Regex.replace(text, "") |> String.trim()
    {clean, blocks}
  end

  def extract(other), do: {other, []}

  # ── validate ───────────────────────────────────────────────────────────────

  @doc """
  Parse and strictly validate one raw `scene3d` block into a
  `t:BusterClaw.Scene3d.Types.scene/0`.

  Total: any input at all yields `{:ok, scene}` or `{:error, atom()}`, never a
  raise. Defaults are filled in for every omitted optional field (`at` at the
  origin, `rotate` zero, `color` 0, `role` `:solid`, `label` `nil`, `camera` a
  three-quarter view) so no stage downstream ever has to handle a missing key.

  The one deliberate exception is a region's `height`, which stays **absent**
  rather than becoming `nil` — its presence is what distinguishes a flat region
  from an extruded one, so a default would erase the distinction.

  Composition helpers are left nested here — `expand/1` resolves them.
  """
  @spec validate(String.t()) :: {:ok, Types.scene()} | {:error, atom()}
  def validate(json) when is_binary(json) do
    if byte_size(json) > @max_bytes do
      {:error, :too_large}
    else
      case decode(json) do
        {:ok, map} when is_map(map) -> scene(map)
        {:ok, _other} -> {:error, :not_an_object}
        :error -> {:error, :invalid_json}
      end
    end
  end

  def validate(_other), do: {:error, :not_a_string}

  # Jason rejects NaN/Infinity/1e400 itself, but a decoder that raised on some
  # pathological input would break totality, so the call is wrapped rather than
  # trusted.
  defp decode(json) do
    case Jason.decode(json) do
      {:ok, term} -> {:ok, term}
      {:error, _} -> :error
    end
  rescue
    _ -> :error
  catch
    _, _ -> :error
  end

  defp scene(map) do
    with :ok <- only_keys(map, ~w(camera nodes)),
         {:ok, camera} <- camera(Map.get(map, "camera")),
         {:ok, raw_nodes} <- node_list(Map.get(map, "nodes")),
         {:ok, nodes, _budget} <- nodes(raw_nodes, 1, @max_authored_nodes) do
      {:ok, %{camera: camera, nodes: nodes}}
    end
  end

  defp node_list(list) when is_list(list) and list != [], do: {:ok, list}
  defp node_list([]), do: {:error, :empty_scene}
  defp node_list(nil), do: {:error, :empty_scene}
  defp node_list(_), do: {:error, :bad_nodes}

  # ── camera ─────────────────────────────────────────────────────────────────

  defp camera(nil), do: {:ok, @default_camera}

  defp camera(map) when is_map(map) do
    with :ok <- only_keys(map, ~w(azimuth elevation)),
         {:ok, az} <- optional_num(map, "azimuth", @default_camera.azimuth),
         {:ok, el} <- optional_num(map, "elevation", @default_camera.elevation) do
      # Azimuth wraps (any angle frames something); elevation is *clamped*, not
      # rejected — a model asking to look straight down means "from above", and
      # 90 degrees exactly degenerates the up-vector.
      {:ok, %{azimuth: wrap360(az), elevation: clamp(el, -89.0, 89.0)}}
    end
  end

  defp camera(_), do: {:error, :bad_camera}

  defp wrap360(deg) do
    r = :math.fmod(deg, 360.0)
    if r < 0.0, do: r + 360.0, else: r
  end

  defp clamp(v, lo, hi), do: v |> max(lo) |> min(hi)

  # ── nodes ──────────────────────────────────────────────────────────────────

  defp nodes(list, depth, budget) do
    Enum.reduce_while(list, {:ok, [], budget}, fn raw, {:ok, acc, left} ->
      case node(raw, depth, left) do
        {:ok, n, left} -> {:cont, {:ok, [n | acc], left}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, acc, left} -> {:ok, Enum.reverse(acc), left}
      {:error, reason} -> {:error, reason}
    end
  end

  defp node(_raw, _depth, budget) when budget <= 0, do: {:error, :too_many_nodes}
  defp node(_raw, depth, _budget) when depth > @max_depth, do: {:error, :too_deep}

  defp node(raw, depth, budget) when is_map(raw) do
    with {:ok, kind} <- kind(Map.get(raw, "kind")),
         :ok <- only_keys(raw, allowed_keys(kind)),
         :ok <- require_keys(raw, @required_fields[kind]),
         {:ok, base} <- common(raw, kind) do
      shape(kind, raw, base, depth, budget - 1)
    end
  end

  defp node(_raw, _depth, _budget), do: {:error, :bad_node}

  defp allowed_keys(kind) when kind in @helpers, do: @helper_fields ++ @shape_fields[kind]
  defp allowed_keys(kind), do: @common_fields ++ @shape_fields[kind]

  # Never String.to_atom/1 on model input — a fixed lookup keeps the atom table
  # out of the model's reach.
  defp kind(name) when is_binary(name) do
    case Map.fetch(@kinds, name) do
      {:ok, kind} -> {:ok, kind}
      :error -> {:error, :unknown_kind}
    end
  end

  defp kind(_), do: {:error, :unknown_kind}

  # The universal fields, with their defaults. Helpers carry the structural
  # placeholders so the shape matches `t:Types.node_/0` even though they cannot
  # be authored with a colour or a label.
  defp common(raw, kind) when kind in @helpers do
    with {:ok, at} <- optional_vec3(raw, "at", {0.0, 0.0, 0.0}),
         {:ok, rotate} <- optional_vec3(raw, "rotate", {0.0, 0.0, 0.0}) do
      {:ok, %{kind: kind, at: at, rotate: degrees(rotate), color: 0, role: :solid, label: nil}}
    end
  end

  defp common(raw, kind) do
    with {:ok, at} <- optional_vec3(raw, "at", {0.0, 0.0, 0.0}),
         {:ok, rotate} <- optional_vec3(raw, "rotate", {0.0, 0.0, 0.0}),
         {:ok, color} <- color(Map.get(raw, "color", 0)),
         {:ok, role} <- role(Map.get(raw, "role")),
         {:ok, label} <- label(Map.get(raw, "label")) do
      {:ok,
       %{
         kind: kind,
         at: at,
         rotate: degrees(rotate),
         color: color,
         role: role,
         label: label
       }}
    end
  end

  # Rotations are Euler degrees; wrapping here means downstream trig never sees
  # 1e6 degrees, where float precision has already eaten the answer.
  defp degrees({x, y, z}), do: {wrap360(x), wrap360(y), wrap360(z)}

  # ── per-kind shape fields ──────────────────────────────────────────────────

  defp shape(:box, raw, base, _depth, budget) do
    with {:ok, size} <- size3(Map.fetch!(raw, "size")) do
      {:ok, Map.put(base, :size, size), budget}
    end
  end

  defp shape(:plane, raw, base, _depth, budget) do
    with {:ok, size} <- size2(Map.fetch!(raw, "size")) do
      {:ok, Map.put(base, :size, size), budget}
    end
  end

  defp shape(:sphere, raw, base, _depth, budget) do
    with {:ok, r} <- pos_num(Map.fetch!(raw, "r")) do
      {:ok, Map.put(base, :r, r), budget}
    end
  end

  defp shape(kind, raw, base, _depth, budget) when kind in [:cylinder, :capsule] do
    with {:ok, r} <- pos_num(Map.fetch!(raw, "r")),
         {:ok, h} <- pos_num(Map.fetch!(raw, "h")) do
      {:ok, base |> Map.put(:r, r) |> Map.put(:h, h), budget}
    end
  end

  defp shape(:polyline, raw, base, _depth, budget) do
    with {:ok, points} <- points(Map.fetch!(raw, "points")) do
      {:ok, Map.put(base, :points, points), budget}
    end
  end

  defp shape(:arrow, raw, base, _depth, budget) do
    with {:ok, from} <- vec3(Map.fetch!(raw, "from")),
         {:ok, to} <- vec3(Map.fetch!(raw, "to")) do
      {:ok, base |> Map.put(:from, from) |> Map.put(:to, to), budget}
    end
  end

  defp shape(:region, raw, base, _depth, budget) do
    with {:ok, outline} <- outline(Map.fetch!(raw, "outline")),
         {:ok, height} <- optional_height(raw) do
      {:ok, base |> Map.put(:outline, outline) |> put_height(height), budget}
    end
  end

  defp shape(:ring, raw, base, depth, budget) do
    with {:ok, count} <- count(:ring, Map.fetch!(raw, "count")),
         {:ok, r} <- pos_num(Map.fetch!(raw, "r")),
         {:ok, child, left} <- child(Map.fetch!(raw, "child"), depth, budget) do
      {:ok, base |> Map.put(:count, count) |> Map.put(:r, r) |> Map.put(:child, child), left}
    end
  end

  defp shape(kind, raw, base, depth, budget) when kind in [:grid, :stack] do
    with {:ok, count} <- count(kind, Map.fetch!(raw, "count")),
         {:ok, gap} <- optional_pos_num(raw, "gap", 1.0),
         {:ok, child, left} <- child(Map.fetch!(raw, "child"), depth, budget) do
      {:ok, base |> Map.put(:count, count) |> Map.put(:gap, gap) |> Map.put(:child, child), left}
    end
  end

  defp child(raw, depth, budget) when is_map(raw), do: node(raw, depth + 1, budget)
  defp child(_raw, _depth, _budget), do: {:error, :bad_child}

  # ── scalar / vector validation ─────────────────────────────────────────────

  # JSON integers are arbitrary-precision in Elixir, so the magnitude check must
  # come *before* the float conversion — `10 ** 400 * 1.0` raises.
  defp num(v) when is_integer(v) do
    if abs(v) > 1_000_000, do: {:error, :out_of_range}, else: {:ok, v * 1.0}
  end

  # A range check only. There is deliberately no NaN guard: JSON has no `NaN`
  # literal, so `Jason.decode/1` cannot produce one and this function sees
  # nothing else. (The usual test, `v != v`, also trips `credo --strict`, which
  # gates merges here — carrying an exclusion for an unreachable branch costs
  # more than it defends.) The range check is NOT redundant with it: `1e300` is
  # perfectly valid JSON and would wreck the bounding-box math downstream.
  defp num(v) when is_float(v) do
    if abs(v) > @max_coord, do: {:error, :out_of_range}, else: {:ok, v}
  end

  defp num(_), do: {:error, :bad_number}

  defp pos_num(v) do
    case num(v) do
      {:ok, f} when f > 0.0 -> {:ok, f}
      {:ok, _} -> {:error, :out_of_range}
      error -> error
    end
  end

  defp optional_num(map, key, default) do
    case Map.get(map, key) do
      nil -> {:ok, default}
      v -> num(v)
    end
  end

  defp optional_pos_num(map, key, default) do
    case Map.get(map, key) do
      nil -> {:ok, default}
      v -> pos_num(v)
    end
  end

  # Arity errors are `:bad_vec3`; the component errors pass through as
  # `:bad_number`/`:out_of_range` because "which way it was wrong" is the whole
  # value of a named reason.
  defp vec3([x, y, z]) do
    with {:ok, x} <- num(x),
         {:ok, y} <- num(y),
         {:ok, z} <- num(z) do
      {:ok, {x, y, z}}
    end
  end

  defp vec3(_), do: {:error, :bad_vec3}

  defp optional_vec3(map, key, default) do
    case Map.get(map, key) do
      nil -> {:ok, default}
      v -> vec3(v)
    end
  end

  defp size3([_, _, _] = list) do
    case vec3(list) do
      {:ok, {x, y, z} = size} when x > 0.0 and y > 0.0 and z > 0.0 -> {:ok, size}
      _ -> {:error, :bad_size}
    end
  end

  defp size3(_), do: {:error, :bad_size}

  # A plane is authored as `[width, depth]` — two numbers, because a plane has no
  # thickness. It is stored as a vec3 with a zero Y so the type stays uniform.
  defp size2([w, d]) do
    with {:ok, w} <- pos_num(w),
         {:ok, d} <- pos_num(d) do
      {:ok, {w, 0.0, d}}
    else
      _ -> {:error, :bad_size}
    end
  end

  defp size2(_), do: {:error, :bad_size}

  defp points(list) when is_list(list) do
    cond do
      length(list) < 2 -> {:error, :bad_points}
      length(list) > @max_points -> {:error, :too_many_points}
      true -> collect_vec3(list)
    end
  end

  defp points(_), do: {:error, :bad_points}

  defp collect_vec3(list) do
    Enum.reduce_while(list, {:ok, []}, fn raw, {:ok, acc} ->
      case vec3(raw) do
        {:ok, v} -> {:cont, {:ok, [v | acc]}}
        {:error, _} -> {:halt, {:error, :bad_points}}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      error -> error
    end
  end

  # ── region outlines ────────────────────────────────────────────────────────

  # An outline is 2D by construction: a region lies in the ground plane, so a `y`
  # component would only ever be a way to get it wrong. It is stored as `{x, z}`
  # pairs and `Geometry` supplies the zero.
  defp outline(list) when is_list(list) do
    cond do
      length(list) < 3 -> {:error, :bad_outline}
      length(list) > @max_outline -> {:error, :too_many_points}
      true -> collect_vec2(list)
    end
  end

  defp outline(_), do: {:error, :bad_outline}

  defp collect_vec2(list) do
    Enum.reduce_while(list, {:ok, []}, fn raw, {:ok, acc} ->
      case vec2(raw) do
        {:ok, v} -> {:cont, {:ok, [v | acc]}}
        {:error, _} -> {:halt, {:error, :bad_outline}}
      end
    end)
    |> case do
      {:ok, acc} -> acc |> Enum.reverse() |> non_degenerate()
      error -> error
    end
  end

  defp vec2([x, z]) do
    with {:ok, x} <- num(x),
         {:ok, z} <- num(z) do
      {:ok, {x, z}}
    end
  end

  defp vec2(_), do: {:error, :bad_outline}

  # A polygon with no area — every point on one line, or every point the same —
  # tessellates to nothing and would render as an invisible node the model
  # believes it drew. The tolerance is derived from the outline's **own bounding
  # box** rather than being an absolute epsilon, because scene scale is arbitrary
  # here (the camera auto-fits): an island authored in metres and the same island
  # in kilometres must get the same verdict.
  #
  # Self-intersection is NOT checked — see the moduledoc for why.
  defp non_degenerate(points) do
    xs = Enum.map(points, &elem(&1, 0))
    zs = Enum.map(points, &elem(&1, 1))
    extent = max(Enum.max(xs) - Enum.min(xs), Enum.max(zs) - Enum.min(zs))

    if abs(shoelace(points)) <= 1.0e-9 * extent * extent,
      do: {:error, :degenerate_outline},
      else: {:ok, points}
  end

  # Twice the signed area. Sign (winding) is `Geometry`'s problem, not ours.
  defp shoelace(points) do
    points
    |> Enum.zip(tl(points) ++ [hd(points)])
    |> Enum.reduce(0.0, fn {{x1, z1}, {x2, z2}}, acc -> acc + (x1 * z2 - x2 * z1) end)
  end

  defp optional_height(raw) do
    case Map.get(raw, "height") do
      nil -> {:ok, nil}
      v -> pos_num(v)
    end
  end

  # An omitted `height` leaves the key genuinely **absent**, not `nil`:
  # `t:Types.node_/0` marks it `optional`, and flat-versus-extruded is the one
  # distinction `Geometry` reads off the key's presence.
  defp put_height(node, nil), do: node
  defp put_height(node, height), do: Map.put(node, :height, height)

  # ── enums ──────────────────────────────────────────────────────────────────

  defp color(i) when is_integer(i) and i >= 0 and i <= 4, do: {:ok, i}
  defp color(_), do: {:error, :bad_color}

  defp role(nil), do: {:ok, :solid}

  defp role(name) when is_binary(name) do
    case Map.fetch(@roles, name) do
      {:ok, role} -> {:ok, role}
      :error -> {:error, :bad_role}
    end
  end

  defp role(_), do: {:error, :bad_role}

  defp label(nil), do: {:ok, nil}

  defp label(text) when is_binary(text) do
    cond do
      # Byte guard first: a multi-megabyte "label" is refused without walking it
      # for graphemes. 4 bytes is the widest UTF-8 codepoint.
      byte_size(text) > @max_label * 4 -> {:error, :label_too_long}
      String.length(text) > @max_label -> {:error, :label_too_long}
      Regex.match?(~r/[\x00-\x1F\x7F]/u, text) -> {:error, :bad_label}
      true -> {:ok, blank_to_nil(String.trim(text))}
    end
  end

  defp label(_), do: {:error, :bad_label}

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(text), do: text

  # ── counts ─────────────────────────────────────────────────────────────────

  # A helper's `count` is normalised to the 3-tuple the type carries, but the
  # shorthand differs by kind because the natural reading of "3" differs: a grid
  # of 3 is a 3x3 on the ground, a stack of 3 is three high, a ring of 3 is three
  # around. Anything ambiguous is rejected rather than guessed at.
  defp count(:grid, n) when is_integer(n), do: axes({n, 1, n})
  defp count(:grid, [nx, nz]), do: axes({nx, 1, nz})
  defp count(:grid, [nx, ny, nz]), do: axes({nx, ny, nz})
  defp count(:stack, n) when is_integer(n), do: axes({1, n, 1})
  defp count(:ring, n) when is_integer(n), do: axes({n, 1, 1})
  defp count(_kind, _other), do: {:error, :bad_count}

  defp axes({nx, ny, nz} = count) do
    cond do
      not (is_integer(nx) and is_integer(ny) and is_integer(nz)) -> {:error, :bad_count}
      nx < 1 or ny < 1 or nz < 1 -> {:error, :bad_count}
      nx > @max_axis or ny > @max_axis or nz > @max_axis -> {:error, :count_too_large}
      nx * ny * nz > @max_nodes -> {:error, :count_too_large}
      true -> {:ok, count}
    end
  end

  # ── key checks ─────────────────────────────────────────────────────────────

  defp only_keys(map, allowed) do
    if Enum.all?(Map.keys(map), &(&1 in allowed)),
      do: :ok,
      else: {:error, :unknown_key}
  end

  defp require_keys(map, required) do
    if Enum.all?(required, &Map.has_key?(map, &1)),
      do: :ok,
      else: {:error, :missing_field}
  end

  # ── expand ─────────────────────────────────────────────────────────────────

  @doc """
  Resolve every `:grid`/`:stack`/`:ring` helper into concrete primitives.

  Pure, and the place the node cap is enforced **after** expansion — a nine-byte
  grid must not be able to smuggle in ten thousand boxes. The budget is threaded
  through the recursion and expansion halts the instant it runs out, so a hostile
  scene never materialises the list it was trying to build.

  Layout is centred on the helper's `at`: a grid's copies straddle it rather than
  growing off one corner, which is what "a 3x3 of servers at the origin" means to
  anyone who writes it. `gap` is **centre-to-centre spacing**, deliberately
  independent of the child's size so the model does no arithmetic.

  Two documented simplifications. A helper's own `rotate` is applied to each
  *copy*, not to the lattice — rotating a lattice needs a matrix, which belongs
  to `Geometry`, and a tilted grid is not something a chat card needs. And a ring
  additionally spins each copy about Y by its own angle, so a ring of boxes reads
  as a ring rather than as n parallel boxes. Both are Euler *sums*, which is only
  exactly right when one of the two angles is zero; that is accepted here rather
  than solved.
  """
  @spec expand(Types.scene()) :: {:ok, Types.flat_scene()} | {:error, atom()}
  def expand(%{camera: camera, nodes: nodes}) when is_list(nodes) do
    case expand_list(nodes, {0.0, 0.0, 0.0}, {0.0, 0.0, 0.0}, @max_nodes) do
      {:ok, [], _left} -> {:error, :empty_scene}
      {:ok, flat, _left} -> {:ok, %{camera: camera, nodes: flat}}
      {:error, reason} -> {:error, reason}
    end
  end

  def expand(_other), do: {:error, :not_a_scene}

  defp expand_list(nodes, offset, spin, budget) do
    Enum.reduce_while(nodes, {:ok, [], budget}, fn node, {:ok, acc, left} ->
      case expand_node(node, offset, spin, left) do
        {:ok, produced, left} -> {:cont, {:ok, acc ++ produced, left}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, acc, left} -> {:ok, acc, left}
      {:error, reason} -> {:error, reason}
    end
  end

  defp expand_node(_node, _offset, _spin, budget) when budget <= 0,
    do: {:error, :too_many_nodes}

  defp expand_node(%{kind: kind} = helper, offset, spin, budget) when kind in @helpers do
    origin = add(offset, helper.at)
    spin = add(spin, helper.rotate)

    helper
    |> placements()
    |> Enum.reduce_while({:ok, [], budget}, fn {delta, twist}, {:ok, acc, left} ->
      case expand_node(helper.child, add(origin, delta), add(spin, twist), left) do
        {:ok, produced, left} -> {:cont, {:ok, acc ++ produced, left}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp expand_node(node, offset, spin, budget) do
    placed = %{node | at: add(offset, node.at), rotate: degrees(add(spin, node.rotate))}
    {:ok, [placed], budget - 1}
  end

  # Where each copy of a helper's child goes, and how much it is spun. Grids and
  # stacks are the same lattice with different counts; only the ring differs.
  defp placements(%{kind: :ring, count: {n, _, _}, r: r}) do
    Enum.map(0..(n - 1), fn i ->
      theta = 2.0 * :math.pi() * i / n
      {{r * :math.sin(theta), 0.0, r * :math.cos(theta)}, {0.0, theta * 180.0 / :math.pi(), 0.0}}
    end)
  end

  defp placements(%{count: {nx, ny, nz}, gap: gap}) do
    for i <- 0..(nx - 1), j <- 0..(ny - 1), k <- 0..(nz - 1) do
      {{centred(i, nx, gap), centred(j, ny, gap), centred(k, nz, gap)}, {0.0, 0.0, 0.0}}
    end
  end

  defp centred(i, n, gap), do: (i - (n - 1) / 2) * gap

  defp add({ax, ay, az}, {bx, by, bz}), do: {ax + bx, ay + by, az + bz}

  @doc """
  The whole pipeline for one raw ```` ```scene3d ```` body: validate → expand →
  tessellate → project → SVG. Returns `{:ok, svg}` or `{:error, reason}`.

  Total by construction — every stage below is a pure function and the two that
  can fail do so with a named reason, so a malformed scene costs the message
  nothing and never takes a LiveView down mid-conversation.
  """
  @spec render(String.t()) :: {:ok, String.t()} | {:error, atom()}
  def render(json) when is_binary(json) do
    with {:ok, scene} <- validate(json),
         {:ok, flat} <- expand(scene) do
      svg =
        flat
        |> BusterClaw.Scene3d.Geometry.build()
        |> BusterClaw.Scene3d.Project.run(flat.camera)
        |> BusterClaw.Scene3d.Svg.render()

      {:ok, svg}
    end
  end

  def render(_other), do: {:error, :not_a_string}

  @doc """
  The system-prompt addendum teaching the agent to build 3D scenes, appended to
  the homepage chat's Claude alongside `SvgViewer.guide/0`.

  Two things make this longer than the SVG guide, and both are deliberate:

  1. **The first paragraph draws the line between the two visual channels.** Two
     drawing tools in one prompt is this feature's biggest behavioural risk, and
     the likely failure is not picking wrong — it is using neither well.
  2. **It spells out the vocabulary's strict edges.** `validate/1` is a trust
     boundary and rejects a whole scene on one bad key, with no feedback loop
     back to the model. Every quirk omitted here surfaces to the user as "3D
     doesn't work" rather than "the guide was short", so the awkward specifics —
     `plane`'s two-element size, `region`'s two-element outline points, `ring`
     taking `r` not `gap`, helpers refusing `color`/`role`/`label` — earn their
     words.

  Three lines here are not vocabulary at all; they are the Phase 2 motivating
  failure written down. The flat-map sentence, the `role: "surface"` paragraph
  and the label budget each correspond to one way a real scene came out
  unreadable, and each is worded to say *why* rather than just *what* — a rule
  with its reason attached survives paraphrase, and a bare prohibition does not.
  """
  @spec guide() :: String.t()
  def guide do
    """
    You have two ways to show something visually and the choice matters. Use a \
    ```svg block for anything FLAT — diagrams, charts, flowcharts, annotated \
    sketches. Use a ```scene3d block ONLY when the third dimension carries real \
    meaning: physical structure, layering, volume, spatial arrangement. If a scene \
    would read the same flattened, it should have been an SVG. A FLAT MAP IS AN \
    SVG — reach for scene3d on a map only when something is genuinely in the third \
    dimension: terrain height, extruded regions, stacked layers.

    A ```scene3d block is JSON, never code:

    {"camera": {"azimuth": 35, "elevation": 25},
     "nodes": [
       {"kind": "box", "size": [2,1,1], "at": [0,0,0], "label": "API", "color": 1},
       {"kind": "cylinder", "r": 0.5, "h": 2, "at": [3,0,0], "label": "Queue"},
       {"kind": "arrow", "from": [1,0,0], "to": [2.5,0,0], "label": "publish"}
     ]}

    Primitives and their required shape fields:
    - box — size [w,h,d]        · sphere — r
    - cylinder — r, h           · capsule — r, h  (h is the BODY; total is h + 2r)
    - plane — size [w,d]        (TWO numbers: a plane has no thickness)
    - polyline — points [[x,y,z], …]
    - arrow — from [x,y,z], to [x,y,z]
    - region — outline [[x,z], …], and optional height

    A region is a FILLED polygon lying on the ground: a landmass, a zone, a \
    building footprint, a catchment. Its outline points are TWO numbers each — \
    [x,z], never y, because a region is on the ground by definition. Give at least \
    3, list them in order around the shape, and do not let the outline cross \
    itself. Add height to extrude the region into a prism, which is usually the \
    thing that earns a map its third dimension in the first place.

    Every node also takes at, rotate, color (an integer 0-4 — a palette index, \
    NEVER a hex string), label, and role.

    role is "solid" (the default — the subject) or "surface". Use "surface" for \
    ground, water, a floor, a base map: it is drawn quietly and does not frame the \
    shot. Reach for it instead of picking a colour — the palette is five saturated \
    series hues with no quiet slot, so water authored as color 3 comes out as a \
    wall of magenta across the whole card.

    For repetition use a helper instead of listing nodes by hand. A helper wraps a \
    `child` node:
    - grid — count 3 or [x,z] or [x,y,z], gap
    - stack — count n (up the Y axis), gap
    - ring — count n, r  (a ring takes RADIUS, not gap)

    Put color, role and label on the CHILD, not on the helper — a helper rejects them.

    Three rules that decide whether a scene reads at all:
    - LABEL what matters, and ONLY what matters. Aim for at most 6-8 labels in a \
      scene. Labels that do not fit are DROPPED, so thirteen labels leave you with \
      fewer legible ones than six would — name the rest in your prose instead. \
      Keep the shape count down too: a dozen well-labelled shapes beats a hundred.
    - Never set camera distance or zoom. The camera auto-fits your scene, so any \
      consistent scale works — pick the two viewing angles and nothing else.
    - Never make solids intersect. Faces are depth-sorted per face, so \
      interpenetrating shapes render wrong. Place things adjacent, not overlapping.

    An invalid scene is dropped silently and your message arrives with nothing \
    where the picture should be, so prefer the plain vocabulary above over \
    guessing at a field that might exist.

    The block is stripped from your message and rendered as a card in the chat — \
    refer to it naturally ("see the scene"), and never paste or describe the raw JSON.\
    """
  end
end
