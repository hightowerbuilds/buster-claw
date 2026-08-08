defmodule BusterClaw.Scene3d.GeometryTest do
  use ExUnit.Case, async: true

  alias BusterClaw.Scene3d.Geometry

  @eps 1.0e-9

  # A 2x2 ground square, written clockwise-seen-from-above on purpose: the model
  # has no reason to prefer a winding and neither should this file.
  @square [{0.0, 0.0}, {2.0, 0.0}, {2.0, 2.0}, {0.0, 2.0}]

  # ── Helpers ─────────────────────────────────────────────────────────────────

  defp prim(kind, extra \\ %{}) do
    Map.merge(
      %{
        kind: kind,
        at: {0.0, 0.0, 0.0},
        rotate: {0.0, 0.0, 0.0},
        color: 0,
        role: :solid,
        label: nil
      },
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

  # A C opening toward +x. The bite out of it — 1 < x < 3, 1 < z < 2 — is
  # emphatically not part of the polygon, and a fan from vertex zero covers it.
  # That is the whole point of this shape.
  defp c_shape do
    [
      {0.0, 0.0},
      {3.0, 0.0},
      {3.0, 1.0},
      {1.0, 1.0},
      {1.0, 2.0},
      {3.0, 2.0},
      {3.0, 3.0},
      {0.0, 3.0}
    ]
  end

  # Ray casting on the ground plane. This is the instrument that proves ear
  # clipping actually clips ears: a fan triangulation of a concave outline
  # necessarily puts at least one face centroid outside, and nothing else in this
  # file would notice.
  defp inside_outline?({px, pz}, outline) do
    outline
    |> Enum.zip(tl(outline) ++ [hd(outline)])
    |> Enum.reduce(false, fn {{xi, zi}, {xj, zj}}, inside ->
      crosses? = zi > pz != zj > pz

      if crosses? and px < (xj - xi) * (pz - zi) / (zj - zi) + xi do
        not inside
      else
        inside
      end
    end)
  end

  # Unsigned area of a polygon projected onto the ground plane.
  defp ground_area(verts) do
    verts
    |> Enum.zip(tl(verts) ++ [hd(verts)])
    |> Enum.reduce(0.0, fn {{xi, _, zi}, {xj, _, zj}}, sum -> sum + (xi * zj - xj * zi) end)
    |> abs()
    |> Kernel./(2.0)
  end

  # "It terminates" is only an assertion if the test can fail instead of hang.
  defp within(fun, timeout \\ 5_000) do
    fun |> Task.async() |> Task.await(timeout)
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
            {:capsule, %{r: 0.4, h: 1.2}},
            {:region, %{outline: @square, height: 2.0}}
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

  # ── Role: the backdrop marker, which every face must carry ──────────────────

  describe "role" do
    test "reaches every face of every primitive that makes one" do
      shapes = [
        {:box, %{size: {2.0, 2.0, 2.0}}},
        {:sphere, %{r: 1.0}},
        {:cylinder, %{r: 1.0, h: 2.0}},
        {:plane, %{size: {2.0, 0.0, 2.0}}},
        {:capsule, %{r: 0.5, h: 1.0}},
        {:arrow, %{from: {0.0, 0.0, 0.0}, to: {0.0, 2.0, 0.0}}},
        {:region, %{outline: c_shape()}},
        {:region, %{outline: c_shape(), height: 1.5}}
      ]

      for role <- [:solid, :surface], {kind, fields} <- shapes do
        mesh = build(prim(kind, Map.put(fields, :role, role)))

        refute mesh.faces == [], "#{kind} produced no faces to check the role on"

        assert Enum.all?(mesh.faces, &(&1.role == role)),
               "#{kind} dropped its #{role} role on at least one face"
      end
    end

    test "is per node, not per scene" do
      mesh =
        build([
          prim(:plane, %{size: {10.0, 0.0, 10.0}, role: :surface}),
          prim(:box, %{size: {1.0, 1.0, 1.0}, role: :solid})
        ])

      assert Enum.count(mesh.faces, &(&1.role == :surface)) == 2
      assert Enum.count(mesh.faces, &(&1.role == :solid)) == 6
    end

    test "defaults to :solid when a node somehow arrives without one" do
      # :solid is the loud default on purpose. A backdrop drawn as a subject is a
      # visible mistake someone fixes; a subject drawn as a backdrop is greyed
      # out AND dropped from the auto-fit, which reads as a rendering bug.
      node = :box |> prim(%{size: {1.0, 1.0, 1.0}}) |> Map.delete(:role)

      assert Enum.all?(build(node).faces, &(&1.role == :solid))
    end
  end

  # ── Region: filled ground polygons, flat and extruded ───────────────────────

  describe "region: flat" do
    test "is double-sided, like a plane and for the same reason" do
      # Project's cull predicate again. A map's water is looked at from below the
      # moment the model writes a negative elevation, and elevation validates to
      # -89 — so a one-sided landmass is a hole in ordinary use.
      mesh = build(prim(:region, %{outline: c_shape(), at: {0.0, -1.0, 0.0}}))

      refute mesh.faces == []
      assert rem(length(mesh.faces), 2) == 0
      half = div(length(mesh.faces), 2)

      for eye <- [{0.0, 50.0, 0.0}, {30.0, 20.0, 30.0}, {0.0, -50.0, 0.0}, {30.0, -20.0, 30.0}] do
        visible =
          Enum.filter(mesh.faces, fn f -> dot(f.normal, sub(eye, centroid(f.verts))) > 0.0 end)

        assert length(visible) == half,
               "expected half the region's faces to survive culling from #{inspect(eye)}"

        # And exactly one of each coplanar pair, not both of some and none of
        # others — which is what a per-triangle winding slip would look like.
        assert length(Enum.uniq_by(visible, &Enum.sort(&1.verts))) == half
      end
    end

    test "lies flat, at the node's own height" do
      mesh = build(prim(:region, %{outline: c_shape(), at: {0.0, 4.0, 0.0}}))
      ys = mesh.faces |> Enum.flat_map(& &1.verts) |> Enum.map(&elem(&1, 1))

      assert Enum.uniq(ys) == [4.0]
    end

    test "a concave outline yields no face outside it — this is why it is not a fan" do
      # THE assertion for ear clipping. Fanning the C from vertex zero emits
      # (0,0)-(1,2)-(3,2), whose centroid sits in the bite at (1.33, 1.33): water
      # painted as land. Every triangulation that is actually a triangulation
      # passes this; a fan cannot.
      outline = c_shape()
      mesh = build(prim(:region, %{outline: outline}))

      refute mesh.faces == []

      for face <- mesh.faces do
        {x, _y, z} = centroid(face.verts)

        assert inside_outline?({x, z}, outline),
               "face centroid #{inspect({x, z})} lies outside the outline; " <>
                 "verts #{inspect(face.verts)}"
      end
    end

    test "the triangles tile the outline exactly, with no gaps and no overlap" do
      # The containment test above catches faces that escape the outline; this
      # one catches the opposite failures — a triangle dropped, or two of them
      # covering the same ground.
      mesh = build(prim(:region, %{outline: c_shape()}))

      covered =
        mesh.faces
        |> Enum.filter(&(elem(&1.normal, 1) > 0.0))
        |> Enum.map(&ground_area(&1.verts))
        |> Enum.sum()

      # The C is a 3x3 square with a 2x1 bite taken out of it.
      assert_in_delta covered, 7.0, @eps
    end

    test "is n-2 triangles per side, and every one of them is a triangle" do
      mesh = build(prim(:region, %{outline: c_shape()}))

      assert length(mesh.faces) == 2 * (8 - 2)
      assert Enum.all?(mesh.faces, &(length(&1.verts) == 3))
      assert mesh.lines == []
    end
  end

  describe "region: extruded" do
    test "a convex outline extrudes into a closed prism with outward normals" do
      mesh = build(prim(:region, %{outline: @square, height: 2.0}))

      assert_outward!(mesh.faces)
      assert_unit_normals!(mesh.faces)
    end

    test "caps sit at 0 and at height, one facing up and one facing down" do
      mesh = build(prim(:region, %{outline: @square, height: 3.0}))

      ys = mesh.faces |> Enum.flat_map(& &1.verts) |> Enum.map(&elem(&1, 1))
      assert Enum.min(ys) == 0.0
      assert Enum.max(ys) == 3.0

      normals = Enum.map(mesh.faces, & &1.normal)
      assert Enum.count(normals, &(elem(&1, 1) > 0.999)) == 2, "expected a 2-triangle top cap"
      assert Enum.count(normals, &(elem(&1, 1) < -0.999)) == 2, "expected a 2-triangle bottom cap"
    end

    test "is one wall quad per outline edge, and nothing is double-sided" do
      mesh = build(prim(:region, %{outline: @square, height: 1.0}))

      walls = Enum.filter(mesh.faces, &(length(&1.verts) == 4))
      assert length(walls) == 4
      # 4 walls + 2 top + 2 bottom. A prism has an outside, so unlike the flat
      # case there is nothing here to double.
      assert length(mesh.faces) == 8
    end

    test "every wall normal points out of the outline, reflex corners included" do
      # assert_outward!/1 assumes a convex solid, so the C-shape gets the direct
      # form of the same claim: step off a wall along its normal and you must
      # leave the polygon; step the other way and you must stay in it. At a
      # reflex corner those two swap if the ring winding was not normalised.
      outline = c_shape()
      mesh = build(prim(:region, %{outline: outline, height: 1.0}))
      walls = Enum.filter(mesh.faces, &(length(&1.verts) == 4))

      assert length(walls) == length(outline)

      for wall <- walls do
        {cx, _cy, cz} = centroid(wall.verts)
        {nx, ny, nz} = wall.normal
        step = 1.0e-4

        assert abs(ny) < @eps, "a wall should be vertical, got #{inspect(wall.normal)}"

        refute inside_outline?({cx + nx * step, cz + nz * step}, outline),
               "wall at #{inspect({cx, cz})} has its normal pointing into the region"

        assert inside_outline?({cx - nx * step, cz - nz * step}, outline)
      end
    end

    test "cap triangles stay inside a concave outline" do
      outline = c_shape()
      mesh = build(prim(:region, %{outline: outline, height: 1.0}))
      caps = Enum.filter(mesh.faces, &(length(&1.verts) == 3))

      assert length(caps) == 2 * (8 - 2)

      for face <- caps do
        {x, _y, z} = centroid(face.verts)
        assert inside_outline?({x, z}, outline)
      end
    end

    test "a zero height is flat, not a prism of no thickness" do
      flat = build(prim(:region, %{outline: @square}))
      zero = build(prim(:region, %{outline: @square, height: 0.0}))

      assert flat == zero
    end
  end

  describe "region: outline winding" do
    test "clockwise and counter-clockwise outlines produce identical geometry" do
      # The model will not be consistent about this and should not have to be.
      outline = c_shape()

      assert build(prim(:region, %{outline: outline})) ==
               build(prim(:region, %{outline: Enum.reverse(outline)}))
    end

    test "the top cap faces up whichever way the outline was written" do
      for outline <- [@square, Enum.reverse(@square)] do
        mesh = build(prim(:region, %{outline: outline, height: 2.0}))

        assert_outward!(mesh.faces)

        tops = Enum.filter(mesh.faces, &(elem(centroid(&1.verts), 1) > 1.999))
        refute tops == []

        for top <- tops, do: assert_close(top.normal, {0.0, 1.0, 0.0})
      end
    end

    test "a closing repeat of the first point is not a zero-length edge" do
      assert build(prim(:region, %{outline: @square, height: 1.0})) ==
               build(prim(:region, %{outline: @square ++ [hd(@square)], height: 1.0}))
    end
  end

  describe "region: malformed outlines" do
    test "a self-intersecting outline terminates and still draws something" do
      # A bowtie has no triangulation at all. The renderer's job here is to not
      # hang and not raise; being slightly wrong about a polygon the model got
      # wrong is a fine trade.
      bowtie = [{0.0, 0.0}, {2.0, 2.0}, {2.0, 0.0}, {0.0, 2.0}]

      mesh = within(fn -> build(prim(:region, %{outline: bowtie, height: 1.0})) end)

      refute mesh.faces == []
      assert_unit_normals!(mesh.faces)
    end

    test "an outline that crosses itself many times also terminates" do
      # The {20/9} star polygon: every edge crosses several others, so the ear
      # search finds nothing and must give up on its own.
      outline =
        for i <- 0..19 do
          t = 2 * :math.pi() * rem(i * 9, 20) / 20
          {2.0 * :math.cos(t), 2.0 * :math.sin(t)}
        end

      mesh = within(fn -> build(prim(:region, %{outline: outline})) end)

      assert is_list(mesh.faces)
      assert_unit_normals!(mesh.faces)
    end

    test "an outline of fewer than three distinct points draws nothing" do
      for outline <- [
            [],
            [{0.0, 0.0}],
            [{0.0, 0.0}, {1.0, 1.0}],
            [{1.0, 1.0}, {1.0, 1.0}, {1.0, 1.0}]
          ] do
        mesh = build(prim(:region, %{outline: outline, height: 2.0}))

        assert mesh.faces == []
        assert mesh.lines == []
      end
    end

    test "junk entries in the outline are skipped, not fatal" do
      outline = [{0.0, 0.0}, "nope", {2.0, 0.0}, nil, {2.0, 2.0}, {0.0, 2.0}]
      mesh = build(prim(:region, %{outline: outline, height: 1.0}))

      assert length(mesh.faces) == 8
    end

    test "an absurdly long outline is truncated rather than paid for" do
      # Ear clipping is roughly cubic in the outline length in the worst case, so
      # the cap is what stops a thousand-point coastline from becoming a wedged
      # renderer. One wall per surviving edge makes the cap directly observable.
      outline =
        for i <- 0..999 do
          t = 2 * :math.pi() * i / 1000
          {:math.cos(t), :math.sin(t)}
        end

      mesh = within(fn -> build(prim(:region, %{outline: outline, height: 1.0})) end)

      assert Enum.count(mesh.faces, &(length(&1.verts) == 4)) == 128
    end
  end

  describe "region labels" do
    test "anchor at the outline centroid, on the ground when flat" do
      mesh =
        build(
          prim(:region, %{
            outline: [{0.0, 0.0}, {4.0, 0.0}, {4.0, 2.0}, {0.0, 2.0}],
            label: "the sound"
          })
        )

      assert [%{at: at, text: "the sound"}] = mesh.labels
      assert_close(at, {2.0, 0.0, 1.0})
    end

    test "ride on top of an extrusion rather than inside it" do
      mesh =
        build(
          prim(:region, %{
            outline: [{0.0, 0.0}, {4.0, 0.0}, {4.0, 2.0}, {0.0, 2.0}],
            height: 5.0,
            label: "island"
          })
        )

      assert [%{at: at}] = mesh.labels
      assert_close(at, {2.0, 5.0, 1.0})
    end

    test "are area-weighted, not a mean of the points" do
      # The same square, but with the bottom edge sampled eleven times over —
      # which is exactly what a traced coastline looks like where the shore
      # wiggles. A vertex mean lands at z = 0.31 and drops the label off the
      # bottom edge; the area-weighted centroid does not move at all.
      dense = for i <- 0..10, do: {i * 0.4, 0.0}
      outline = dense ++ [{4.0, 2.0}, {0.0, 2.0}]

      mesh = build(prim(:region, %{outline: outline, label: "x"}))

      assert [%{at: at}] = mesh.labels
      assert_close(at, {2.0, 0.0, 1.0})
    end

    test "follow the node's placement like any other label" do
      mesh =
        build(
          prim(:region, %{
            outline: @square,
            height: 2.0,
            at: {10.0, 0.0, -4.0},
            label: "here"
          })
        )

      assert [%{at: at}] = mesh.labels
      assert_close(at, {11.0, 2.0, -3.0})
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
