defmodule BusterClaw.Scene3d.ProjectTest do
  use ExUnit.Case, async: true

  alias BusterClaw.Scene3d.Project

  @front %{azimuth: 0.0, elevation: 0.0}

  # ── Fixtures ────────────────────────────────────────────────────────────────

  # An axis-aligned box, wound CCW-from-outside on every face, with the normals
  # `Geometry` is contracted to precompute.
  defp box(center \\ {0.0, 0.0, 0.0}, side \\ 1.0, color \\ 0) do
    {cx, cy, cz} = center
    h = side / 2.0

    corner = fn sx, sy, sz -> {cx + sx * h, cy + sy * h, cz + sz * h} end

    faces = [
      # +Z
      {{0.0, 0.0, 1.0}, [{-1, -1, 1}, {1, -1, 1}, {1, 1, 1}, {-1, 1, 1}]},
      # -Z
      {{0.0, 0.0, -1.0}, [{1, -1, -1}, {-1, -1, -1}, {-1, 1, -1}, {1, 1, -1}]},
      # +X
      {{1.0, 0.0, 0.0}, [{1, -1, 1}, {1, -1, -1}, {1, 1, -1}, {1, 1, 1}]},
      # -X
      {{-1.0, 0.0, 0.0}, [{-1, -1, -1}, {-1, -1, 1}, {-1, 1, 1}, {-1, 1, -1}]},
      # +Y
      {{0.0, 1.0, 0.0}, [{-1, 1, 1}, {1, 1, 1}, {1, 1, -1}, {-1, 1, -1}]},
      # -Y
      {{0.0, -1.0, 0.0}, [{-1, -1, -1}, {1, -1, -1}, {1, -1, 1}, {-1, -1, 1}]}
    ]

    verts =
      Enum.map(faces, fn {normal, signs} ->
        %{
          verts: Enum.map(signs, fn {sx, sy, sz} -> corner.(sx * 1.0, sy * 1.0, sz * 1.0) end),
          normal: normal,
          color: color
        }
      end)

    %{faces: verts, lines: [], labels: []}
  end

  defp empty_mesh, do: %{faces: [], lines: [], labels: []}

  # Scales world positions only. Normals are unit directions and must NOT be
  # scaled — that is the whole premise of the scale-invariance property.
  defp scale_mesh(mesh, k) do
    p = fn {x, y, z} -> {x * k, y * k, z * k} end

    %{
      faces: Enum.map(mesh.faces, &%{&1 | verts: Enum.map(&1.verts, p)}),
      lines: Enum.map(mesh.lines, &%{&1 | a: p.(&1.a), b: p.(&1.b)}),
      labels: Enum.map(mesh.labels, &%{&1 | at: p.(&1.at)})
    }
  end

  defp frame_numbers(frame) do
    {min_x, min_y, w, h} = frame.viewbox

    Enum.flat_map(frame.polys, fn poly ->
      [poly.shade, poly.depth] ++ Enum.flat_map(poly.points, fn {x, y} -> [x, y] end)
    end) ++
      Enum.flat_map(frame.lines, fn line ->
        {ax, ay} = line.a
        {bx, by} = line.b
        [line.depth, ax, ay, bx, by]
      end) ++
      Enum.flat_map(frame.labels, fn label ->
        {x, y} = label.at
        [label.depth, x, y]
      end) ++
      [min_x, min_y, w, h]
  end

  # NaN fails every comparison, and an infinity blows the bound, so this catches
  # both. (Erlang mostly raises rather than producing either, which is also a
  # failure this assertion's surrounding call would surface.)
  defp assert_all_finite(frame) do
    for n <- frame_numbers(frame) do
      assert is_float(n), "expected a float, got #{inspect(n)}"
      assert abs(n) < 1.0e12, "non-finite value in frame: #{inspect(n)}"
    end
  end

  # ── The headline property: framing is scale-free ────────────────────────────

  describe "auto-fit scale invariance (roadmap decision 3)" do
    test "a scene scaled 1000x projects to identical 2D points and viewbox" do
      base = box({2.0, -1.0, 0.5}, 3.0, 2)

      mesh = %{
        base
        | lines: [%{a: {0.0, 0.0, 0.0}, b: {4.0, 2.0, -1.0}, color: 1, width: 1.5}],
          labels: [%{at: {2.0, 3.0, 0.0}, text: "hub"}]
      }

      camera = %{azimuth: 37.0, elevation: 21.0}

      small = Project.run(mesh, camera)
      large = Project.run(scale_mesh(mesh, 1000.0), camera)

      assert length(small.polys) == length(large.polys)
      assert length(small.lines) == length(large.lines)
      assert length(small.labels) == length(large.labels)
      assert small.polys != []

      for {a, b} <- Enum.zip(small.polys, large.polys) do
        assert a.color == b.color
        assert_in_delta a.shade, b.shade, 1.0e-9

        for {{ax, ay}, {bx, by}} <- Enum.zip(a.points, b.points) do
          assert_in_delta ax, bx, 1.0e-6
          assert_in_delta ay, by, 1.0e-6
        end
      end

      for {a, b} <- Enum.zip(small.lines, large.lines) do
        {ax, ay} = a.a
        {bx, by} = b.a
        assert_in_delta ax, bx, 1.0e-6
        assert_in_delta ay, by, 1.0e-6
      end

      for {a, b} <- Enum.zip(small.labels, large.labels) do
        {ax, ay} = a.at
        {bx, by} = b.at
        assert_in_delta ax, bx, 1.0e-6
        assert_in_delta ay, by, 1.0e-6
      end

      {sx, sy, sw, sh} = small.viewbox
      {lx, ly, lw, lh} = large.viewbox
      assert_in_delta sx, lx, 1.0e-6
      assert_in_delta sy, ly, 1.0e-6
      assert_in_delta sw, lw, 1.0e-6
      assert_in_delta sh, lh, 1.0e-6
    end

    test "a scene scaled down 100x also projects identically" do
      mesh = box({0.0, 0.0, 0.0}, 1.0, 0)
      camera = %{azimuth: -64.0, elevation: -12.0}

      a = Project.run(mesh, camera)
      b = Project.run(scale_mesh(mesh, 0.01), camera)

      for {pa, pb} <- Enum.zip(a.polys, b.polys),
          {{ax, ay}, {bx, by}} <- Enum.zip(pa.points, pb.points) do
        assert_in_delta ax, bx, 1.0e-6
        assert_in_delta ay, by, 1.0e-6
      end
    end

    test "depth scales with the scene but the ordering does not" do
      mesh = box({0.0, 0.0, 0.0}, 1.0, 0)
      camera = %{azimuth: 30.0, elevation: 20.0}

      small = Project.run(mesh, camera)
      large = Project.run(scale_mesh(mesh, 1000.0), camera)

      # `depth` is raw view-space depth in scene units, per the contract, so it
      # is the one quantity that is deliberately not scale-invariant.
      for {a, b} <- Enum.zip(small.polys, large.polys) do
        assert_in_delta b.depth / a.depth, 1000.0, 1.0e-6
      end
    end
  end

  # ── Backface culling ────────────────────────────────────────────────────────

  describe "backface culling" do
    test "a face pointing at the camera survives and one pointing away is dropped" do
      quad = fn z, normal, color ->
        %{
          verts: [{-1.0, -1.0, z}, {1.0, -1.0, z}, {1.0, 1.0, z}, {-1.0, 1.0, z}],
          normal: normal,
          color: color
        }
      end

      mesh = %{
        faces: [
          quad.(1.0, {0.0, 0.0, 1.0}, 0),
          quad.(-1.0, {0.0, 0.0, -1.0}, 1)
        ],
        lines: [],
        labels: []
      }

      frame = Project.run(mesh, @front)

      assert [%{color: 0}] = frame.polys
    end

    test "a box viewed head-on shows exactly one of its six faces" do
      frame = Project.run(box(), @front)

      assert length(frame.polys) == 1
    end

    test "a box viewed from a corner shows exactly three faces" do
      frame = Project.run(box(), %{azimuth: 45.0, elevation: 35.0})

      assert length(frame.polys) == 3
    end

    test "a single face wound backwards vanishes silently" do
      quad = fn normal ->
        %{
          faces: [
            %{
              verts: [{-1.0, -1.0, 0.0}, {1.0, -1.0, 0.0}, {1.0, 1.0, 0.0}, {-1.0, 1.0, 0.0}],
              normal: normal,
              color: 0
            }
          ],
          lines: [],
          labels: []
        }
      end

      assert [_] = Project.run(quad.({0.0, 0.0, 1.0}), @front).polys
      # The contract's most likely geometry bug: reverse the normal and the face
      # disappears without error, which is exactly why `Geometry` owes a winding
      # test per primitive.
      assert Project.run(quad.({0.0, 0.0, -1.0}), @front).polys == []
    end

    test "reversing every normal inverts which of the box's faces are visible" do
      mesh = box()

      flipped = %{
        mesh
        | faces:
            Enum.map(mesh.faces, fn f ->
              {x, y, z} = f.normal
              %{f | normal: {-x, -y, -z}}
            end)
      }

      # Head-on, one face faces the eye; flip every normal and it is precisely
      # the other five that do.
      assert length(Project.run(mesh, @front).polys) == 1
      assert length(Project.run(flipped, @front).polys) == 5
    end
  end

  # ── Painter sort ────────────────────────────────────────────────────────────

  describe "painter sort (roadmap decision 7)" do
    test "polys come back ordered furthest-first" do
      quad = fn z, color ->
        %{
          verts: [{-1.0, -1.0, z}, {1.0, -1.0, z}, {1.0, 1.0, z}, {-1.0, 1.0, z}],
          normal: {0.0, 0.0, 1.0},
          color: color
        }
      end

      # Both face the camera; the one at z = -2 is behind the one at z = 2.
      mesh = %{faces: [quad.(2.0, 0), quad.(-2.0, 1)], lines: [], labels: []}

      frame = Project.run(mesh, @front)

      assert [far, near] = frame.polys
      assert far.color == 1
      assert near.color == 0
      assert far.depth > near.depth
    end

    test "a box's visible faces are monotonically non-increasing in depth" do
      frame = Project.run(box({0.0, 0.0, 0.0}, 2.0, 3), %{azimuth: 33.0, elevation: 27.0})

      depths = Enum.map(frame.polys, & &1.depth)
      assert depths == Enum.sort(depths, :desc)
      assert length(depths) > 1
    end

    test "lines are sorted furthest-first too" do
      mesh = %{
        faces: [],
        lines: [
          %{a: {-1.0, 0.0, 5.0}, b: {1.0, 0.0, 5.0}, color: 0, width: 1.0},
          %{a: {-1.0, 0.0, -5.0}, b: {1.0, 0.0, -5.0}, color: 1, width: 1.0}
        ],
        labels: []
      }

      frame = Project.run(mesh, @front)

      assert [far, near] = frame.lines
      assert far.color == 1
      assert near.color == 0
      assert far.depth > near.depth
    end

    test "labels carry depth but keep mesh order rather than being sorted" do
      mesh = %{
        faces: [],
        lines: [],
        labels: [
          %{at: {0.0, 0.0, 5.0}, text: "near"},
          %{at: {0.0, 0.0, -5.0}, text: "far"}
        ]
      }

      frame = Project.run(mesh, @front)

      # Input order preserved even though "far" is deeper — labels draw last and
      # unoccluded (decision 5), so sorting them into the geometry would be wrong.
      assert Enum.map(frame.labels, & &1.text) == ["near", "far"]
      [near, far] = frame.labels
      assert far.depth > near.depth
    end
  end

  # ── A hand-checkable case ───────────────────────────────────────────────────

  describe "unit box at the origin, azimuth 0 / elevation 0" do
    test "the single visible face is a square centred on the origin" do
      frame = Project.run(box(), @front)

      assert [poly] = frame.polys
      assert length(poly.points) == 4

      xs = Enum.map(poly.points, &elem(&1, 0))
      ys = Enum.map(poly.points, &elem(&1, 1))

      # Camera on the +Z axis, box centred at the origin: the projected quad must
      # be symmetric about both axes and square, so every coordinate has the same
      # magnitude. No magic numbers — just the symmetry the setup forces.
      magnitudes = Enum.map(xs ++ ys, &abs/1)
      [reference | rest] = magnitudes

      assert reference > 0.0
      for m <- rest, do: assert_in_delta(m, reference, 1.0e-9)

      assert_in_delta Enum.sum(xs), 0.0, 1.0e-9
      assert_in_delta Enum.sum(ys), 0.0, 1.0e-9

      # Both signs present on each axis.
      assert Enum.any?(xs, &(&1 > 0.0)) and Enum.any?(xs, &(&1 < 0.0))
      assert Enum.any?(ys, &(&1 > 0.0)) and Enum.any?(ys, &(&1 < 0.0))
    end

    test "the viewbox is square and centred on the origin, with margin to spare" do
      frame = Project.run(box(), @front)

      {min_x, min_y, w, h} = frame.viewbox

      assert_in_delta w, h, 1.0e-9
      assert_in_delta min_x, -w / 2.0, 1.0e-9
      assert_in_delta min_y, -h / 2.0, 1.0e-9

      # Every drawn point sits strictly inside the frame.
      [poly] = frame.polys
      extreme = poly.points |> Enum.flat_map(fn {x, y} -> [abs(x), abs(y)] end) |> Enum.max()
      assert extreme < w / 2.0
    end

    test "+X is to the right and +Y is up in the emitted 2D coordinates" do
      mesh = %{
        faces: [],
        lines: [],
        labels: [
          %{at: {0.0, 0.0, 0.0}, text: "origin"},
          %{at: {1.0, 0.0, 0.0}, text: "right"},
          %{at: {0.0, 1.0, 0.0}, text: "up"}
        ]
      }

      frame = Project.run(mesh, @front)
      [origin, right, up] = frame.labels

      {ox, oy} = origin.at
      {rx, _ry} = right.at
      {_ux, uy} = up.at

      assert rx > ox
      # SVG's Y axis grows downward, so "up" in the scene is a smaller Y here.
      assert uy < oy
    end

    test "shade is always inside 0.0..1.0" do
      frame = Project.run(box(), %{azimuth: 40.0, elevation: 25.0})

      assert frame.polys != []

      for poly <- frame.polys do
        assert poly.shade >= 0.0 and poly.shade <= 1.0
      end
    end
  end

  # ── Degenerate input ────────────────────────────────────────────────────────

  describe "degenerate cameras and meshes" do
    test "elevation at the clamp boundary does not produce NaN or blow up" do
      for elevation <- [89.0, -89.0, 88.999_999, 0.0] do
        frame = Project.run(box(), %{azimuth: 17.0, elevation: elevation})

        assert frame.polys != [], "expected visible geometry at elevation #{elevation}"
        assert_all_finite(frame)
      end
    end

    test "an out-of-contract elevation is re-clamped rather than degenerating" do
      # At exactly ±90 the up-vector collapses and the view basis is undefined.
      # `validate/1` forbids it; we still must not divide by zero if it arrives.
      for elevation <- [90.0, -90.0, 180.0, -270.0] do
        frame = Project.run(box(), %{azimuth: 0.0, elevation: elevation})
        assert_all_finite(frame)
      end
    end

    test "any azimuth is fine, including huge and negative ones" do
      for azimuth <- [0.0, 359.9, -720.0, 1_000_000.0] do
        frame = Project.run(box(), %{azimuth: azimuth, elevation: 15.0})
        assert frame.polys != []
        assert_all_finite(frame)
      end
    end

    test "an empty mesh returns an empty frame with a sane square viewbox" do
      frame = Project.run(empty_mesh(), @front)

      assert frame.polys == []
      assert frame.lines == []
      assert frame.labels == []

      {min_x, min_y, w, h} = frame.viewbox
      assert w > 0.0
      assert h > 0.0
      assert_in_delta w, h, 1.0e-9
      assert_in_delta min_x, -w / 2.0, 1.0e-9
      assert_in_delta min_y, -h / 2.0, 1.0e-9
    end

    test "a mesh with a single point has no extent to fit and still frames sanely" do
      mesh = %{faces: [], lines: [], labels: [%{at: {7.0, -3.0, 2.0}, text: "here"}]}

      frame = Project.run(mesh, %{azimuth: 20.0, elevation: 20.0})

      assert [label] = frame.labels
      assert {x, y} = label.at
      assert_in_delta x, 0.0, 1.0e-6
      assert_in_delta y, 0.0, 1.0e-6

      {_min_x, _min_y, w, h} = frame.viewbox
      assert w > 0.0 and h > 0.0
      assert_all_finite(frame)
    end

    test "a zero-extent bounding box (coincident points) does not divide by zero" do
      p = {1.5, 1.5, 1.5}

      mesh = %{
        faces: [],
        lines: [%{a: p, b: p, color: 0, width: 1.0}],
        labels: [%{at: p, text: "dot"}]
      }

      frame = Project.run(mesh, @front)

      assert length(frame.lines) == 1
      assert_all_finite(frame)
    end

    test "a flat scene with zero extent on one axis still fits" do
      # A ground plane: no thickness in Y at all.
      mesh = %{
        faces: [
          %{
            verts: [{-5.0, 0.0, -5.0}, {5.0, 0.0, -5.0}, {5.0, 0.0, 5.0}, {-5.0, 0.0, 5.0}],
            normal: {0.0, 1.0, 0.0},
            color: 4
          }
        ],
        lines: [],
        labels: []
      }

      frame = Project.run(mesh, %{azimuth: 0.0, elevation: 45.0})

      assert [poly] = frame.polys
      assert length(poly.points) == 4
      assert_all_finite(frame)
    end

    test "a face with a degenerate normal is culled rather than crashing" do
      mesh = %{
        faces: [
          %{
            verts: [{-1.0, -1.0, 0.0}, {1.0, -1.0, 0.0}, {1.0, 1.0, 0.0}],
            normal: {0.0, 0.0, 0.0},
            color: 0
          }
        ],
        lines: [],
        labels: []
      }

      frame = Project.run(mesh, @front)

      assert frame.polys == []
      assert_all_finite(frame)
    end

    test "a face with no vertices is skipped" do
      mesh = %{faces: [%{verts: [], normal: {0.0, 0.0, 1.0}, color: 0}], lines: [], labels: []}

      assert Project.run(mesh, @front).polys == []
    end
  end

  # ── Contract shape ──────────────────────────────────────────────────────────

  test "the frame carries exactly the keys the contract declares" do
    mesh = %{
      box()
      | lines: [%{a: {0.0, 0.0, 0.0}, b: {1.0, 1.0, 1.0}, color: 1, width: 2.0}],
        labels: [%{at: {0.0, 1.0, 0.0}, text: "top"}]
    }

    frame = Project.run(mesh, %{azimuth: 25.0, elevation: 15.0})

    assert Map.keys(frame) |> Enum.sort() == [:labels, :lines, :polys, :viewbox]

    for poly <- frame.polys do
      assert Map.keys(poly) |> Enum.sort() == [:color, :depth, :points, :shade]
    end

    for line <- frame.lines do
      assert Map.keys(line) |> Enum.sort() == [:a, :b, :color, :depth, :width]
      assert line.width == 2.0
    end

    for label <- frame.labels do
      assert Map.keys(label) |> Enum.sort() == [:at, :depth, :text]
    end

    assert {_, _, _, _} = frame.viewbox
  end
end
