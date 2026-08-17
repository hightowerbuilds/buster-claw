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
  """
  use BusterClawWeb, :html

  # A bare stroke is a few pixels wide and nearly impossible to click. In the
  # modes where pointing at one matters, each gets an invisible companion with a
  # usable hit area. Only in those modes — it doubles the nodes.
  @hit_width 16

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
        @tool == :select && "cursor-default"
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
          <%!-- Hit targets. Transparent, and only present when the tool is one
                that points at things — in draw mode they would swallow the
                pointerdown that starts a stroke.

                `hit_width()`, not `@hit_width`: inside ~H a `@name` is an ASSIGN,
                so the module attribute reads as `assigns.hit_width` and raised
                KeyError on every render in a tool that shows hit targets. --%>
          <path
            :if={@tool != :draw and element.kind == :stroke}
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
            :if={@tool != :draw and element.kind == :image}
            data-sketch-element={element.id}
            x={num(element.x)}
            y={num(element.y)}
            width={num(element.w)}
            height={num(element.h)}
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

  @doc """
  Points to an SVG path.

  **Must agree byte-for-byte with `pathData` in `assets/js/lib/sketch.js`.** The
  hook draws a stroke while it is being made and this draws it the instant it
  commits; a disagreement is not a rendering bug, it is a visible jump at the end
  of every stroke. Both are tested against the same cases.
  """
  def path_data([]), do: ""

  # A tap with no movement is a dot, not nothing — a zero-length path does not
  # render even with a round linecap.
  def path_data([[x, y]]), do: "M #{num(x)} #{num(y)} L #{num(x)} #{num(y)}"

  def path_data([[x, y] | rest]) do
    "M #{num(x)} #{num(y)} " <>
      Enum.map_join(rest, " ", fn [px, py] -> "L #{num(px)} #{num(py)}" end)
  end

  def path_data(_points), do: ""

  # Elements store floats, so a whole number is `0.0` here and `0` in JavaScript.
  # Printing it as `0.0` would be a valid path and a mismatched string, which is
  # exactly the drift the agreement test exists to catch.
  defp num(n) when is_float(n) do
    if n == Float.round(n),
      do: Integer.to_string(trunc(n)),
      else: :erlang.float_to_binary(n, [:short])
  end

  defp num(n) when is_integer(n), do: Integer.to_string(n)

  @doc false
  def hit_width, do: @hit_width

  # Both halves of this URL were minted by `Sketch.Assets` — the sketch name
  # passed its own allowlist before the file was written, and the filename is a
  # content hash with a known extension. Nothing a caller typed reaches it.
  defp asset_path(sketch, source), do: ~p"/sketches/#{sketch}/#{source}"
end
