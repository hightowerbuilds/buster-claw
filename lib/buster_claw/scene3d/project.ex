defmodule BusterClaw.Scene3d.Project do
  @moduledoc """
  The projection stage: a world-space `t:BusterClaw.Scene3d.Types.mesh/0` and two
  orbit angles in, a flat, shaded, depth-sorted
  `t:BusterClaw.Scene3d.Types.frame/0` out. Pure arithmetic — no processes, no
  IO, no state.

  This is where the scene stops being geometry and becomes a picture. Everything
  downstream (`Scene3d.Svg`) is a serializer: it emits the lists in the order it
  gets them and makes no spatial decisions of its own. That split is deliberate,
  because it means the two hard-to-get-right things — framing and draw order —
  live in exactly one testable place.

  ## Auto-fit is the point (roadmap decision 3)

  The model never says how far away the camera is, because asking it to would
  reproduce the single most common failure mode: a scene authored in millimetres
  or in kilometres that renders as a dot or as a wall of colour. Instead we take
  the scene's bounding box, place the camera at a distance proportional to its
  radius, and crop the `viewbox` to the projected extent.

  The consequence worth stating plainly: **the projected 2D points are invariant
  under a uniform scaling of the whole scene.** Multiply every coordinate by
  1000 and this module returns the same picture. There is a test that asserts
  exactly that, and it is the most important test in the file.

  `depth` is the honest exception. It is raw view-space depth in scene units, as
  the contract specifies, so it *does* scale with the scene. Only the *ordering*
  is scale-invariant. A future depth cue (roadmap Phase 2) must normalise against
  the frame's own min/max rather than treating `depth` as a 0–1 quantity.

  ## Painter's algorithm, and what it gets wrong (roadmap decision 7)

  Faces are culled by their outward normal and then sorted back-to-front by
  view-space centroid depth. **This is wrong for interpenetrating solids**, and
  it is wrong for long thin polygons that straddle each other's centroids — a
  centroid is a single number standing in for a whole surface, and no ordering of
  whole polygons can be correct when two of them cross.

  That is accepted rather than solved. The authoring guide forbids intersecting
  geometry; when the model does it anyway the artifact is visible, local, and
  costs nothing but a slightly wrong-looking card. **Do not add a BSP tree here.**
  A binary space partition would mean splitting polygons at render time, a new
  class of numerical edge case, and several hundred lines of the most bug-prone
  code in graphics — to fix an artifact in a chat message. If this is ever refiled
  as a bug, the answer is this paragraph.

  A second, smaller ordering limit falls out of the frame contract: `polys` and
  `lines` are separate lists, so each is sorted independently and `Svg` must draw
  one group entirely before the other. Lines therefore cannot weave through
  polygons by depth. For labelled diagrams — arrows and polylines that are meant
  to be read, not occluded — drawing lines on top is the more useful failure, so
  the contract's shape and the feature's intent happen to agree.

  ## Culling, clipping and the shading light

  Backface culling uses the perspective-correct test (is the eye on the outward
  side of the face's plane?) rather than the cheaper normal-vs-view-direction
  test, since with a real perspective camera those disagree near the frame edges.
  It trusts `Geometry` to wind faces CCW-from-outside; a face wound backwards
  vanishes silently, which is why the contract calls that out as the bug worth a
  test per primitive.

  There is **no near-plane clipping**. A primitive with any vertex at or behind
  the camera is dropped whole rather than split. Auto-fit makes this unreachable
  in practice — the camera sits well outside the bounding sphere, so nothing in
  the scene can be behind it — so the check is a guard against a degenerate
  camera, not a clipper. Building a real clipper for a case that cannot occur
  would be speculative work.

  `shade` is computed against a key light fixed in **view** space, not world
  space, so the light orbits with the camera. That is not physically honest — a
  real light does not follow your head — but it guarantees the scene is lit from
  the front at every azimuth, and a diagram that goes dark when you spin it is a
  worse lie than one whose lighting is a little too convenient. It is always
  computed even though Phase 1's renderer barely uses it, so that Phase 2 shading
  is a render-side change only.
  """

  alias BusterClaw.Scene3d.Types

  # A modest vertical field of view. Wide angles make a small card look like a
  # fisheye; too narrow and the scene reads as flat isometric with no depth cue
  # at all. 35° gives enough convergence to see that a box is a box.
  @fov_deg 35.0

  # Fraction of the projected extent left as breathing room on each side, so
  # nothing touches the card border.
  @margin 0.06

  # Half-width of the frustum in SVG user units. The viewbox is cropped to the
  # projected content, so this is a nominal working scale, not a hard bound.
  @half_extent 100.0

  # The contract clamps elevation to (-89, 89) so the up-vector never
  # degenerates. We re-clamp rather than trust it: at exactly ±90 the view basis
  # is undefined and the cross product collapses to a zero vector.
  @max_elevation 89.0

  # Key light in view space: up, slightly left, mostly toward the viewer.
  @key_light {-0.35, 0.55, 0.76}

  # Floor on the shaded value, so an unlit face is dim rather than black.
  @ambient 0.35

  # A scene with no extent (one point, or every point coincident) has no scale to
  # fit to, so we invent one and the whole thing lands in the middle of the card.
  @fallback_radius 1.0

  # Below this the perspective divide is meaningless; drop the primitive instead.
  @min_depth 1.0e-9

  # Below this the projected content is a point, not a picture; use the default
  # frame rather than zooming to absurdity.
  @min_viewbox_extent 1.0e-6

  @typep basis :: %{eye: Types.vec3(), x: Types.vec3(), y: Types.vec3(), z: Types.vec3()}

  @doc """
  Project a mesh through an orbit camera into a finished 2D frame.

  Total: an empty mesh, a zero-extent mesh and an out-of-range elevation all
  return a well-formed frame rather than raising. `polys` and `lines` come back
  sorted furthest-first; `labels` keep their mesh order and carry depth for the
  renderer's own use, because labels draw last and unoccluded (decision 5).
  """
  @spec run(Types.mesh(), Types.camera()) :: Types.frame()
  def run(mesh, camera) do
    {center, radius} = bounds(mesh_points(mesh))
    cam = basis(camera, center, radius)

    # Combines the perspective term (1 / tan(fov/2)) with the screen scale, so
    # the hot path is one multiply and one divide per coordinate.
    scale = @half_extent / :math.tan(radians(@fov_deg) / 2.0)

    polys =
      mesh.faces
      |> Enum.flat_map(&face_poly(&1, cam, scale))
      |> back_to_front()

    lines =
      mesh.lines
      |> Enum.flat_map(&line_poly(&1, cam, scale))
      |> back_to_front()

    labels = Enum.flat_map(mesh.labels, &label_poly(&1, cam, scale))

    %{polys: polys, lines: lines, labels: labels, viewbox: viewbox(polys, lines, labels)}
  end

  # ── Framing ─────────────────────────────────────────────────────────────────

  @spec mesh_points(Types.mesh()) :: [Types.vec3()]
  defp mesh_points(mesh) do
    Enum.flat_map(mesh.faces, & &1.verts) ++
      Enum.flat_map(mesh.lines, &[&1.a, &1.b]) ++
      Enum.map(mesh.labels, & &1.at)
  end

  # Bounding-box centre plus the radius of the sphere that encloses the box. The
  # sphere overestimates for elongated scenes, which only costs a little slack in
  # the camera distance — the viewbox crop takes the slack back afterwards.
  @spec bounds([Types.vec3()]) :: {Types.vec3(), float()}
  defp bounds([]), do: {{0.0, 0.0, 0.0}, 0.0}

  defp bounds(points) do
    {min_x, max_x} = points |> Enum.map(&elem(&1, 0)) |> Enum.min_max()
    {min_y, max_y} = points |> Enum.map(&elem(&1, 1)) |> Enum.min_max()
    {min_z, max_z} = points |> Enum.map(&elem(&1, 2)) |> Enum.min_max()

    center = {(min_x + max_x) / 2.0, (min_y + max_y) / 2.0, (min_z + max_z) / 2.0}
    half = {(max_x - min_x) / 2.0, (max_y - min_y) / 2.0, (max_z - min_z) / 2.0}

    {center, norm(half)}
  end

  # Orbit angles → an eye position and an orthonormal view basis. `azimuth`
  # rotates around Y, `elevation` lifts above the XZ plane; at (0, 0) the eye
  # sits on +Z looking down -Z, which is the contract's default camera.
  @spec basis(Types.camera(), Types.vec3(), float()) :: basis()
  defp basis(camera, center, radius) do
    az = radians(camera.azimuth)
    el = radians(clamp(camera.elevation, -@max_elevation, @max_elevation))

    # Direction from the scene centre toward the eye.
    dir = {
      :math.cos(el) * :math.sin(az),
      :math.sin(el),
      :math.cos(el) * :math.cos(az)
    }

    radius = if radius > 0.0, do: radius, else: @fallback_radius

    # Distance at which a sphere of this radius exactly fills the vertical FOV.
    # Proportional to radius, which is what makes the whole stage scale-free.
    distance = radius / :math.sin(radians(@fov_deg) / 2.0)

    z = normalize(dir)
    x = normalize(cross({0.0, 1.0, 0.0}, z))
    y = cross(z, x)

    %{eye: add(center, mul(dir, distance)), x: x, y: y, z: z}
  end

  # ── Per-primitive projection ────────────────────────────────────────────────

  @spec face_poly(Types.face(), basis(), float()) :: [Types.poly()]
  defp face_poly(%{verts: []}, _cam, _scale), do: []

  defp face_poly(face, cam, scale) do
    if facing?(face, cam) do
      case project_all(face.verts, cam, scale) do
        {:ok, points, depths} ->
          [
            %{
              points: points,
              color: face.color,
              shade: shade(face.normal, cam),
              depth: mean(depths)
            }
          ]

        :error ->
          []
      end
    else
      []
    end
  end

  @spec line_poly(Types.line(), basis(), float()) :: [Types.poly_line()]
  defp line_poly(line, cam, scale) do
    case project_all([line.a, line.b], cam, scale) do
      {:ok, [a, b], depths} ->
        [%{a: a, b: b, color: line.color, width: line.width, depth: mean(depths)}]

      _ ->
        []
    end
  end

  @spec label_poly(Types.label(), basis(), float()) :: [Types.poly_label()]
  defp label_poly(label, cam, scale) do
    case project(label.at, cam, scale) do
      {:ok, point, depth} -> [%{at: point, text: label.text, depth: depth}]
      :error -> []
    end
  end

  # A face is visible when the eye lies on its outward side. Using the plane test
  # rather than dot(normal, view_direction) matters under perspective: a face at
  # the edge of frame can face the eye while pointing away from the view axis.
  @spec facing?(Types.face(), basis()) :: boolean()
  defp facing?(face, cam) do
    dot(face.normal, sub(cam.eye, centroid(face.verts))) > 0.0
  end

  # 0.0–1.0 from the face normal against the view-space key light. Both vectors
  # are normalized defensively: a non-unit normal out of `Geometry` would
  # otherwise push the result outside the contract's range.
  @spec shade(Types.vec3(), basis()) :: float()
  defp shade(normal, cam) do
    n = normalize(normal)
    n_view = {dot(n, cam.x), dot(n, cam.y), dot(n, cam.z)}
    lambert = max(0.0, dot(normalize(n_view), normalize(@key_light)))

    clamp(@ambient + (1.0 - @ambient) * lambert, 0.0, 1.0)
  end

  @spec project_all([Types.vec3()], basis(), float()) ::
          {:ok, [Types.vec2()], [float()]} | :error
  defp project_all(points, cam, scale) do
    Enum.reduce_while(points, {:ok, [], []}, fn p, {:ok, pts, deps} ->
      case project(p, cam, scale) do
        {:ok, pt, depth} -> {:cont, {:ok, [pt | pts], [depth | deps]}}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, pts, deps} -> {:ok, Enum.reverse(pts), deps}
      :error -> :error
    end
  end

  # Perspective divide. `depth` is distance along the view axis away from the
  # eye, so larger is further — the sense the painter sort wants. SVG's Y grows
  # downward, hence the flip.
  @spec project(Types.vec3(), basis(), float()) :: {:ok, Types.vec2(), float()} | :error
  defp project(point, cam, scale) do
    v = sub(point, cam.eye)
    depth = -dot(v, cam.z)

    if depth > @min_depth do
      {:ok, {scale * dot(v, cam.x) / depth, -scale * dot(v, cam.y) / depth}, depth}
    else
      :error
    end
  end

  @spec back_to_front([map()]) :: [map()]
  defp back_to_front(items), do: Enum.sort_by(items, & &1.depth, :desc)

  # ── Viewbox ─────────────────────────────────────────────────────────────────

  # Cropped to what actually got drawn, plus a margin, and squared so the frame
  # is predictable regardless of the card's aspect. Squaring never distorts —
  # SVG's default `preserveAspectRatio` letterboxes — it just stops a flat wide
  # scene from being blown up vertically.
  @spec viewbox([Types.poly()], [Types.poly_line()], [Types.poly_label()]) ::
          {float(), float(), float(), float()}
  defp viewbox(polys, lines, labels) do
    points =
      Enum.flat_map(polys, & &1.points) ++
        Enum.flat_map(lines, &[&1.a, &1.b]) ++
        Enum.map(labels, & &1.at)

    case points do
      [] ->
        default_viewbox()

      _ ->
        {min_x, max_x} = points |> Enum.map(&elem(&1, 0)) |> Enum.min_max()
        {min_y, max_y} = points |> Enum.map(&elem(&1, 1)) |> Enum.min_max()

        extent = max(max_x - min_x, max_y - min_y) * (1.0 + 2.0 * @margin)

        if extent < @min_viewbox_extent do
          default_viewbox()
        else
          center_x = (min_x + max_x) / 2.0
          center_y = (min_y + max_y) / 2.0
          {center_x - extent / 2.0, center_y - extent / 2.0, extent, extent}
        end
    end
  end

  @spec default_viewbox() :: {float(), float(), float(), float()}
  defp default_viewbox do
    {-@half_extent, -@half_extent, 2.0 * @half_extent, 2.0 * @half_extent}
  end

  # ── Vector arithmetic ───────────────────────────────────────────────────────

  @spec add(Types.vec3(), Types.vec3()) :: Types.vec3()
  defp add({ax, ay, az}, {bx, by, bz}), do: {ax + bx, ay + by, az + bz}

  @spec sub(Types.vec3(), Types.vec3()) :: Types.vec3()
  defp sub({ax, ay, az}, {bx, by, bz}), do: {ax - bx, ay - by, az - bz}

  @spec mul(Types.vec3(), float()) :: Types.vec3()
  defp mul({x, y, z}, k), do: {x * k, y * k, z * k}

  @spec dot(Types.vec3(), Types.vec3()) :: float()
  defp dot({ax, ay, az}, {bx, by, bz}), do: ax * bx + ay * by + az * bz

  @spec cross(Types.vec3(), Types.vec3()) :: Types.vec3()
  defp cross({ax, ay, az}, {bx, by, bz}) do
    {ay * bz - az * by, az * bx - ax * bz, ax * by - ay * bx}
  end

  # Named `norm/1` rather than `length/1` so it does not collide with the
  # auto-imported `Kernel.length/1`.
  @spec norm(Types.vec3()) :: float()
  defp norm({x, y, z}), do: :math.sqrt(x * x + y * y + z * z)

  @spec normalize(Types.vec3()) :: Types.vec3()
  defp normalize(v) do
    len = norm(v)

    # A zero-length vector has no direction. Returning the zero vector makes a
    # face with a degenerate normal cull (dot is 0, so it is never "facing") and
    # shade to ambient, rather than raising on the divide.
    if len > 0.0, do: mul(v, 1.0 / len), else: {0.0, 0.0, 0.0}
  end

  @spec centroid([Types.vec3()]) :: Types.vec3()
  defp centroid([]), do: {0.0, 0.0, 0.0}

  defp centroid(points) do
    points |> Enum.reduce(&add/2) |> mul(1.0 / length(points))
  end

  @spec mean([float()]) :: float()
  defp mean([]), do: 0.0
  defp mean(values), do: Enum.sum(values) / length(values)

  @spec radians(float()) :: float()
  defp radians(degrees), do: degrees * :math.pi() / 180.0

  @spec clamp(float(), float(), float()) :: float()
  defp clamp(value, lo, hi), do: value |> max(lo) |> min(hi)
end
