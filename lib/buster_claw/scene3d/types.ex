defmodule BusterClaw.Scene3d.Types do
  @moduledoc """
  The shared data contract for the Scene3D pipeline. **This module is types and
  documentation only — it holds no logic and nothing here should grow any.**

  It exists because the pipeline is built as four independent stages, and every
  stage boundary is a shape both sides must agree on exactly. Changing a type
  here changes two modules at once; do that deliberately.

  ## The pipeline

      raw text
        └─ Scene3d.extract/1      → [json_string]
        └─ Scene3d.validate/1     → t:scene/0        (authored shape, nested)
        └─ Scene3d.expand/1       → t:flat_scene/0   (helpers expanded, flat)
        └─ Scene3d.Geometry.build/1 → t:mesh/0       (world-space faces/lines/labels)
        └─ Scene3d.Project.run/2  → t:frame/0        (2D, shaded, depth-sorted)
        └─ Scene3d.Svg.render/2   → SVG string

  ## Coordinate system

  Right-handed, **Y up**. `-Z` is "into the screen" at the default camera. The
  scene's own units are arbitrary — `Project` auto-fits the camera to the scene
  bounding box (roadmap decision 3), so a scene authored at scale 0.01 and one at
  scale 1000 both render identically framed. **Nothing downstream of `validate/1`
  may assume a unit scale.**

  ## Winding and culling

  Face vertices are **counter-clockwise when viewed from outside** the solid.
  `Project` relies on this for backface culling; `Geometry` is responsible for
  emitting it correctly. A face wound backwards will silently vanish, which is
  the most likely geometry bug and the one worth a test per primitive.

  ## Colours

  Every colour is an **index into the app's validated 5-slot palette**, never a
  hex string (roadmap decision 4). Resolution to actual CSS colours happens in
  `Scene3d.Svg` and nowhere else, so the palette can be re-tuned in one place and
  so a scene stays legible in both themes.
  """

  # ── Authored shape (what the model writes, after validation) ────────────────

  @typedoc """
  A camera, as two orbit angles in degrees. Deliberately **not** an eye/target
  pair: models get look-at matrices wrong constantly, and two angles always frame
  something (roadmap decision 2).

  `azimuth` rotates around the Y axis; `elevation` lifts above the XZ plane and
  is clamped to (-89, 89) so the up-vector never degenerates.
  """
  @type camera :: %{azimuth: float(), elevation: float()}

  @typedoc "A 3D point in scene space."
  @type vec3 :: {float(), float(), float()}

  @typedoc "A 2D point in projected space (SVG user units)."
  @type vec2 :: {float(), float()}

  @typedoc "An index into the 5-slot palette."
  @type color :: 0..4

  @typedoc """
  What a node is *for*, which decides how loudly it is drawn and whether it
  frames the shot.

  - `:solid` — the subject. Full palette colour, and it counts toward the
    camera's auto-fit bounds.
  - `:surface` — backdrop: ground, water, a floor. Rendered muted and
    low-contrast, and **excluded from auto-fit bounds**.

  This exists because the palette is a *series* palette — five saturated hues
  chosen so chart series stay distinguishable. It has no quiet colour, so before
  `:surface` existed the only way to draw water was to pick a series slot, and a
  ground plane came out as a wall of magenta covering the card. A backdrop also
  must not frame the shot: bounds over every point let a large plane dominate the
  bounding box and squeeze the actual subject into a small patch in the middle.
  Both failures are visible in the Phase 2 motivating screenshot.
  """
  @type role :: :solid | :surface

  @typedoc """
  One authored node. `kind` decides which of the shape fields are present; the
  rest are universal. `label` is the **only** model-controlled text in the whole
  pipeline and must be HTML-escaped at render time.

  Composition helpers (`:grid`, `:stack`, `:ring`) carry a `child` node and a
  count/spacing, and are removed entirely by `expand/1` — no stage after
  expansion ever sees one.

  `:region` is the map primitive: a **filled** polygon lying in the ground plane,
  given as 2D `{x, z}` points (no `y` — a region is on the ground by definition,
  and omitting the axis is one fewer thing to get wrong). With `height` it
  extrudes into a prism, which is what makes a map worth rendering in 3D at all
  rather than as a tilted flat picture.
  """
  @type node_ :: %{
          required(:kind) =>
            :box
            | :sphere
            | :cylinder
            | :plane
            | :capsule
            | :polyline
            | :arrow
            | :region
            | :grid
            | :stack
            | :ring,
          required(:at) => vec3(),
          required(:rotate) => vec3(),
          required(:color) => color(),
          required(:role) => role(),
          required(:label) => String.t() | nil,
          optional(:size) => vec3(),
          optional(:r) => float(),
          optional(:h) => float(),
          optional(:points) => [vec3()],
          optional(:outline) => [{float(), float()}],
          optional(:height) => float(),
          optional(:from) => vec3(),
          optional(:to) => vec3(),
          optional(:child) => node_(),
          optional(:count) => {pos_integer(), pos_integer(), pos_integer()},
          optional(:gap) => float()
        }

  @typedoc "A validated scene, helpers still nested."
  @type scene :: %{camera: camera(), nodes: [node_()]}

  @typedoc """
  A validated scene with every composition helper expanded to concrete
  primitives. The node cap is enforced **here**, after expansion — a small `grid`
  must not be able to smuggle in ten thousand boxes.
  """
  @type flat_scene :: %{camera: camera(), nodes: [node_()]}

  # ── Mesh (world-space geometry, pre-camera) ─────────────────────────────────

  @typedoc """
  A convex planar polygon in world space, wound CCW from outside. `normal` is
  precomputed because both culling and shading need it and it is cheaper to
  carry than to recompute per frame.
  """
  @type face :: %{verts: [vec3()], normal: vec3(), color: color(), role: role()}

  @typedoc """
  A world-space line segment. Used by `:polyline` and `:arrow`.

  **`width` is a constant stroke weight, not a scene-space measurement, and it
  passes through `Project` unscaled.** That is deliberate and worth understanding
  before "fixing" it: scaling it by the auto-fit — the intuitive move — would make
  stroke weight depend on the scale a scene happened to be authored at, which is
  exactly the coupling the auto-fit exists to remove.

  `Scene3d.Svg` renders strokes with `vector-effect="non-scaling-stroke"`, so the
  final unit is **CSS pixels of the rendered card**, independent of the viewBox.
  A width of `1.0` is a 1px line at any scene scale and any card size.
  """
  @type line :: %{a: vec3(), b: vec3(), color: color(), width: float()}

  @typedoc """
  A world-space label anchor. Labels **billboard** (always face the camera) and
  are drawn after all geometry so they are never occluded (roadmap decision 5).
  """
  @type label :: %{at: vec3(), text: String.t()}

  @typedoc "Everything `Geometry` produces from a flat scene."
  @type mesh :: %{faces: [face()], lines: [line()], labels: [label()]}

  # ── Frame (2D, ready to serialize) ──────────────────────────────────────────

  @typedoc """
  A projected polygon. `depth` is the view-space centroid depth used for the
  painter sort (larger = further away). `shade` is a 0.0–1.0 lighting factor from
  the face normal against a fixed key light — `Svg` may use it or ignore it, but
  `Project` always computes it so Phase 2 shading is a render-side change only.

  **`depth` is in scene units and is NOT scale-invariant** — a scene authored
  1000× larger has 1000× the depths. Only the *ordering* is scale-free. Anything
  deriving a visual property from depth (Phase 2's distance desaturation, or
  shrinking labels with distance) must normalise against the frame's own
  min/max and must never treat `depth` as a 0–1 quantity.

  `shade` is lit from a key light fixed in **view** space, so it orbits with the
  camera and the scene is front-lit at every azimuth. Physically dishonest, and
  deliberately so: a diagram that goes dark when you turn it is the worse lie.
  """
  @type poly :: %{
          points: [vec2()],
          color: color(),
          shade: float(),
          depth: float(),
          role: role()
        }

  @type poly_line :: %{a: vec2(), b: vec2(), color: color(), width: float(), depth: float()}

  @type poly_label :: %{at: vec2(), text: String.t(), depth: float()}

  @typedoc """
  A label after layout: where it will actually be drawn, at what size, and
  whether it needs a leader line back to the thing it names.

  `anchor` is the projected point the label belongs to; `at` is where it ended up
  after collision resolution. When they differ, `leader` is true and the renderer
  draws a hairline between them — an offset label with no leader is a label
  pointing at nothing.

  Labels that could not be placed are **absent from the list**, not marked. A
  dropped label is not lost information: the card's caption already names
  everything in the scene, so the honest trade is a readable picture plus a
  complete list, rather than thirteen overlapping words and neither.
  """
  @type placed_label :: %{
          at: vec2(),
          anchor: vec2(),
          text: String.t(),
          size: float(),
          leader: boolean()
        }

  @typedoc """
  A finished 2D frame. `polys` and `lines` arrive **already sorted back-to-front**
  (painter's algorithm, roadmap decision 7) — `Svg` emits them in order and does
  no sorting of its own. `viewbox` is `{min_x, min_y, width, height}` and comes
  from the auto-fit, so the SVG always frames the whole scene.

  Painter's algorithm is wrong for interpenetrating solids. That is accepted and
  documented rather than solved; the authoring guide forbids intersecting
  geometry. **Do not add a BSP tree here.**

  **`polys` and `lines` are sorted independently and therefore cannot interleave
  by depth** — a renderer necessarily draws one group entirely before the other.
  Drawing lines *over* polys is the chosen failure, because an arrow hidden
  inside the box it points at is worse than one drawn slightly in front of it.
  Genuine interleaving would require changing this type, not the renderer.
  """
  @type frame :: %{
          polys: [poly()],
          lines: [poly_line()],
          labels: [poly_label()],
          viewbox: {float(), float(), float(), float()}
        }
end
