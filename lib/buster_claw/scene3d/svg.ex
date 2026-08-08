defmodule BusterClaw.Scene3d.Svg do
  @moduledoc """
  The last stage of the Scene3D pipeline (SCENE3D_ROADMAP Phase 1): a
  `t:BusterClaw.Scene3d.Types.frame/0` serialized to one self-contained
  `<svg>…</svg>` string.

  Server-rendered SVG, for exactly the reasons `BusterClawWeb.PortfolioChart`
  gives: the numbers already live on the server, LiveView already re-renders, and
  the CSP forbids fetching a drawing library anyway. There is no charting or 3D
  dependency here and there should not be one.

  ## The safety posture, which inverts `BusterClaw.SvgViewer`'s

  `SvgViewer` receives markup **the model wrote** and sanitizes it — its trust
  boundary is a regex trying to out-think a browser's parser, which is why it
  leans on the CSP as the real backstop.

  This module **generates** markup from numbers a validator already bounded. No
  model-authored tag, attribute, or URL exists anywhere in the pipeline, so there
  is nothing to sanitize and no sanitizer to outsmart. That makes this channel
  structurally safer than the one it sits beside.

  The one exception, and it is the only one: **label text**. Per
  `BusterClaw.Scene3d.Types`, `label` is the sole model-controlled string in the
  whole pipeline, and it is the sole thing here that reaches the DOM as content
  rather than as our own bytes. It passes through `Phoenix.HTML.html_escape/1` on
  its single path to the output (`esc/1`), which is total — a non-binary yields
  `""` rather than raising. Escaping is applied at the emit site, not at the
  boundary, so a future caller cannot route around it.

  ## What it draws

  **In the order given, and only that order.** The frame arrives already sorted
  back-to-front by `Project` (painter's algorithm, roadmap decision 7); this
  module does no sorting of its own, because a second sort here would be a second
  place for the depth order to be wrong. Faces first, then lines, then **all
  labels last**, so a label is never occluded by geometry drawn after it
  (decision 5).

  Colours are palette indices, never hex, right up to this module — resolution to
  CSS happens here and nowhere else (decision 4) so the palette can be re-tuned in
  one place. See `@palette`.

  `viewBox` comes from the frame's auto-fit. There are deliberately **no `width`
  or `height` attributes**: the card sizes the element with CSS, and a hardcoded
  size would fight it. `preserveAspectRatio` is left at its default
  (`xMidYMid meet`) — a 3D projection that gets stretched non-uniformly stops
  being a projection.

  ## Limits, stated rather than solved

  * **Lines always draw over faces.** `polys` and `lines` are sorted
    independently, so they cannot interleave by depth and *some* group must be
    drawn whole first. Lines win deliberately: an arrow hidden inside the box it
    points at is a worse failure than one drawn slightly in front of it. Real
    interleaving is a change to `Types`, not to this module.
  * **Painter's algorithm is wrong for interpenetrating solids.** Documented in
    `Types` and forbidden by the authoring guide. **Do not add a BSP tree.**
  * **Label placement is not decided here** (Phase 2). `Scene3d.Labels` owns
    sizing, collision resolution and dropping; this module renders the
    `t:BusterClaw.Scene3d.Types.placed_label/0` list it returns, each at its own
    `size` and `at`, plus a hairline leader for any whose `at` drifted off its
    `anchor`. **A label absent from that list was dropped deliberately and is not
    drawn** — the card's caption still names it, and the `<title>` here is still
    derived from the frame's *full* label list, so a dropped label never
    disappears from the accessible name. `@label_scale` survives only as the
    fallback size for a malformed entry.
  * **A `:surface` poly is drawn as a wash, not as a colour** (Phase 2). See
    `mute/1`: the palette is a *series* palette with no quiet slot, so a ground
    plane picked one and came out as a wall of magenta over most of the card.
    Adding a sixth "quiet" slot would break the five-slot colourblind validation,
    so the quiet tone is *derived* instead.
  * **`depth` is not used for anything visual here**, by design. It is in scene
    units and is *not* scale-invariant — only the ordering it produced upstream
    is scale-free. Phase 2's distance cues must normalise against the frame's own
    min/max first; nothing in this module may treat `depth` as a 0–1 quantity.
  * **Shading is deliberately narrow** (`@shade_floor`). Phase 1 wants solids to
    read as solids, not a lighting model; a wide range darkens facets into the
    `#121212` ground on the dark theme. Real shading is Phase 2, and because
    `Project` already computes `shade`, it stays a render-side change.
  * **Stroke widths are CSS pixels, not scene units.** Every stroke carries
    `vector-effect="non-scaling-stroke"`, because the viewBox is auto-fitted to an
    arbitrary scene scale — a scene authored at 0.01 and one at 1000 would
    otherwise get wildly different edge weights. The cost is that a `line`'s
    authored `width` reads as px.
  """

  alias BusterClaw.Scene3d.Labels
  alias BusterClaw.Scene3d.Types

  # The Chart Builder's validated 5-slot palette (reconciled against the
  # `dataviz` method, Chart Builder Phase 3, `9c12d24`), carried here as RGB so
  # shading is a multiply rather than a parse. In slot order:
  #
  #   0 hazard  #ff4407 · 1 cyan    #00a1ce · 2 violet #9417ff
  #   3 magenta #e10095 · 4 yellow  #ac9000
  #
  # **The order is the colourblind-safety mechanism, not decoration** — worst
  # adjacent CVD ΔE 16.0, worst adjacent normal-vision ΔE 23.4, all five slots at
  # or above 3:1 on the dark canvas. Changing a hex or reordering a slot
  # invalidates that validation run. The Chart Builder code that first carried
  # these hexes was deleted with the trading stack on 08-08; the palette itself
  # is app-wide and outlived it.
  @palette {{255, 68, 7}, {0, 161, 206}, {148, 23, 255}, {225, 0, 149}, {172, 144, 0}}

  # An out-of-range or non-integer index resolves here rather than raising. It
  # should be unreachable — `validate/1` bounds the index — but this stage is the
  # last one before the DOM and is not the place to discover otherwise.
  @fallback_slot 0

  # Faces are multiplied between @shade_floor and 1.0. Narrow on purpose: see the
  # moduledoc. Going lower reads as "faceted" on #F4F1EA and as "missing" on
  # #121212.
  @shade_floor 0.8

  # Edge strokes derive from the face's *unshaded* colour, so a silhouette reads
  # as one continuous seam across facets of differing brightness.
  @edge_factor 0.55

  # ── The muted tone for `role: :surface` ─────────────────────────────────────
  #
  # A backdrop must read as backdrop. Two knobs, and they do different jobs:
  #
  # 1. **Chroma.** Mix the palette colour toward neutral grey, keeping
  #    @surface_chroma of it. A *hint* of hue, so two surfaces in one scene are
  #    still told apart, but nowhere near series strength. The mix target is a
  #    fixed mid grey rather than the colour's own luminance on purpose: the
  #    colour's luminance varies wildly across the five slots (magenta's is
  #    ~59, yellow's ~140), so mixing toward it would make "quiet" mean a
  #    different lightness per slot, and magenta would vanish on #121212.
  #
  # 2. **Alpha.** Then paint that tone at @surface_fill_opacity so it composites
  #    against whatever the card's ground actually is. **This is the fill-side
  #    equivalent of the `currentColor` trick used for labels** — we do not know
  #    the theme at render time and must not guess a hex, so instead of blending
  #    toward a ground we picked, we let the browser blend toward the real one.
  #    A mid grey at 18% lands ~1.4:1 against #121212 and ~1.15:1 against
  #    #F4F1EA: present on both, subject on neither.
  #
  # The cost, stated rather than solved: alpha accumulates where two surfaces
  # overlap. Backdrops are one or two planes in practice, and the alternative —
  # picking a ground hex — is wrong on one theme by construction.
  @surface_chroma 0.25
  @surface_grey 128
  @surface_fill_opacity 0.18

  # The surface's own edge, quiet to match. Same tone as the fill, just less
  # transparent, so the plane has a discernible boundary on both grounds without
  # becoming a frame. It deliberately does NOT use @edge_factor: darkening a
  # muted tone sinks it into the dark ground and reads as a missing edge.
  @surface_stroke_opacity 0.4

  # Leader hairline from a displaced label back to the point it names. Inherits
  # `currentColor` like the text it belongs to, and is held well under it — a
  # leader is a pointer, not a line in the drawing.
  @leader_opacity 0.35

  # Fallback label size, as a fraction of the smaller viewBox dimension, so text
  # stays proportionate whatever scale the scene was authored at (decision 3).
  # Sizing is `Scene3d.Labels`' job now; this covers a placed label that arrives
  # without a usable one.
  @label_scale 0.055

  # Labels beyond this many stop being useful in an accessible name; the rest are
  # counted instead. They all still render.
  @named_labels 8

  @typedoc """
  Render options.

  * `:class` — CSS classes for the root `<svg>`; how the card sizes it.
  * `:title` — the accessible name. Defaults to one derived from the scene's own
    labels, because `role="img"` hides the inner `<text>` from assistive tech and
    a generic name would throw away the only thing the scene says out loud.
  * `:layout` — the label layout function, defaulting to `&Labels.layout/3`.
    A seam, not a feature: it lets *this* module's rendering of a placed label be
    tested against known input, without the test depending on another module's
    collision policy. Production never passes it, and any other option given here
    is forwarded to the layout function.

  `:class` and `:title` are escaped like any other text.
  """
  @type opts :: [class: String.t(), title: String.t(), layout: (... -> [Types.placed_label()])]

  @doc """
  Serialize a frame to one complete, self-contained SVG document.

  Pure: no IO, no process state, no clock. The same frame always produces the
  same bytes, which is what makes this stage testable without a browser.
  """
  @spec render(Types.frame(), opts()) :: String.t()
  def render(%{polys: polys, lines: lines, labels: labels, viewbox: viewbox}, opts \\ [])
      when is_list(opts) do
    {min_x, min_y, w, h} = box = viewbox(viewbox)

    [
      ~s(<svg xmlns="http://www.w3.org/2000/svg" viewBox="),
      num(min_x),
      " ",
      num(min_y),
      " ",
      num(w),
      " ",
      num(h),
      ~s(" role="img"),
      class_attr(opts),
      ">",
      "<title>",
      title(opts, labels),
      "</title>",
      # Order is the whole contract of this function: geometry as given, then
      # every label that survived layout, last.
      poly_layer(polys),
      line_layer(lines),
      label_layer(layout(labels, box, opts), label_size(w, h)),
      "</svg>"
    ]
    |> IO.iodata_to_binary()
  end

  # ── Layers ──────────────────────────────────────────────────────────────────

  defp poly_layer([]), do: []

  defp poly_layer(polys) do
    [~s(<g data-layer="polys">), Enum.map(polys, &poly/1), "</g>"]
  end

  defp poly(%{points: points, color: color, shade: shade} = poly) do
    [
      ~s(<polygon points="),
      points(points),
      ~s(" ),
      paint(slot(color), shade_factor(shade), role(poly)),
      ~s( stroke-width="1" stroke-linejoin="round" vector-effect="non-scaling-stroke"/>)
    ]
  end

  # `role` is Phase 2's addition to `t:Types.poly/0`. Defaulting a poly without
  # one to `:solid` keeps the loud reading for anything that predates the field —
  # a backdrop drawn as a subject is ugly, a subject drawn as a backdrop is gone.
  defp role(%{role: :surface}), do: :surface
  defp role(_poly), do: :solid

  defp paint(rgb, shade, :solid) do
    [
      ~s(fill="),
      hex(scale(rgb, shade)),
      ~s(" stroke="),
      hex(scale(rgb, @edge_factor)),
      ~s(")
    ]
  end

  defp paint(rgb, shade, :surface) do
    tone = hex(scale(mute(rgb), shade))

    [
      ~s(fill="),
      tone,
      ~s(" fill-opacity="),
      num(@surface_fill_opacity),
      ~s(" stroke="),
      tone,
      ~s(" stroke-opacity="),
      num(@surface_stroke_opacity),
      ~s(")
    ]
  end

  defp line_layer([]), do: []

  defp line_layer(lines) do
    [~s(<g data-layer="lines">), Enum.map(lines, &line/1), "</g>"]
  end

  defp line(%{a: {ax, ay}, b: {bx, by}, color: color, width: width}) do
    [
      ~s(<line x1="),
      num(ax),
      ~s(" y1="),
      num(ay),
      ~s(" x2="),
      num(bx),
      ~s(" y2="),
      num(by),
      ~s(" stroke="),
      hex(slot(color)),
      ~s(" stroke-width="),
      num(stroke_width(width)),
      ~s(" stroke-linecap="round" vector-effect="non-scaling-stroke"/>)
    ]
  end

  # `Scene3d.Labels` decides where each label goes, how big it is, and which ones
  # do not fit at all. Called only when there is something placeable to place, so
  # an empty frame is still renderable with no collaborator in the picture.
  #
  # The filter is this module keeping its own promise, not distrust of the
  # collaborator: Phase 1 guarantees that a malformed label cannot crash the last
  # stage before the DOM, and delegating does not transfer that guarantee. A
  # label whose text is not a string or whose anchor is not a point could not be
  # drawn anyway, and it still reaches the accessible name, which is derived from
  # the frame's own list rather than from this one.
  defp layout(labels, box, opts) do
    case Enum.filter(labels, &placeable?/1) do
      [] ->
        []

      placeable ->
        fun = Keyword.get(opts, :layout, &Labels.layout/3)
        fun.(placeable, box, Keyword.drop(opts, [:class, :title, :layout]))
    end
  end

  defp placeable?(%{at: {x, y}, text: text}) when is_number(x) and is_number(y) do
    is_binary(text) and text != ""
  end

  defp placeable?(_label), do: false

  defp label_layer([], _fallback), do: []

  defp label_layer(placed, fallback) do
    [
      # `currentColor` is the cross-theme mechanism: the label inherits the card's
      # text colour, so it inverts with the theme instead of us guessing a hex
      # that has to be legible on both #F4F1EA and #121212. `font-size` is no
      # longer here — each label carries its own.
      ~s(<g data-layer="labels" font-family="ui-sans-serif, system-ui, sans-serif"),
      ~s( text-anchor="middle" dominant-baseline="middle" fill="currentColor">),
      # Leaders first, so text sits over its own hairline rather than under it.
      Enum.map(placed, &leader/1),
      Enum.map(placed, &label(&1, fallback)),
      "</g>"
    ]
  end

  # A displaced label with no leader is a label pointing at nothing, so the
  # hairline is drawn from the anchor it names to wherever layout moved it.
  defp leader(%{leader: true, at: {x, y}, anchor: {ax, ay}}) do
    [
      ~s(<line x1="),
      num(ax),
      ~s(" y1="),
      num(ay),
      ~s(" x2="),
      num(x),
      ~s(" y2="),
      num(y),
      ~s(" stroke="currentColor" stroke-opacity="),
      num(@leader_opacity),
      ~s(" stroke-width="1" vector-effect="non-scaling-stroke"/>)
    ]
  end

  defp leader(_placed), do: []

  defp label(%{at: {x, y}, text: text} = placed, fallback) do
    [
      ~s(<text x="),
      num(x),
      ~s(" y="),
      num(y),
      ~s(" font-size="),
      num(font_size(placed, fallback)),
      ~s(">),
      esc(text),
      "</text>"
    ]
  end

  # This is the last stage before the DOM and not the place to discover that a
  # collaborator handed over a shape it promised not to.
  defp label(_placed, _fallback), do: []

  defp font_size(%{size: size}, _fallback) when is_number(size) and size > 0, do: size
  defp font_size(_placed, fallback), do: fallback

  # ── Text: the one model-controlled surface ──────────────────────────────────

  # The only place a model-authored string becomes output. Total by construction:
  # `html_escape/1` handles any binary, and anything else is dropped. Escapes
  # `& < > " '`, which covers both the element-content case (`<script>`) and the
  # attribute case (`" onload="`) — the title lands in element content too, but is
  # escaped identically so the distinction never has to be remembered.
  @spec esc(term()) :: String.t()
  defp esc(text) when is_binary(text) do
    text |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()
  end

  defp esc(_other), do: ""

  defp class_attr(opts) do
    case Keyword.get(opts, :class) do
      class when is_binary(class) and class != "" -> [~s( class="), esc(class), ~s(")]
      _ -> []
    end
  end

  defp title(opts, labels) do
    case Keyword.get(opts, :title) do
      title when is_binary(title) and title != "" -> esc(title)
      _ -> derived_title(labels)
    end
  end

  defp derived_title(labels) do
    names =
      labels
      |> Enum.map(&Map.get(&1, :text))
      |> Enum.filter(&(is_binary(&1) and &1 != ""))

    case Enum.split(names, @named_labels) do
      {[], _} -> "3D scene"
      {shown, []} -> esc("3D scene: " <> Enum.join(shown, ", "))
      {shown, rest} -> esc("3D scene: " <> Enum.join(shown, ", ") <> ", and #{length(rest)} more")
    end
  end

  # ── Palette and shading ─────────────────────────────────────────────────────

  defp slot(index) when is_integer(index) and index >= 0 and index <= 4 do
    elem(@palette, index)
  end

  defp slot(_out_of_range), do: elem(@palette, @fallback_slot)

  defp shade_factor(shade) when is_number(shade) do
    @shade_floor + (1.0 - @shade_floor) * clamp01(shade)
  end

  defp shade_factor(_not_a_number), do: 1.0

  defp clamp01(n) when n < 0, do: 0.0
  defp clamp01(n) when n > 1, do: 1.0
  defp clamp01(n), do: n * 1.0

  # A series colour reduced to a backdrop tone: keep @surface_chroma of the hue,
  # mix the rest toward neutral. Paired with @surface_fill_opacity at the emit
  # site — see the attribute block above for why it takes both, and why neither
  # is a sixth palette slot.
  defp mute({r, g, b}), do: {toward_grey(r), toward_grey(g), toward_grey(b)}

  defp toward_grey(value) do
    round(value * @surface_chroma + @surface_grey * (1.0 - @surface_chroma))
  end

  defp scale({r, g, b}, factor), do: {channel(r, factor), channel(g, factor), channel(b, factor)}

  defp channel(value, factor) do
    value |> Kernel.*(factor) |> round() |> min(255) |> max(0)
  end

  defp hex({r, g, b}), do: ["#", byte_hex(r), byte_hex(g), byte_hex(b)]

  defp byte_hex(value) do
    value |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(2, "0")
  end

  # ── Geometry serialization ──────────────────────────────────────────────────

  defp points(points) do
    points
    |> Enum.map(fn {x, y} -> [num(x), ",", num(y)] end)
    |> Enum.intersperse(" ")
  end

  # A zero- or negative-sized viewBox disables rendering of the element entirely
  # per spec, which looks exactly like a crash. An empty scene should be an empty
  # card, so it gets a unit box instead.
  defp viewbox({min_x, min_y, w, h}) do
    {min_x, min_y, positive(w), positive(h)}
  end

  defp positive(n) when is_number(n) and n > 0, do: n
  defp positive(_n), do: 1

  defp stroke_width(w) when is_number(w) and w > 0, do: w
  defp stroke_width(_w), do: 1

  defp label_size(w, h), do: min(w, h) * @label_scale

  # Three decimals is sub-pixel at any card size, and trimming the rest keeps the
  # document small — a tessellated sphere is a few hundred coordinate pairs, and
  # `:compact` still insists on a `.0` that SVG does not need.
  defp num(n) when is_integer(n), do: Integer.to_string(n)

  defp num(n) when is_float(n) do
    n
    |> :erlang.float_to_binary([:compact, {:decimals, 3}])
    |> String.replace_suffix(".0", "")
  end

  defp num(_n), do: "0"
end
