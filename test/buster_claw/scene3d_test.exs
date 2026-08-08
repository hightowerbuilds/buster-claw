defmodule BusterClaw.Scene3dTest do
  use ExUnit.Case, async: true

  alias BusterClaw.Scene3d

  # A minimal well-formed scene, as JSON, so each test can vary one thing.
  defp json(map), do: Jason.encode!(map)

  defp box(extra \\ %{}), do: Map.merge(%{"kind" => "box", "size" => [1, 1, 1]}, extra)

  defp scene(nodes, extra \\ %{}) do
    Map.merge(%{"camera" => %{"azimuth" => 30, "elevation" => 20}, "nodes" => nodes}, extra)
  end

  defp validate(map), do: map |> json() |> Scene3d.validate()

  defp expanded(nodes) do
    {:ok, parsed} = validate(scene(nodes))
    Scene3d.expand(parsed)
  end

  describe "extract/1" do
    test "pulls a scene block and strips it from the text" do
      text = ~s(Here is the rack:\n```scene3d\n{"nodes":[{"kind":"box"}]}\n```\nAs shown.)

      {clean, [block]} = Scene3d.extract(text)

      assert clean == "Here is the rack:\n\nAs shown."
      assert block == ~s({"nodes":[{"kind":"box"}]})
    end

    test "keeps multiple blocks in document order" do
      text = ~s(a ```scene3d\n{"n":1}``` b ```scene3d\n{"n":2}``` c)
      {clean, blocks} = Scene3d.extract(text)

      assert blocks == [~s({"n":1}), ~s({"n":2})]
      assert clean == "a  b  c"
    end

    test "drops a body that is not a JSON object" do
      assert {"", []} = Scene3d.extract("```scene3d\njust talking about scenes\n```")
      assert {"", []} = Scene3d.extract("```scene3d\n[1,2,3]\n```")
    end

    test "drops a block over the byte cap" do
      fat = ~s({"nodes":") <> String.duplicate("x", 33_000) <> ~s("})
      assert {_clean, []} = Scene3d.extract("```scene3d\n#{fat}\n```")
    end

    test "text with no block passes through unchanged" do
      assert Scene3d.extract("plain reply") == {"plain reply", []}
    end

    test "non-binary input is returned untouched with no blocks" do
      assert Scene3d.extract(nil) == {nil, []}
    end
  end

  describe "validate/1 — the happy path and its defaults" do
    test "a full scene validates" do
      assert {:ok, parsed} =
               validate(
                 scene([
                   %{
                     "kind" => "box",
                     "at" => [1, 2, 3],
                     "rotate" => [0, 45, 0],
                     "size" => [2, 1, 2],
                     "color" => 3,
                     "label" => "web-01"
                   }
                 ])
               )

      assert parsed.camera == %{azimuth: 30.0, elevation: 20.0}

      assert [
               %{
                 kind: :box,
                 at: {1.0, 2.0, 3.0},
                 rotate: {+0.0, 45.0, +0.0},
                 size: {2.0, 1.0, 2.0},
                 color: 3,
                 label: "web-01"
               }
             ] = parsed.nodes
    end

    test "omitted optional fields get defaults so downstream never sees a missing key" do
      assert {:ok, %{nodes: [node]}} = validate(scene([box()]))

      assert node.at == {0.0, 0.0, 0.0}
      assert node.rotate == {0.0, 0.0, 0.0}
      assert node.color == 0
      assert node.label == nil
    end

    test "an omitted camera defaults to a three-quarter view" do
      assert {:ok, %{camera: camera}} = validate(%{"nodes" => [box()]})
      assert camera == %{azimuth: 35.0, elevation: 25.0}
    end

    test "elevation is clamped, not rejected; azimuth wraps" do
      assert {:ok, %{camera: %{elevation: 89.0}}} =
               validate(scene([box()], %{"camera" => %{"elevation" => 90}}))

      assert {:ok, %{camera: %{elevation: -89.0}}} =
               validate(scene([box()], %{"camera" => %{"elevation" => -1000}}))

      assert {:ok, %{camera: %{azimuth: 10.0}}} =
               validate(scene([box()], %{"camera" => %{"azimuth" => 370}}))

      assert {:ok, %{camera: %{azimuth: 350.0}}} =
               validate(scene([box()], %{"camera" => %{"azimuth" => -10}}))
    end

    test "every primitive kind is expressible" do
      nodes = [
        %{"kind" => "box", "size" => [1, 1, 1]},
        %{"kind" => "sphere", "r" => 0.5},
        %{"kind" => "cylinder", "r" => 0.5, "h" => 2},
        %{"kind" => "plane", "size" => [10, 10]},
        %{"kind" => "capsule", "r" => 0.3, "h" => 1.5},
        %{"kind" => "polyline", "points" => [[0, 0, 0], [1, 1, 1], [2, 0, 2]]},
        %{"kind" => "arrow", "from" => [0, 0, 0], "to" => [0, 3, 0]}
      ]

      assert {:ok, %{nodes: validated}} = validate(scene(nodes))
      assert length(validated) == 7

      assert Enum.map(validated, & &1.kind) ==
               [:box, :sphere, :cylinder, :plane, :capsule, :polyline, :arrow]
    end

    test "a plane is authored as [width, depth] and stored as a zero-thickness vec3" do
      assert {:ok, %{nodes: [%{size: {10.0, +0.0, 4.0}}]}} =
               validate(scene([%{"kind" => "plane", "size" => [10, 4]}]))
    end

    test "a blank label collapses to nil rather than an empty text node" do
      assert {:ok, %{nodes: [%{label: nil}]}} = validate(scene([box(%{"label" => "   "})]))
    end
  end

  describe "validate/1 — malformed input fails closed with a named reason" do
    test "non-string input" do
      assert Scene3d.validate(%{}) == {:error, :not_a_string}
      assert Scene3d.validate(nil) == {:error, :not_a_string}
    end

    test "over the byte cap" do
      assert Scene3d.validate(String.duplicate("x", 40_000)) == {:error, :too_large}
    end

    test "unparseable JSON" do
      assert Scene3d.validate("{not json") == {:error, :invalid_json}
      assert Scene3d.validate("") == {:error, :invalid_json}
    end

    test "JSON that is not an object" do
      assert Scene3d.validate("[1,2,3]") == {:error, :not_an_object}
      assert Scene3d.validate("42") == {:error, :not_an_object}
    end

    test "unknown top-level key" do
      assert validate(scene([box()], %{"lights" => []})) == {:error, :unknown_key}
    end

    test "unknown node key" do
      assert validate(scene([box(%{"material" => "chrome"})])) == {:error, :unknown_key}
    end

    test "a field belonging to a different kind is still an unknown key" do
      assert validate(scene([%{"kind" => "sphere", "r" => 1, "size" => [1, 1, 1]}])) ==
               {:error, :unknown_key}
    end

    test "unknown camera key" do
      assert validate(scene([box()], %{"camera" => %{"fov" => 60}})) == {:error, :unknown_key}
    end

    test "a non-map camera" do
      assert validate(scene([box()], %{"camera" => [30, 20]})) == {:error, :bad_camera}
    end

    test "unknown kind, and a kind that is not a string" do
      assert validate(scene([%{"kind" => "torus", "r" => 1}])) == {:error, :unknown_kind}
      assert validate(scene([%{"kind" => 7}])) == {:error, :unknown_kind}
      assert validate(scene([%{}])) == {:error, :unknown_kind}
    end

    test "a kind name never becomes an atom" do
      name = "definitely_not_an_existing_atom_9f3a"
      assert validate(scene([%{"kind" => name}])) == {:error, :unknown_kind}
      # The atom table is a finite, unreclaimed resource; if the validator ever
      # interned model input this would stop raising.
      assert_raise ArgumentError, fn -> String.to_existing_atom(name) end
    end

    test "missing a required shape field" do
      assert validate(scene([%{"kind" => "box"}])) == {:error, :missing_field}
      assert validate(scene([%{"kind" => "cylinder", "r" => 1}])) == {:error, :missing_field}

      assert validate(scene([%{"kind" => "arrow", "from" => [0, 0, 0]}])) ==
               {:error, :missing_field}
    end

    test "a node that is not a map" do
      assert validate(scene(["box"])) == {:error, :bad_node}
    end

    test "nodes missing, empty, or not a list" do
      assert validate(%{"camera" => %{}}) == {:error, :empty_scene}
      assert validate(scene([])) == {:error, :empty_scene}
      assert validate(scene(%{"a" => 1})) == {:error, :bad_nodes}
    end

    test "a malformed vector" do
      assert validate(scene([box(%{"at" => [1, 2]})])) == {:error, :bad_vec3}
      assert validate(scene([box(%{"at" => "origin"})])) == {:error, :bad_vec3}
      # A component error keeps its own reason — "which way it was wrong" is the
      # whole value of a named reason.
      assert validate(scene([box(%{"at" => [1, "2", 3]})])) == {:error, :bad_number}
    end

    test "a non-positive or malformed size" do
      assert validate(scene([box(%{"size" => [0, 1, 1]})])) == {:error, :bad_size}
      assert validate(scene([box(%{"size" => [-1, 1, 1]})])) == {:error, :bad_size}
      assert validate(scene([box(%{"size" => [1, 1]})])) == {:error, :bad_size}
      assert validate(scene([%{"kind" => "plane", "size" => [1, 1, 1]}])) == {:error, :bad_size}
      assert validate(scene([%{"kind" => "plane", "size" => [0, 1]}])) == {:error, :bad_size}
    end

    test "a non-positive radius or height" do
      assert validate(scene([%{"kind" => "sphere", "r" => 0}])) == {:error, :out_of_range}

      assert validate(scene([%{"kind" => "cylinder", "r" => 1, "h" => -2}])) ==
               {:error, :out_of_range}
    end

    test "a palette index out of range, or not an integer" do
      assert validate(scene([box(%{"color" => 5})])) == {:error, :bad_color}
      assert validate(scene([box(%{"color" => -1})])) == {:error, :bad_color}
      assert validate(scene([box(%{"color" => 1.0})])) == {:error, :bad_color}
      assert validate(scene([box(%{"color" => "red"})])) == {:error, :bad_color}
    end

    test "a label that is too long, not a string, or carries control characters" do
      assert validate(scene([box(%{"label" => String.duplicate("a", 121)})])) ==
               {:error, :label_too_long}

      assert validate(scene([box(%{"label" => 42})])) == {:error, :bad_label}
      assert validate(scene([box(%{"label" => "line\nbreak"})])) == {:error, :bad_label}
    end

    test "a polyline that is too short or too long" do
      assert validate(scene([%{"kind" => "polyline", "points" => [[0, 0, 0]]}])) ==
               {:error, :bad_points}

      assert validate(scene([%{"kind" => "polyline", "points" => "a line"}])) ==
               {:error, :bad_points}

      many = for i <- 0..300, do: [i, 0, 0]

      assert validate(scene([%{"kind" => "polyline", "points" => many}])) ==
               {:error, :too_many_points}

      assert validate(scene([%{"kind" => "polyline", "points" => [[0, 0, 0], [1, 2]]}])) ==
               {:error, :bad_points}
    end
  end

  describe "validate/1 — numeric bounds" do
    test "Jason itself refuses NaN, Infinity, and an unrepresentable exponent" do
      assert Scene3d.validate(~s({"nodes":[{"kind":"sphere","r":NaN}]})) ==
               {:error, :invalid_json}

      assert Scene3d.validate(~s({"nodes":[{"kind":"sphere","r":Infinity}]})) ==
               {:error, :invalid_json}

      assert Scene3d.validate(~s({"nodes":[{"kind":"sphere","r":1e400}]})) ==
               {:error, :invalid_json}
    end

    test "an absurd float coordinate is out of range" do
      assert validate(scene([box(%{"at" => [1.0e300, 0, 0]})])) == {:error, :out_of_range}
    end

    test "a bignum integer is rejected before it is converted to a float" do
      # `10 ** 400 * 1.0` raises; the magnitude check has to come first.
      huge = String.duplicate("9", 400)

      assert Scene3d.validate(~s({"nodes":[{"kind":"sphere","r":#{huge}}]})) ==
               {:error, :out_of_range}
    end

    test "a huge rotation is rejected rather than fed to trig" do
      assert validate(scene([box(%{"rotate" => [0, 1.0e9, 0]})])) == {:error, :out_of_range}
    end
  end

  describe "validate/1 — composition helpers" do
    test "a grid validates, keeping its child nested" do
      assert {:ok, %{nodes: [grid]}} =
               validate(
                 scene([
                   %{"kind" => "grid", "count" => [3, 1, 3], "gap" => 2, "child" => box()}
                 ])
               )

      assert grid.kind == :grid
      assert grid.count == {3, 1, 3}
      assert grid.gap == 2.0
      assert grid.child.kind == :box
    end

    test "the count shorthand reads differently per kind" do
      assert {:ok, %{nodes: [%{count: {3, 1, 3}}]}} =
               validate(scene([%{"kind" => "grid", "count" => 3, "child" => box()}]))

      assert {:ok, %{nodes: [%{count: {2, 1, 5}}]}} =
               validate(scene([%{"kind" => "grid", "count" => [2, 5], "child" => box()}]))

      assert {:ok, %{nodes: [%{count: {1, 4, 1}}]}} =
               validate(scene([%{"kind" => "stack", "count" => 4, "child" => box()}]))

      assert {:ok, %{nodes: [%{count: {6, 1, 1}}]}} =
               validate(scene([%{"kind" => "ring", "count" => 6, "r" => 3, "child" => box()}]))
    end

    test "gap defaults to a unit of centre-to-centre spacing" do
      assert {:ok, %{nodes: [%{gap: 1.0}]}} =
               validate(scene([%{"kind" => "grid", "count" => 2, "child" => box()}]))
    end

    test "a helper rejects colour and label — they belong on the child" do
      assert validate(scene([%{"kind" => "grid", "count" => 2, "child" => box(), "color" => 2}])) ==
               {:error, :unknown_key}

      assert validate(
               scene([%{"kind" => "grid", "count" => 2, "child" => box(), "label" => "x"}])
             ) ==
               {:error, :unknown_key}
    end

    test "a ring takes a radius, not a gap" do
      assert validate(scene([%{"kind" => "ring", "count" => 4, "gap" => 1, "child" => box()}])) ==
               {:error, :unknown_key}

      assert validate(scene([%{"kind" => "ring", "count" => 4, "child" => box()}])) ==
               {:error, :missing_field}
    end

    test "a malformed or oversized count" do
      assert validate(scene([%{"kind" => "grid", "count" => 0, "child" => box()}])) ==
               {:error, :bad_count}

      assert validate(scene([%{"kind" => "grid", "count" => "many", "child" => box()}])) ==
               {:error, :bad_count}

      assert validate(scene([%{"kind" => "grid", "count" => [1, 2, 3, 4], "child" => box()}])) ==
               {:error, :bad_count}

      assert validate(scene([%{"kind" => "stack", "count" => [1, 2], "child" => box()}])) ==
               {:error, :bad_count}

      assert validate(scene([%{"kind" => "grid", "count" => [64, 1, 1], "child" => box()}])) ==
               {:error, :count_too_large}

      assert validate(scene([%{"kind" => "grid", "count" => [20, 20, 1], "child" => box()}])) ==
               {:error, :count_too_large}
    end

    test "a child that is not a map" do
      assert validate(scene([%{"kind" => "grid", "count" => 2, "child" => "box"}])) ==
               {:error, :bad_child}
    end

    test "helper nesting is capped" do
      deep =
        Enum.reduce(1..6, box(), fn _, child ->
          %{"kind" => "stack", "count" => 1, "child" => child}
        end)

      assert validate(scene([deep])) == {:error, :too_deep}
    end

    test "nesting one level inside the cap is accepted" do
      # depth 4 = three nested helpers wrapping a leaf primitive.
      ok =
        Enum.reduce(1..3, box(), fn _, child ->
          %{"kind" => "stack", "count" => 1, "child" => child}
        end)

      assert {:ok, _} = validate(scene([ok]))
    end

    test "the authored node count is capped before expansion" do
      nodes = for _ <- 1..200, do: box()
      assert validate(scene(nodes)) == {:error, :too_many_nodes}
    end
  end

  describe "expand/1" do
    test "primitives pass through unchanged and the camera is preserved" do
      {:ok, parsed} = validate(scene([box(%{"at" => [1, 0, 0], "label" => "a"})]))
      assert {:ok, flat} = Scene3d.expand(parsed)

      assert flat.camera == parsed.camera
      assert flat.nodes == parsed.nodes
    end

    test "a grid becomes concrete boxes, centred on the helper's `at`" do
      assert {:ok, flat} =
               expanded([%{"kind" => "grid", "count" => 3, "gap" => 2, "child" => box()}])

      assert length(flat.nodes) == 9
      assert Enum.all?(flat.nodes, &(&1.kind == :box))

      xs = flat.nodes |> Enum.map(&elem(&1.at, 0)) |> Enum.uniq() |> Enum.sort()
      zs = flat.nodes |> Enum.map(&elem(&1.at, 2)) |> Enum.uniq() |> Enum.sort()
      assert xs == [-2.0, 0.0, 2.0]
      assert zs == [-2.0, 0.0, 2.0]
      assert Enum.all?(flat.nodes, &(elem(&1.at, 1) == 0.0))
    end

    test "the helper's `at` offsets the whole lattice, and the child's `at` offsets each copy" do
      assert {:ok, flat} =
               expanded([
                 %{
                   "kind" => "grid",
                   "count" => [2, 1, 1],
                   "gap" => 4,
                   "at" => [10, 5, 0],
                   "child" => box(%{"at" => [0, 1, 0]})
                 }
               ])

      assert Enum.map(flat.nodes, & &1.at) == [{8.0, 6.0, 0.0}, {12.0, 6.0, 0.0}]
    end

    test "a stack runs up Y" do
      assert {:ok, flat} =
               expanded([%{"kind" => "stack", "count" => 3, "gap" => 1, "child" => box()}])

      assert Enum.map(flat.nodes, & &1.at) == [
               {0.0, -1.0, 0.0},
               {0.0, 0.0, 0.0},
               {0.0, 1.0, 0.0}
             ]
    end

    test "a ring places copies on a circle and spins each to face outward" do
      assert {:ok, flat} =
               expanded([%{"kind" => "ring", "count" => 4, "r" => 2, "child" => box()}])

      assert length(flat.nodes) == 4

      # Every copy sits on the circle of radius 2 in the XZ plane.
      for %{at: {x, y, z}} <- flat.nodes do
        assert_in_delta :math.sqrt(x * x + z * z), 2.0, 1.0e-9
        assert y == 0.0
      end

      yaws = flat.nodes |> Enum.map(&elem(&1.rotate, 1)) |> Enum.map(&Float.round(&1, 6))
      assert yaws == [0.0, 90.0, 180.0, 270.0]
    end

    test "a helper's rotate is applied to each copy, not to the lattice" do
      assert {:ok, flat} =
               expanded([
                 %{
                   "kind" => "grid",
                   "count" => [2, 1, 1],
                   "gap" => 2,
                   "rotate" => [0, 45, 0],
                   "child" => box()
                 }
               ])

      # The lattice stays axis-aligned...
      assert Enum.map(flat.nodes, & &1.at) == [{-1.0, 0.0, 0.0}, {1.0, 0.0, 0.0}]
      # ...while every copy carries the helper's rotation.
      assert Enum.all?(flat.nodes, &(&1.rotate == {0.0, 45.0, 0.0}))
    end

    test "helpers nest" do
      assert {:ok, flat} =
               expanded([
                 %{
                   "kind" => "grid",
                   "count" => [2, 1, 2],
                   "gap" => 3,
                   "child" => %{
                     "kind" => "stack",
                     "count" => 2,
                     "gap" => 1,
                     "child" => box(%{"color" => 2, "label" => "unit"})
                   }
                 }
               ])

      assert length(flat.nodes) == 8
      assert Enum.all?(flat.nodes, &(&1.kind == :box))
      assert Enum.all?(flat.nodes, &(&1.color == 2 and &1.label == "unit"))
      assert flat.nodes |> Enum.map(& &1.at) |> Enum.uniq() |> length() == 8
    end

    test "expansion is bounded — a grid of grids cannot smuggle in thousands of boxes" do
      assert expanded([
               %{
                 "kind" => "grid",
                 "count" => [16, 1, 16],
                 "gap" => 1,
                 "child" => %{
                   "kind" => "grid",
                   "count" => [16, 1, 16],
                   "gap" => 0.1,
                   "child" => box()
                 }
               }
             ]) == {:error, :too_many_nodes}
    end

    test "a scene sitting exactly on the flat cap is accepted" do
      assert {:ok, flat} =
               expanded([%{"kind" => "grid", "count" => [16, 1, 16], "child" => box()}])

      assert length(flat.nodes) == 256
    end

    test "one node over the flat cap is refused" do
      assert expanded([
               box(),
               %{"kind" => "grid", "count" => [16, 1, 16], "child" => box()}
             ]) == {:error, :too_many_nodes}
    end

    test "a non-scene is refused rather than raising" do
      assert Scene3d.expand(%{}) == {:error, :not_a_scene}
      assert Scene3d.expand(nil) == {:error, :not_a_scene}
      assert Scene3d.expand(%{camera: %{}, nodes: "nope"}) == {:error, :not_a_scene}
    end
  end

  describe "the whole pipeline" do
    test "a scene round-trips extract -> validate -> expand" do
      text = """
      Here is the cluster layout.

      ```scene3d
      {
        "camera": {"azimuth": 40, "elevation": 25},
        "nodes": [
          {"kind": "plane", "size": [12, 12], "color": 4},
          {"kind": "grid", "count": [3, 1, 3], "gap": 3,
           "child": {"kind": "box", "size": [1, 2, 1], "color": 1, "label": "node"}},
          {"kind": "arrow", "from": [0, 4, 0], "to": [0, 7, 0], "color": 2, "label": "uplink"}
        ]
      }
      ```

      Nine nodes, one uplink.
      """

      {clean, [block]} = Scene3d.extract(text)

      assert clean =~ "Here is the cluster layout."
      assert clean =~ "Nine nodes, one uplink."
      refute clean =~ "scene3d"

      assert {:ok, parsed} = Scene3d.validate(block)
      assert Enum.map(parsed.nodes, & &1.kind) == [:plane, :grid, :arrow]

      assert {:ok, flat} = Scene3d.expand(parsed)
      assert flat.camera == %{azimuth: 40.0, elevation: 25.0}
      assert Enum.map(flat.nodes, & &1.kind) == [:plane] ++ List.duplicate(:box, 9) ++ [:arrow]
      refute Enum.any?(flat.nodes, &(&1.kind in [:grid, :stack, :ring]))
    end
  end

  describe "hostile input" do
    test "a deliberately hostile scene is refused without crashing" do
      hostile = [
        # Huge counts.
        json(scene([%{"kind" => "grid", "count" => [999, 999, 999], "child" => box()}])),
        # Deep nesting.
        json(
          scene([
            Enum.reduce(1..40, box(), fn _, c ->
              %{"kind" => "grid", "count" => 2, "child" => c}
            end)
          ])
        ),
        # NaN / Infinity / unrepresentable exponents.
        ~s({"nodes":[{"kind":"sphere","r":NaN}]}),
        ~s({"nodes":[{"kind":"sphere","r":-Infinity}]}),
        ~s({"nodes":[{"kind":"box","size":[1e999,1,1]}]}),
        # Absurd coordinates.
        json(scene([box(%{"at" => [1.0e308, -1.0e308, 1.0e308]})])),
        # A bignum that would raise if converted to a float.
        ~s({"nodes":[{"kind":"sphere","r":#{String.duplicate("7", 5000)}}]}),
        # Structural nonsense.
        ~s({"nodes":{"kind":"box"}}),
        ~s({"nodes":[[[[[[[[[[1]]]]]]]]]]}),
        json(scene(List.duplicate(box(), 5_000)))
      ]

      for payload <- hostile do
        assert {:error, reason} = Scene3d.validate(payload)
        assert is_atom(reason)
      end
    end

    test "a 10 MB label is refused by the byte cap without ever being walked" do
      payload = json(scene([box(%{"label" => String.duplicate("a", 10_000_000)})]))
      assert byte_size(payload) > 10_000_000
      assert Scene3d.validate(payload) == {:error, :too_large}
    end

    test "a label that fits the block cap but not the label cap is still refused" do
      payload = json(scene([box(%{"label" => String.duplicate("a", 20_000)})]))
      assert byte_size(payload) < 32_000
      assert Scene3d.validate(payload) == {:error, :label_too_long}
    end

    test "a scene stuffed to the block cap with real nodes is refused, not hung" do
      nodes = for i <- 1..600, do: box(%{"at" => [i, 0, 0]})
      payload = json(scene(nodes))
      assert Scene3d.validate(payload) in [{:error, :too_large}, {:error, :too_many_nodes}]
    end
  end
end
