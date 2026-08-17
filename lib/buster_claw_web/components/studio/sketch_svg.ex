defmodule BusterClawWeb.Studio.SketchSvg do
  @moduledoc """
  The drawing surface: committed elements as SVG, plus the layer the hook draws
  the in-flight stroke into.

  `SKETCH_ROADMAP` Phase 1. SVG rather than a canvas because every element needs
  to be addressable — selecting, moving and deleting one mark are the whole point
  of the phase, and on a bitmap there is no mark to address. It also means the
  document is server-owned with the DOM as its projection, so there is no
  parallel model in JS at all, and strokes are resolution-independent for free.

  ## No `viewBox`, on purpose

  One user unit is one CSS pixel, so the server never needs to know the panel's
  size. Resizing reveals or hides paper rather than scaling what is on it, which
  keeps a stroke the size it was drawn.

  ## Nothing here is sanitised, because nothing here is markup

  Every value below comes off a `Sketch.Element`, which validated it: the colour
  matched a six-hex-digit allowlist, the width is a bounded number, the points
  are bounded floats. That is the difference between this and `SvgViewer`, which
  renders model-authored markup and has to defend itself with a sanitiser and the
  CSP behind it. Here the model will emit *data* and we draw it, so there is no
  markup of anyone else's to strip.

  Phase 3's `:text` is the one field that is not a number or an allowlisted
  colour, and it is **not** an exception: a label's content is interpolated by
  HEEx, which escapes it. The escape that had to be written by hand is in
  `BusterClaw.Sketch.Svg`, where the standalone document is built as a string
  with no template engine underneath it.
  """
  use BusterClawWeb, :html

  import BusterClaw.Sketch.Svg,
    only: [
      path_data: 1,
      num: 1,
      font_family: 0,
      text_baseline: 1,
      text_width: 1,
      text_height: 1
    ]

  # A bare stroke is a few pixels wide and nearly impossible to click. In the
  # modes where pointing at one matters, each gets an invisible companion with a
  # usable hit area. Only in those modes — it doubles the nodes.
  @hit_width 16

  # The D7 attribution tick. Small enough to read as a margin note and not as
  # part of the drawing, and big enough to see without hunting for it.
  @marker_size 4
  @marker_gap 8

  attr :elements, :list, required: true
  attr :selected, :string, default: nil
  attr :tool, :atom, required: true
  attr :target, :any, required: true
  attr :sketch, :string, required: true

  def surface(assigns) do
    ~H"""
    <%!-- `phx-target` is load-bearing, not decoration: without it every event the
          hook pushes lands on the parent LiveView, which has no clause for it and
          raises. The document lives in the component, so its events have to. --%>
    <div
      id="studio-sketch-surface"
      phx-hook="SketchPad"
      phx-target={@target}
      data-sketch-tool={@tool}
      class={[
        "relative min-h-0 flex-1 overflow-hidden bg-base-200",
        @tool == :draw && "cursor-crosshair",
        @tool == :erase && "cursor-cell",
        @tool == :select && "cursor-default",
        @tool == :text && "cursor-text"
      ]}
    >
      <svg data-sketch-svg class="block size-full touch-none">
        <g :for={element <- @elements}>
          <%!-- An image references a file in the sketch's sidecar; the bytes are
                never in the document. `href` is built from the sketch name and a
                content hash, both of which `Sketch.Assets` minted — there is no
                caller-supplied string in this URL. --%>
          <image
            :if={element.kind == :image}
            href={asset_path(@sketch, element.source)}
            x={num(element.x)}
            y={num(element.y)}
            width={num(element.w)}
            height={num(element.h)}
            preserveAspectRatio="none"
            pointer-events="none"
            class={element.id == @selected && "opacity-60"}
          />
          <path
            :if={element.kind == :stroke}
            d={path_data(element.points)}
            stroke={element.color}
            stroke-width={num(element.width)}
            fill="none"
            stroke-linecap="round"
            stroke-linejoin="round"
            pointer-events="none"
            class={element.id == @selected && "opacity-60"}
          />
          <%!-- A label. `{element.content}` is model-supplied from Phase 3 on,
                and HEEx escapes an interpolation into text content — so this is
                already safe and MUST NOT be escaped a second time, which would
                render `&amp;` where the operator typed `&`. The hand-rolled
                escape in `Sketch.Svg` exists because the standalone document is
                built as a string with no template engine under it; the two are
                not duplicates of each other.

                `y` on the element is the TOP of the label, not the baseline —
                see `text_baseline/1` for why SVG's convention was the one that
                bent.

                `phx-no-format` because the formatter puts the interpolation on
                its own indented line, which pads the label with whitespace that
                SVG then has to collapse back out. It renders the same either
                way; it does not READ the same, and a diff where a label gains
                invisible padding is one nobody can review. --%>
          <text
            :if={element.kind == :text}
            phx-no-format
            x={num(element.x)}
            y={num(text_baseline(element))}
            fill={element.color}
            font-size={num(element.size)}
            font-family={font_family()}
            pointer-events="none"
            class={element.id == @selected && "opacity-60"}
          >{element.content}</text>
          <%!-- The selection ring traces a stroke's own points rather than its
                bounding box: a freehand stroke's box is mostly empty, so a box
                would point at the wrong thing. An image IS its box, so it gets
                one — the two kinds want opposite treatment here. --%>
          <path
            :if={element.id == @selected and element.kind == :stroke}
            d={path_data(element.points)}
            stroke="currentColor"
            stroke-width={num(element.width + 6)}
            fill="none"
            stroke-linecap="round"
            stroke-linejoin="round"
            pointer-events="none"
            class="text-primary opacity-30"
          />
          <rect
            :if={element.id == @selected and element.kind == :image}
            x={num(element.x)}
            y={num(element.y)}
            width={num(element.w)}
            height={num(element.h)}
            stroke="currentColor"
            stroke-width="3"
            fill="none"
            pointer-events="none"
            class="text-primary"
          />
          <%!-- A label's box is an ESTIMATE — the server cannot measure a glyph,
                so this ring is a few pixels out on either side. That is
                acceptable for "which one is selected" and would not be for
                anything that had to line up with the text. --%>
          <rect
            :if={element.id == @selected and element.kind == :text}
            x={num(element.x)}
            y={num(element.y)}
            width={num(text_width(element))}
            height={num(text_height(element))}
            stroke="currentColor"
            stroke-width="3"
            fill="none"
            pointer-events="none"
            class="text-primary"
          />
          <%!-- D7, and it is load-bearing rather than decorative: D6 lets the
                model delete only what the model drew, and that rule reads as
                arbitrary unless you can SEE which marks are which.

                A tick BESIDE the element, never a tint ON it. Tinting model
                work would change what the drawing looks like, which is the one
                thing a drawing surface may not do to a drawing — the same
                reason the eraser stopped painting background-coloured strokes.

                Clamped off the left/top edge rather than offset blindly: there
                is no viewBox, so a negative coordinate is simply clipped and
                the marker for a mark at the origin would not exist. --%>
          <rect
            :if={element.author == :model}
            data-sketch-author="model"
            x={num(marker_x(element))}
            y={num(marker_y(element))}
            width={marker_size()}
            height={marker_size()}
            fill="currentColor"
            pointer-events="none"
            class="text-primary"
          >
            <title>Drawn by the model</title>
          </rect>
          <%!-- Hit targets. Transparent, and only present when the tool is one
                that points at things — in draw mode they would swallow the
                pointerdown that starts a stroke.

                `hit_width()`, not `@hit_width`: inside ~H a `@name` is an ASSIGN,
                so the module attribute reads as `assigns.hit_width` and raised
                KeyError on every render in a tool that shows hit targets. --%>
          <%!-- An allowlist, not `!= :draw`. Text mode places a label wherever
                it is clicked and never points at an existing element, so a hit
                target there is a node that exists to do nothing. --%>
          <path
            :if={@tool in [:erase, :select] and element.kind == :stroke}
            data-sketch-element={element.id}
            d={path_data(element.points)}
            stroke="transparent"
            stroke-width={num(max(element.width, hit_width()))}
            fill="none"
            stroke-linecap="round"
            pointer-events="stroke"
          />
          <%!-- `pointer-events="all"` with a transparent FILL, because an image
                is picked up anywhere inside it, not along its edge. --%>
          <rect
            :if={@tool in [:erase, :select] and element.kind == :image}
            data-sketch-element={element.id}
            x={num(element.x)}
            y={num(element.y)}
            width={num(element.w)}
            height={num(element.h)}
            fill="transparent"
            pointer-events="all"
          />
          <%!-- A label is picked up by its estimated box for the same reason an
                image is picked up by its own: `pointer-events` on the glyphs
                themselves would leave the counters of an `o` as holes. --%>
          <rect
            :if={@tool in [:erase, :select] and element.kind == :text}
            data-sketch-element={element.id}
            x={num(element.x)}
            y={num(element.y)}
            width={num(text_width(element))}
            height={num(text_height(element))}
            fill="transparent"
            pointer-events="all"
          />
        </g>

        <%!-- The hook's own layer. `phx-update="ignore"` is load-bearing: the
              hook rewrites this path's `d` on every pointermove, and a LiveView
              re-render between two of them would erase the stroke mid-draw. --%>
        <g id="studio-sketch-live" phx-update="ignore">
          <path
            data-sketch-live
            d=""
            fill="none"
            stroke-linecap="round"
            stroke-linejoin="round"
            pointer-events="none"
          />
        </g>
      </svg>
    </div>
    """
  end

  # `path_data/1` and `num/1` moved to `BusterClaw.Sketch.Svg` when Phase 2 needed
  # to render a sketch headlessly — a command runs with no socket, and reaching
  # into `BusterClawWeb` from a command module points the dependency the wrong
  # way. Imported rather than re-exported so the call sites in the template above
  # stay byte-identical, which is the pattern this repo already uses for
  # extractions (TradingLive, 08-02).

  @doc false
  def hit_width, do: @hit_width

  @doc false
  def marker_size, do: @marker_size

  # The attribution tick's corner, clamped so a mark drawn at the origin still
  # gets one. `anchor/1` is where the element begins rather than where its
  # centre is: for a stroke that is the first point the pen touched down on,
  # which is the part of it the eye reads as its start.
  defp marker_x(element), do: element |> anchor() |> elem(0) |> offset()
  defp marker_y(element), do: element |> anchor() |> elem(1) |> offset()

  defp offset(n), do: max(n - @marker_gap, 1.0) / 1

  defp anchor(%{kind: :stroke, points: [[x, y] | _rest]}), do: {x, y}
  defp anchor(%{x: x, y: y}) when is_number(x) and is_number(y), do: {x, y}
  defp anchor(_element), do: {0.0, 0.0}

  # Both halves of this URL were minted by `Sketch.Assets` — the sketch name
  # passed its own allowlist before the file was written, and the filename is a
  # content hash with a known extension. Nothing a caller typed reaches it.
  defp asset_path(sketch, source), do: ~p"/sketches/#{sketch}/#{source}"
end
