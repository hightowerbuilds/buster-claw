defmodule BusterClaw.Scene3d.GeometryTest do
  use ExUnit.Case, async: true

  alias BusterClaw.Scene3d.Geometry

  @eps 1.0e-9

  # ── Helpers ─────────────────────────────────────────────────────────────────

  defp prim(kind, extra \\ %{}) do
    Map.merge(
      %{kind: kind, at: {0.0, 0.0, 0.0}, rotate: {0.0, 0.0, 0.0}, color: 0, label: nil},
      extra
    )
  end

  defp scene(nodes) do
    %{camera: %{azimuth: 30.0, elevation: 20.0}, nodes: List.wrap(nodes)}
  end

  defp build(nodes), do: nodes |> scene() |> Geometry.build()

  defp sub({ax, ay, az}, {bx, by, bz}), do: {ax - bx, ay - by, az - bz}
  defp dot({ax, ay, az}, {bx, by, bz}), do: ax * bx + ay * by + az * bz
  defp magnitude({x, y, z}), do: :math.sqrt(x * x + y * y + z * z)

  defp centroid(points) do
    {sx, sy, sz} =
      Enum.reduce(points, {0.0, 0.0, 0.0}, fn {x, y, z}, {ax, ay, az} ->
        {ax + x, ay + y, az + z}
      end)

    n = length(points)
    {sx / n, sy / n, sz / n}
  end

  defp assert_close(a, b, tol \\ @eps) do
    assert magnitude(sub(a, b)) < tol,
           "expected #{inspect(a)} to be within #{tol} of #{inspect(b)}"
  end

  # The one property that catches the entire winding bug class.
  #
  # For any convex solid, the mean of its face centroids is a point strictly
  # inside it. From a strictly interior point C, every outward-facing plane
  # satisfies (p - C) . n > 0 for any p on that face. So if a single face is
  # wound backwards its normal flips and the dot goes negative — no matter which
  # face it is, which primitive it came from, or how the node was rotated.
  defp assert_outward!(faces) do
    refute faces == [], "expected faces to assert on"

    centroids = Enum.map(faces, &centroid(&1.verts))
    center = centroid(centroids)

    for {face, c} <- Enum.zip(faces, centroids) do
      d = dot(sub(c, center), face.normal)

      assert d > @eps,
             "face at #{inspect(c)} has inward normal #{inspect(face.normal)} (dot #{d}); " <>
               "verts #{inspect(face.verts)}"
    end
  end

  # Normals must also be unit length — Project shades with them directly.
  defp assert_unit_normals!(faces) do
    for face <- faces do
      assert abs(magnitude(face.normal) - 1.0) < @eps,
             "normal #{inspect(face.normal)} is not unit length"
    end
  end

  # ── Winding: one property test per primitive ────────────────────────────────

  describe "outward winding" do
    test "box faces all point away from the box's centre" do
      mesh = build(prim(:box, %{size: {2.0, 3.0, 4.0}}))

      assert_outward!(mesh.faces)
      assert_unit_normals!(mesh.faces)
    end

    test "sphere faces all point away from the sphere's centre" do
      mesh = build(prim(:sphere, %{r: 1.5}))

      assert_outward!(mesh.faces)
      assert_unit_normals!(mesh.faces)
    end

    test "cylinder faces, walls and both caps, point away from its centre" do
      mesh = build(prim(:cylinder, %{r: 0.75, h: 3.0}))

      assert_outward!(mesh.faces)
      assert_unit_normals!(mesh.faces)

      # Pin the caps specifically: the wall property would still hold if a cap
      # were flipped and happened to sit near the centroid.
      normals = Enum.map(mesh.faces, & &1.normal)
      assert Enum.any?(normals, &(elem(&1, 1) > 0.999)), "no +Y cap"
      assert Enum.any?(normals, &(elem(&1, 1) < -0.999)), "no -Y cap"
    end

    test "plane emits two coplanar quads wound against each other" do
      mesh = build(prim(:plane, %{size: {4.0, 0.0, 6.0}}))

      assert [up, down] = mesh.faces
      assert length(up.verts) == 4
      assert length(down.verts) == 4
      assert_close(up.normal, {0.0, 1.0, 0.0})
      assert_close(down.normal, {0.0, -1.0, 0.0})

      # Coplanar: same quad, opposite traversal. Anything else would z-fight.
      assert Enum.sort(up.verts) == Enum.sort(down.verts)
      assert_close(centroid(up.verts), centroid(down.verts))
    end

    test "a plane is visible from above AND below, which is why it is two faces" do
      # This is Project's cull predicate verbatim. A model that writes a negative
      # elevation is looking up at the scene, and `elevation` validates down to
      # -89 — so a single-sided ground plane silently disappears in ordinary use,
      # not in some edge case.
      mesh = build(prim(:plane, %{size: {10.0, 0.0, 10.0}, at: {0.0, -2.0, 0.0}}))

      visible = fn eye ->
        Enum.filter(mesh.faces, fn f -> dot(f.normal, sub(eye, centroid(f.verts))) > 0.0 end)
      end

      for eye <- [{0.0, 50.0, 0.0}, {30.0, 20.0, 30.0}, {0.0, -50.0, 0.0}, {30.0, -20.0, 30.0}] do
        assert length(visible.(eye)) == 1,
               "expected exactly one plane face to survive culling from eye #{inspect(eye)}"
      end
    end

    test "capsule faces, body and both hemispheres, point away from its centre" do
      mesh = build(prim(:capsule, %{r: 0.5, h: 2.0}))

      assert_outward!(mesh.faces)
      assert_unit_normals!(mesh.faces)

      # h is the straight section, so the extremes sit at +/- (h/2 + r).
      ys = mesh.faces |> Enum.flat_map(& &1.verts) |> Enum.map(&elem(&1, 1))
      assert_in_delta Enum.max(ys), 1.5, @eps
      assert_in_delta Enum.min(ys), -1.5, @eps
    end

    test "arrow head cone faces point away from the cone's centre" do
      mesh = build(prim(:arrow, %{from: {0.0, 0.0, 0.0}, to: {4.0, 0.0, 0.0}}))

      assert_outward!(mesh.faces)
      assert_unit_normals!(mesh.faces)
    end

    test "winding survives rotation" do
      # Rotation is orientation-preserving, so an outward normal must stay
      # outward. If it ever does not, the rotation matrices are left-handed.
      for kind_and_fields <- [
            {:box, %{size: {2.0, 1.0, 3.0}}},
            {:sphere, %{r: 1.0}},
            {:cylinder, %{r: 0.6, h: 2.0}},
            {:capsule, %{r: 0.4, h: 1.2}}
          ] do
        {kind, fields} = kind_and_fields
        fields = Map.merge(fields, %{rotate: {35.0, -110.0, 62.0}, at: {5.0, -2.0, 8.0}})

        kind |> prim(fields) |> build() |> Map.fetch!(:faces) |> assert_outward!()
      end
    end
  end

  # ── Shape and counts ────────────────────────────────────────────────────────

  describe "box" do
    test "is exactly 6 faces of 4 vertices" do
      mesh = build(prim(:box, %{size: {2.0, 2.0, 2.0}}))

      assert length(mesh.faces) == 6
      assert Enum.all?(mesh.faces, &(length(&1.verts) == 4))
      assert mesh.lines == []
    end

    test "size is honoured on each axis" do
      mesh = build(prim(:box, %{size: {2.0, 4.0, 6.0}}))
      verts = Enum.flat_map(mesh.faces, & &1.verts)

      assert Enum.max(Enum.map(verts, &elem(&1, 0))) == 1.0
      assert Enum.max(Enum.map(verts, &elem(&1, 1))) == 2.0
      assert Enum.max(Enum.map(verts, &elem(&1, 2))) == 3.0
    end

    test "at translates every vertex" do
      mesh = build(prim(:box, %{size: {2.0, 2.0, 2.0}, at: {10.0, -5.0, 3.0}}))

      assert_close(centroid(Enum.flat_map(mesh.faces, & &1.verts)), {10.0, -5.0, 3.0})
    end
  end

  describe "sphere" do
    test "is 16 segments by 8 rings, poles triangulated" do
      mesh = build(prim(:sphere, %{r: 1.0}))

      # 8 bands x 16 segments; the two polar bands are triangles.
      assert length(mesh.faces) == 8 * 16
      assert Enum.count(mesh.faces, &(length(&1.verts) == 3)) == 2 * 16
      assert Enum.count(mesh.faces, &(length(&1.verts) == 4)) == 6 * 16
    end

    test "every vertex sits on the radius" do
      mesh = build(prim(:sphere, %{r: 2.5}))

      for v <- Enum.flat_map(mesh.faces, & &1.verts) do
        assert_in_delta magnitude(v), 2.5, @eps
      end
    end
  end

  describe "cylinder" do
    test "is a 16-segment wall plus two caps" do
      mesh = build(prim(:cylinder, %{r: 1.0, h: 2.0}))

      assert length(mesh.faces) == 16 + 2
      caps = Enum.filter(mesh.faces, &(length(&1.verts) == 16))
      assert length(caps) == 2
    end
  end

  # ── Rotation: handedness and order, pinned explicitly ───────────────────────

  describe "rotation" do
    test "360 degrees about every axis is the identity" do
      fields = %{size: {2.0, 1.0, 3.0}}
      plain = build(prim(:box, fields))
      spun = build(prim(:box, Map.put(fields, :rotate, {360.0, 360.0, 360.0})))

      for {a, b} <- Enum.zip(plain.faces, spun.faces) do
        assert_close(a.normal, b.normal)

        for {p, q} <- Enum.zip(a.verts, b.verts), do: assert_close(p, q)
      end
    end

    test "+90 degrees about Y maps +X to -Z (right-handed, Y up)" do
      # A polyline is the cleanest probe: one segment, no tessellation between
      # the input vector and the output vector.
      mesh =
        build(
          prim(:polyline, %{points: [{0.0, 0.0, 0.0}, {1.0, 0.0, 0.0}], rotate: {0.0, 90.0, 0.0}})
        )

      assert [%{a: a, b: b}] = mesh.lines
      assert_close(a, {0.0, 0.0, 0.0})
      assert_close(b, {0.0, 0.0, -1.0})
    end

    test "+90 degrees about Y carries a box's +X face round to -Z" do
      # Same claim, but through the tessellator and its normals. The box is long
      # in X so only the +/-X faces sit at distance 2 from the origin.
      mesh = build(prim(:box, %{size: {4.0, 1.0, 1.0}, rotate: {0.0, 90.0, 0.0}}))

      moved =
        Enum.find(mesh.faces, fn f -> magnitude(centroid(f.verts)) > 1.9 end)

      assert moved, "expected a face at the long axis"
      assert_close(centroid(moved.verts), {0.0, 0.0, -2.0})
      assert_close(moved.normal, {0.0, 0.0, -1.0})
    end

    test "+90 degrees about Z maps +X to +Y and about X maps +Y to +Z" do
      probe = fn rotate ->
        mesh =
          build(prim(:polyline, %{points: [{0.0, 0.0, 0.0}, {1.0, 0.0, 0.0}], rotate: rotate}))

        [%{b: b}] = mesh.lines
        b
      end

      assert_close(probe.({0.0, 0.0, 90.0}), {0.0, 1.0, 0.0})

      mesh =
        build(
          prim(:polyline, %{points: [{0.0, 0.0, 0.0}, {0.0, 1.0, 0.0}], rotate: {90.0, 0.0, 0.0}})
        )

      assert [%{b: b}] = mesh.lines
      assert_close(b, {0.0, 0.0, 1.0})
    end

    test "euler order is X then Y then Z about the fixed world axes" do
      # (0,1,0) under Rz(0).Ry(90).Rx(90) is (1,0,0).
      # Under the reverse order Rx(90).Ry(90).Rz(0) it would be (0,0,1), so this
      # assertion fails loudly if the composition order is ever flipped.
      mesh =
        build(
          prim(:polyline, %{points: [{0.0, 0.0, 0.0}, {0.0, 1.0, 0.0}], rotate: {90.0, 90.0, 0.0}})
        )

      assert [%{b: b}] = mesh.lines
      assert_close(b, {1.0, 0.0, 0.0})
    end

    test "rotation happens before translation" do
      mesh =
        build(
          prim(:polyline, %{
            points: [{0.0, 0.0, 0.0}, {1.0, 0.0, 0.0}],
            rotate: {0.0, 90.0, 0.0},
            at: {10.0, 0.0, 0.0}
          })
        )

      assert [%{a: a, b: b}] = mesh.lines
      assert_close(a, {10.0, 0.0, 0.0})
      # Rotate-then-translate puts the tip at (10, 0, -1). Translate-then-rotate
      # would swing the whole segment round to (0, 0, -10).
      assert_close(b, {10.0, 0.0, -1.0})
    end
  end

  # ── Lines ───────────────────────────────────────────────────────────────────

  describe "polyline" do
    test "N points yield N-1 lines and no faces" do
      for n <- 2..6 do
        points = for i <- 1..n, do: {i * 1.0, 0.0, 0.0}
        mesh = build(prim(:polyline, %{points: points}))

        assert length(mesh.lines) == n - 1
        assert mesh.faces == []
      end
    end

    test "lines join consecutive points in order" do
      points = [{0.0, 0.0, 0.0}, {1.0, 0.0, 0.0}, {1.0, 2.0, 0.0}]
      mesh = build(prim(:polyline, %{points: points}))

      assert [%{a: a1, b: b1}, %{a: a2, b: b2}] = mesh.lines
      assert_close(a1, {0.0, 0.0, 0.0})
      assert_close(b1, {1.0, 0.0, 0.0})
      assert_close(a2, {1.0, 0.0, 0.0})
      assert_close(b2, {1.0, 2.0, 0.0})
    end

    test "a single point yields nothing to draw" do
      mesh = build(prim(:polyline, %{points: [{0.0, 0.0, 0.0}]}))

      assert mesh.lines == []
      assert mesh.faces == []
    end

    test "carries the node colour and a positive stroke width" do
      mesh = build(prim(:polyline, %{points: [{0.0, 0.0, 0.0}, {1.0, 1.0, 1.0}], color: 3}))

      assert [%{color: 3, width: width}] = mesh.lines
      assert width > 0.0
    end
  end

  describe "arrow" do
    test "is one shaft line from `from` to `to` plus a head of faces" do
      mesh = build(prim(:arrow, %{from: {0.0, 0.0, 0.0}, to: {0.0, 3.0, 0.0}, color: 2}))

      assert [%{a: a, b: b, color: 2}] = mesh.lines
      assert_close(a, {0.0, 0.0, 0.0})
      assert_close(b, {0.0, 3.0, 0.0})

      refute mesh.faces == []
      assert Enum.all?(mesh.faces, &(&1.color == 2))
    end

    test "the head sits at the `to` end, not the `from` end" do
      mesh = build(prim(:arrow, %{from: {0.0, 0.0, 0.0}, to: {0.0, 10.0, 0.0}}))

      ys = mesh.faces |> Enum.flat_map(& &1.verts) |> Enum.map(&elem(&1, 1))
      assert Enum.max(ys) == 10.0
      assert Enum.min(ys) > 5.0
    end

    test "a zero-length arrow degrades to a bare line rather than crashing" do
      mesh = build(prim(:arrow, %{from: {1.0, 1.0, 1.0}, to: {1.0, 1.0, 1.0}}))

      assert length(mesh.lines) == 1
      assert mesh.faces == []
    end
  end

  # ── Labels ──────────────────────────────────────────────────────────────────

  describe "labels" do
    test "come through with their text intact, anchored at the node centre" do
      mesh = build(prim(:box, %{size: {1.0, 1.0, 1.0}, at: {2.0, 3.0, 4.0}, label: "web server"}))

      assert [%{at: at, text: "web server"}] = mesh.labels
      assert_close(at, {2.0, 3.0, 4.0})
    end

    test "text is passed through verbatim; escaping belongs to the renderer" do
      # Geometry must not silently mangle the string — Svg is the stage that
      # escapes it, and a half-escape here would hide a hole there.
      text = ~S|<script>alert("x")</script> & <>|
      mesh = build(prim(:sphere, %{r: 1.0, label: text}))

      assert [%{text: ^text}] = mesh.labels
    end

    test "a nil or empty label emits nothing" do
      assert build(prim(:box, %{label: nil})).labels == []
      assert build(prim(:box, %{label: ""})).labels == []
    end

    test "a polyline label anchors at the midpoint of its points" do
      mesh =
        build(prim(:polyline, %{points: [{0.0, 0.0, 0.0}, {4.0, 0.0, 0.0}], label: "link"}))

      assert [%{at: at, text: "link"}] = mesh.labels
      assert_close(at, {2.0, 0.0, 0.0})
    end

    test "an arrow label anchors between from and to" do
      mesh = build(prim(:arrow, %{from: {0.0, 0.0, 0.0}, to: {0.0, 0.0, 6.0}, label: "flow"}))

      assert [%{at: at}] = mesh.labels
      assert_close(at, {0.0, 0.0, 3.0})
    end

    test "one label per node, in node order" do
      mesh =
        build([
          prim(:box, %{label: "a"}),
          prim(:sphere, %{r: 1.0, label: nil}),
          prim(:cylinder, %{r: 1.0, h: 1.0, label: "c"})
        ])

      assert Enum.map(mesh.labels, & &1.text) == ["a", "c"]
    end
  end

  # ── Scene-level behaviour ───────────────────────────────────────────────────

  describe "build/1" do
    test "an empty scene is an empty mesh" do
      assert Geometry.build(scene([])) == %{faces: [], lines: [], labels: []}
    end

    test "accumulates every node" do
      mesh = build([prim(:box), prim(:box), prim(:plane, %{size: {1.0, 0.0, 1.0}})])

      assert length(mesh.faces) == 6 + 6 + 2
    end

    test "palette indices pass through unchanged" do
      for c <- 0..4 do
        mesh = build(prim(:box, %{color: c}))
        assert Enum.all?(mesh.faces, &(&1.color == c))
      end
    end

    test "composition helpers should be gone by now, and contribute nothing" do
      # expand/1 removes these upstream. If one survives, dropping it beats
      # crashing the whole card.
      mesh = build([prim(:grid, %{count: {2, 2, 2}}), prim(:stack), prim(:ring)])

      assert mesh == %{faces: [], lines: [], labels: []}
    end

    test "a degenerate zero-size solid emits no zero-area faces" do
      mesh = build(prim(:box, %{size: {0.0, 0.0, 0.0}}))

      assert mesh.faces == []
    end

    test "scene scale is not assumed anywhere" do
      for r <- [0.001, 1.0, 1000.0] do
        mesh = build(prim(:sphere, %{r: r}))

        assert length(mesh.faces) == 8 * 16
        assert_outward!(mesh.faces)
      end
    end
  end
end
