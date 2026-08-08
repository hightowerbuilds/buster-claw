defmodule BusterClaw.Scene3d.Geometry do
  @moduledoc """
  Tessellation for the Scene3D pipeline: a validated flat scene in, world-space
  faces, lines and labels out.

  This is the stage that turns a *vocabulary* into *polygons*. Everything above
  it talks about "a cylinder at (2, 0, 0)"; everything below it only ever sees
  `t:BusterClaw.Scene3d.Types.face/0` — a wound polygon carrying its own normal.
  `Project` never learns what a cylinder is, and that is the point of cutting the
  pipeline here: adding a primitive is a function in this module and a change
  nowhere else.

  ## Winding is the contract, and winding is the bug

  Faces come out **counter-clockwise viewed from outside** the solid, with
  `normal` pointing outward. `Project` backface-culls on exactly that, so a face
  wound the wrong way does not render *wrong* — it silently vanishes and the
  solid gets a hole in it. Nothing raises, nothing logs. The defence is the
  property test in `geometry_test.exs`: for a closed convex solid, every face
  normal must point away from the solid's own centre. One assertion catches the
  whole class, which is why each primitive is tested against it rather than
  against a hand-copied vertex list nobody can proofread.

  Normals are recovered from the wound vertices by Newell's method rather than a
  single cross product. Caps are 16-gons here, and a cross product taken from the
  first three vertices of one is at the mercy of whichever corner happens to be
  nearly straight.

  ### The one exception: `:plane` is two faces

  Every other primitive is a closed solid, where "outside" is unambiguous and one
  face per surface is right. A plane is an open surface with no outside, so a
  single quad is culled from exactly half the possible camera positions — and
  that half is reachable, not theoretical: `elevation` validates down to -89, so
  a model looking *up* at something gets a ground plane that silently vanishes.

  So a plane emits **two coplanar quads with opposite winding**. The cull is what
  makes this correct rather than wasteful: `Project` keeps a face only when
  `dot(normal, eye - centroid) > 0`, so from any eye position exactly one of the
  pair survives and the other is discarded before it is ever drawn. There is no
  double-draw and therefore no z-fighting. The alternative — a per-face
  "don't cull me" flag — would change the shared `t:Types.face/0` contract for
  the sake of one primitive, which is a much worse trade than one extra quad.

  ## Rotation and handedness

  `rotate` is XYZ Euler in **degrees**, applied about the fixed world axes in the
  order X, then Y, then Z — `R = Rz · Ry · Rx` acting on column vectors — and the
  result is then translated by `at`. Each axis rotation is right-handed, matching
  the right-handed Y-up frame `Types` declares, so a **+90° rotation about Y
  sends +X to -Z**. That sentence is the whole handedness decision, and there is
  a test that fails if it ever stops being true.

  ## What this deliberately does not do

  * **Segment counts are fixed and low** (see the module attributes). This draws
    a card in a chat transcript, not a render farm; a smoother sphere costs
    polygons in a painter's-algorithm sort that is already the pipeline's
    expensive step.
  * **`h` on a `:cylinder` and a `:capsule` means the same thing** — the length of
    the straight section. A capsule's total height is therefore `h + 2r`, not
    `h`. The alternative (total height, body length derived) breaks whenever
    `2r > h` and there is no honest way to render that.
  * Nothing here is a process and nothing here does IO. `build/1` is a pure
    function of its argument.

  `build/1` also refuses to crash on a slightly-off node: a missing `size` gets a
  unit default, an unknown `kind` contributes nothing. The validator upstream is
  total and this should never fire — but the failure mode of raising is a blank
  chat card mid-conversation, which is worse than a wrong-sized box.
  """

  alias BusterClaw.Scene3d.Types

  # Low on purpose. A 16x8 sphere is 128 faces; every one of them goes through
  # the projector's per-frame depth sort, so this number is the pipeline's cost
  # knob. At card size the silhouette is what reads, and 16 segments is already
  # smooth enough that the facets are invisible.
  @sphere_segments 16
  @sphere_rings 8

  # The cylinder shares the sphere's segment count so a capsule's body and its
  # caps line up vertex-for-vertex instead of stitching two different densities.
  @cylinder_segments 16
  @capsule_cap_rings 4

  # An arrowhead is a few millimetres of the final image. Eight segments reads as
  # a cone; sixteen reads as the same cone and costs twice the sort.
  @arrow_head_segments 8
  @arrow_head_len_frac 0.22
  @arrow_head_radius_frac 0.4

  # Stroke widths pass through `Project` unscaled, straight into the SVG. That
  # sounds scale-dependent and is not, because these are CONSTANTS: the auto-fit
  # normalises every scene into a viewbox of nominal half-extent 100, so a fixed
  # width lands at the same visual weight whether the author worked at 0.01 or
  # 1000. Deriving these from the scene's own dimensions would break exactly
  # that. Do not make them scale-dependent.
  @polyline_width 1.0
  @arrow_shaft_width 1.5

  # Below this, Newell's sum is numerically indistinguishable from a zero-area
  # face. Such a face has no normal to speak of and cannot be shaded or culled
  # meaningfully, so it is dropped rather than given an invented one.
  @degenerate 1.0e-12

  @origin {0.0, 0.0, 0.0}

  @typep vec3 :: Types.vec3()
  # A wound polygon before it is given a colour and a normal.
  @typep poly :: [vec3()]
  # A line segment with its stroke width, before placement.
  @typep segment :: {vec3(), vec3(), float()}

  @doc """
  Tessellate every node of a flat scene into world space.

  Each node is built in its own local frame (centred on its origin, axis-aligned,
  Y up), then rotated by `rotate` and translated by `at`. Faces, lines and labels
  accumulate in node order; `Project` sorts them afterwards, so nothing here
  depends on that order.

  A node's `label`, when present, contributes exactly one `t:Types.label/0` at
  the node's centre — the local origin for the solids, the midpoint of the
  geometry for `:polyline` and `:arrow`, which have no origin worth anchoring to.
  """
  @spec build(Types.flat_scene()) :: Types.mesh()
  def build(scene) when is_map(scene) do
    meshes =
      scene
      |> Map.get(:nodes, [])
      |> List.wrap()
      |> Enum.map(&node_mesh/1)

    %{
      faces: Enum.flat_map(meshes, & &1.faces),
      lines: Enum.flat_map(meshes, & &1.lines),
      labels: Enum.flat_map(meshes, & &1.labels)
    }
  end

  def build(_), do: empty_mesh()

  # ── Node → mesh ─────────────────────────────────────────────────────────────

  defp node_mesh(node) when is_map(node) do
    color = color(node)
    rotate = vec(Map.get(node, :rotate), @origin)
    at = vec(Map.get(node, :at), @origin)

    {polys, segments, center} = primitive(node)

    %{
      faces:
        Enum.flat_map(polys, fn verts ->
          verts |> Enum.map(&place(&1, rotate, at)) |> face(color)
        end),
      lines:
        Enum.map(segments, fn {a, b, width} ->
          %{a: place(a, rotate, at), b: place(b, rotate, at), color: color, width: width}
        end),
      labels: label(node, place(center, rotate, at))
    }
  end

  defp node_mesh(_), do: empty_mesh()

  defp empty_mesh, do: %{faces: [], lines: [], labels: []}

  defp place(point, rotate, at), do: point |> rotate_xyz(rotate) |> add(at)

  defp label(node, at) do
    case Map.get(node, :label) do
      text when is_binary(text) and text != "" -> [%{at: at, text: text}]
      _ -> []
    end
  end

  # Newell's normal is computed on the *placed* vertices. Rotation is orthonormal
  # and orientation-preserving, so this is identical to rotating a local normal,
  # and it removes a whole second code path that could disagree with the winding.
  defp face(verts, color) when length(verts) >= 3 do
    case normalize(newell(verts)) do
      nil -> []
      normal -> [%{verts: verts, normal: normal, color: color}]
    end
  end

  defp face(_verts, _color), do: []

  # ── Primitives ──────────────────────────────────────────────────────────────
  #
  # Each returns {polygons, segments, local_centre}. Polygons are already wound
  # CCW-from-outside; that winding is the reason each one is spelled out rather
  # than generated from a corner-flipping loop.

  @spec primitive(map()) :: {[poly()], [segment()], vec3()}
  defp primitive(%{kind: :box} = node), do: {box_polys(size(node)), [], @origin}

  defp primitive(%{kind: :sphere} = node), do: {sphere_polys(radius(node)), [], @origin}

  defp primitive(%{kind: :cylinder} = node),
    do: {cylinder_polys(radius(node), height(node)), [], @origin}

  defp primitive(%{kind: :plane} = node), do: {plane_polys(size(node)), [], @origin}

  defp primitive(%{kind: :capsule} = node),
    do: {capsule_polys(radius(node), height(node)), [], @origin}

  defp primitive(%{kind: :polyline} = node), do: polyline(points(node))

  defp primitive(%{kind: :arrow} = node),
    do: arrow(vec(Map.get(node, :from), @origin), vec(Map.get(node, :to), @origin))

  # Composition helpers are gone by expansion time and anything else was refused
  # by the validator. Contributing nothing is the only sane response either way.
  defp primitive(_node), do: {[], [], @origin}

  # Box: six quads about the local origin. Written out longhand because a
  # generated version is exactly as long and impossible to check by eye.
  defp box_polys({w, h, d}) do
    x = abs(w) / 2
    y = abs(h) / 2
    z = abs(d) / 2

    [
      # +X
      [{x, -y, z}, {x, -y, -z}, {x, y, -z}, {x, y, z}],
      # -X
      [{-x, -y, -z}, {-x, -y, z}, {-x, y, z}, {-x, y, -z}],
      # +Y
      [{-x, y, z}, {x, y, z}, {x, y, -z}, {-x, y, -z}],
      # -Y
      [{-x, -y, -z}, {x, -y, -z}, {x, -y, z}, {-x, -y, z}],
      # +Z
      [{-x, -y, z}, {x, -y, z}, {x, y, z}, {-x, y, z}],
      # -Z
      [{x, -y, -z}, {-x, -y, -z}, {-x, y, -z}, {x, y, -z}]
    ]
  end

  # Plane: the box's +Y face, flattened — and then a second copy of it wound the
  # other way. See the moduledoc for why a plane is the one primitive that gets
  # two faces for one surface.
  defp plane_polys({w, _h, d}) do
    x = abs(w) / 2
    z = abs(d) / 2
    up = [{-x, 0.0, z}, {x, 0.0, z}, {x, 0.0, -z}, {-x, 0.0, -z}]

    [up, Enum.reverse(up)]
  end

  defp sphere_polys(r) do
    r
    |> lat_rings(0.0, @sphere_rings, 0.0, :math.pi(), :both)
    |> revolve()
  end

  defp cylinder_polys(r, h) do
    half = abs(h) / 2
    top = ring_points(half, r, @cylinder_segments)
    bottom = ring_points(-half, r, @cylinder_segments)

    # The side wall, then the two caps. A cap is a flat disc, not a pole, so it
    # is a polygon in its own right: increasing angle winds +Y, hence the reverse
    # on the bottom.
    revolve([{:ring, top}, {:ring, bottom}]) ++ [top, Enum.reverse(bottom)]
  end

  # A capsule is one surface of revolution, not three glued ones: the top
  # hemisphere's equator ring and the bottom hemisphere's equator ring sit at
  # y = +h/2 and y = -h/2, so the band *between* them is the cylindrical body and
  # falls out of `revolve/1` for free.
  defp capsule_polys(r, h) do
    half = abs(h) / 2
    half_pi = :math.pi() / 2

    top = lat_rings(r, half, @capsule_cap_rings, 0.0, half_pi, :top)
    bottom = lat_rings(r, -half, @capsule_cap_rings, half_pi, :math.pi(), :bottom)

    revolve(top ++ bottom)
  end

  defp polyline(points) do
    segments =
      points
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.map(fn [a, b] -> {a, b, @polyline_width} end)

    {[], segments, centroid(points)}
  end

  defp arrow(from, to) do
    {arrow_head(from, to), [{from, to, @arrow_shaft_width}], midpoint(from, to)}
  end

  # A cone at the `to` end, sized off the shaft so the head stays proportionate
  # at any scene scale (nothing downstream may assume a unit scale). The shaft
  # runs the full length and the head overlaps its tip; hiding the overlap would
  # cost a shortened line for no visible gain, since the head is opaque.
  defp arrow_head(from, to) do
    direction = sub(to, from)

    case normalize(direction) do
      nil ->
        []

      dir ->
        head_len = magnitude(direction) * @arrow_head_len_frac
        head_r = head_len * @arrow_head_radius_frac
        base = add(to, scale(dir, -head_len))
        {u, v} = basis(dir)

        ring =
          for j <- 0..(@arrow_head_segments - 1) do
            t = 2 * :math.pi() * j / @arrow_head_segments

            base
            |> add(scale(u, head_r * :math.cos(t)))
            |> add(scale(v, head_r * :math.sin(t)))
          end

        sides = for {a, b} <- cyclic_pairs(ring), do: [to, a, b]

        # The base disc faces backwards down the shaft, so it takes the reverse
        # winding of the ring the sides were built from.
        [Enum.reverse(ring) | sides]
    end
  end

  # ── Surfaces of revolution ──────────────────────────────────────────────────

  # Stitch a top-to-bottom stack of rings into bands. Quads between two rings,
  # triangles where a ring collapses to a pole. The winding — down the near edge
  # first, then around — is what makes every band face outward; flip either
  # traversal and the solid turns inside out.
  defp revolve(rings) do
    rings
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.flat_map(&band/1)
  end

  defp band([{:pole, p}, {:ring, lower}]) do
    for {a, b} <- cyclic_pairs(lower), do: [p, a, b]
  end

  defp band([{:ring, upper}, {:pole, p}]) do
    for {a, b} <- cyclic_pairs(upper), do: [a, p, b]
  end

  defp band([{:ring, upper}, {:ring, lower}]) do
    for {{u0, u1}, {l0, l1}} <- Enum.zip(cyclic_pairs(upper), cyclic_pairs(lower)) do
      [u0, l0, l1, u1]
    end
  end

  defp band(_), do: []

  # Rings of latitude on a sphere of radius `r` centred at `{0, cy, 0}`, sweeping
  # polar angle `phi0` (from +Y) to `phi1`. Poles are tagged by *index*, never by
  # testing the ring radius against zero: `sin(:math.pi())` is 1.2e-16, not 0.0,
  # so the south pole would never be recognised and the sphere would end in a
  # ring of coincident vertices.
  defp lat_rings(r, cy, rings, phi0, phi1, pole_at) do
    for i <- 0..rings do
      phi = phi0 + (phi1 - phi0) * (i / rings)

      cond do
        i == 0 and pole_at in [:top, :both] ->
          {:pole, {0.0, cy + r, 0.0}}

        i == rings and pole_at in [:bottom, :both] ->
          {:pole, {0.0, cy - r, 0.0}}

        true ->
          {:ring, ring_points(cy + r * :math.cos(phi), r * :math.sin(phi), @sphere_segments)}
      end
    end
  end

  # A horizontal ring. Angle runs +Z toward +X, which is the traversal that makes
  # the ring, read in order, a CCW polygon seen from +Y.
  defp ring_points(y, radius, segments) do
    for j <- 0..(segments - 1) do
      t = 2 * :math.pi() * j / segments
      {radius * :math.sin(t), y, radius * :math.cos(t)}
    end
  end

  defp cyclic_pairs([]), do: []
  defp cyclic_pairs(list), do: Enum.zip(list, tl(list) ++ [hd(list)])

  # ── Field access ────────────────────────────────────────────────────────────

  defp size(node), do: vec(Map.get(node, :size), {1.0, 1.0, 1.0})
  defp radius(node), do: abs(number(Map.get(node, :r), 0.5))
  defp height(node), do: abs(number(Map.get(node, :h), 1.0))

  defp points(node) do
    node
    |> Map.get(:points, [])
    |> List.wrap()
    |> Enum.flat_map(fn p ->
      case vec(p, nil) do
        nil -> []
        v -> [v]
      end
    end)
  end

  defp color(node) do
    case Map.get(node, :color) do
      c when is_integer(c) and c >= 0 and c <= 4 -> c
      _ -> 0
    end
  end

  defp vec({x, y, z}, _default) when is_number(x) and is_number(y) and is_number(z),
    do: {x * 1.0, y * 1.0, z * 1.0}

  defp vec(_other, default), do: default

  defp number(n, _default) when is_number(n), do: n * 1.0
  defp number(_other, default), do: default

  # ── Vector math ─────────────────────────────────────────────────────────────

  # `rotate` is XYZ Euler in degrees: X, then Y, then Z, about the fixed world
  # axes. Unrotated nodes are the common case and take the exact path — running
  # them through three trig pairs would dust every vertex with 1e-16 noise for no
  # reason.
  @spec rotate_xyz(vec3(), vec3()) :: vec3()
  defp rotate_xyz(p, {rx, ry, rz}) when rx == 0 and ry == 0 and rz == 0, do: p

  defp rotate_xyz(p, {rx, ry, rz}) do
    p
    |> rotate_x(rad(rx))
    |> rotate_y(rad(ry))
    |> rotate_z(rad(rz))
  end

  defp rotate_x({x, y, z}, a) do
    c = :math.cos(a)
    s = :math.sin(a)
    {x, y * c - z * s, y * s + z * c}
  end

  # Right-handed about +Y: this is the rotation that sends +X to -Z at +90°.
  defp rotate_y({x, y, z}, a) do
    c = :math.cos(a)
    s = :math.sin(a)
    {x * c + z * s, y, -x * s + z * c}
  end

  defp rotate_z({x, y, z}, a) do
    c = :math.cos(a)
    s = :math.sin(a)
    {x * c - y * s, x * s + y * c, z}
  end

  defp rad(degrees), do: degrees * :math.pi() / 180.0

  @spec add(vec3(), vec3()) :: vec3()
  defp add({ax, ay, az}, {bx, by, bz}), do: {ax + bx, ay + by, az + bz}

  @spec sub(vec3(), vec3()) :: vec3()
  defp sub({ax, ay, az}, {bx, by, bz}), do: {ax - bx, ay - by, az - bz}

  @spec scale(vec3(), float()) :: vec3()
  defp scale({x, y, z}, k), do: {x * k, y * k, z * k}

  @spec cross(vec3(), vec3()) :: vec3()
  defp cross({ax, ay, az}, {bx, by, bz}),
    do: {ay * bz - az * by, az * bx - ax * bz, ax * by - ay * bx}

  @spec magnitude(vec3()) :: float()
  defp magnitude({x, y, z}), do: :math.sqrt(x * x + y * y + z * z)

  @spec normalize(vec3()) :: vec3() | nil
  defp normalize(v) do
    case magnitude(v) do
      m when m < @degenerate -> nil
      m -> scale(v, 1.0 / m)
    end
  end

  defp midpoint(a, b), do: scale(add(a, b), 0.5)

  defp centroid([]), do: @origin

  defp centroid(points) do
    points
    |> Enum.reduce(@origin, &add/2)
    |> scale(1.0 / length(points))
  end

  # Newell's method: the area-weighted normal of a polygon, summed edge by edge.
  # Robust where a cross product of the first three vertices is not — a 16-gon
  # cap has corners that are very nearly straight.
  @spec newell(poly()) :: vec3()
  defp newell(verts) do
    verts
    |> cyclic_pairs()
    |> Enum.reduce(@origin, fn {{xi, yi, zi}, {xj, yj, zj}}, {ax, ay, az} ->
      {ax + (yi - yj) * (zi + zj), ay + (zi - zj) * (xi + xj), az + (xi - xj) * (yi + yj)}
    end)
  end

  # Any orthonormal pair spanning the plane perpendicular to `d`, chosen so that
  # `u x v == d` — the arrowhead's winding depends on that being right-handed.
  # The reference axis is swapped when `d` is near-vertical, since a cross
  # product with a nearly parallel vector loses all its precision.
  @spec basis(vec3()) :: {vec3(), vec3()}
  defp basis({_, dy, _} = d) do
    reference = if abs(dy) > 0.9, do: {1.0, 0.0, 0.0}, else: {0.0, 1.0, 0.0}
    u = reference |> cross(d) |> normalize() || {1.0, 0.0, 0.0}
    {u, cross(d, u)}
  end
end
