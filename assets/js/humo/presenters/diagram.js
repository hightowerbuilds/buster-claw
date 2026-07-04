// Diagram presenter — authors a `humo-graph` onto an offscreen Canvas2D that
// feeds the screen's content texture (HUMO screen rewrite, Phase 2/3). Same
// content-author contract as the chat presenter (source / dims / dirty /
// markClean / clear), so the screen composites and stylizes it identically — a
// diagram condenses out of the smoke and glows under the post stack, for free.
//
// The layout + trust-bounding is pure and lives in diagram_layout.js; this
// module is just the Canvas2D drawing. Shapes are stroked white on transparent
// (the shader reads alpha and tints it ash), so the glow haloes every box.
import {layoutGraph} from "./diagram_layout.js"

const WIDTH = 1024
const HEIGHT = 512
const LABEL_FONT = "600 15px ui-monospace, Menlo, monospace"

function roundRect(ctx, x, y, w, h, r) {
  ctx.beginPath()
  ctx.moveTo(x + r, y)
  ctx.arcTo(x + w, y, x + w, y + h, r)
  ctx.arcTo(x + w, y + h, x, y + h, r)
  ctx.arcTo(x, y + h, x, y, r)
  ctx.arcTo(x, y, x + w, y, r)
  ctx.closePath()
}

export function createDiagramPresenter() {
  const canvas = document.createElement("canvas")
  canvas.width = WIDTH
  canvas.height = HEIGHT
  const ctx = canvas.getContext("2d")
  let dirty = true

  return {
    source: canvas,
    dims: {width: WIDTH, height: HEIGHT},

    get dirty() {
      return dirty
    },
    markClean() {
      dirty = false
    },

    // Rasterize a graph spec. White strokes/labels on transparent; the screen
    // shader colours and haloes them.
    draw(spec) {
      const {nodes, edges} = layoutGraph(spec, {width: WIDTH, height: HEIGHT})
      ctx.clearRect(0, 0, WIDTH, HEIGHT)

      // Edges first, so boxes sit on top of the line ends.
      ctx.strokeStyle = "rgba(255,255,255,0.5)"
      ctx.lineWidth = 1.5
      for (const e of edges) {
        ctx.beginPath()
        ctx.moveTo(e.x1, e.y1)
        ctx.lineTo(e.x2, e.y2)
        ctx.stroke()
      }

      // Boxes + centered labels.
      ctx.font = LABEL_FONT
      ctx.textAlign = "center"
      ctx.textBaseline = "middle"
      for (const n of nodes) {
        const x = n.cx - n.w / 2
        const y = n.cy - n.h / 2
        roundRect(ctx, x, y, n.w, n.h, 6)
        ctx.strokeStyle = "#fff"
        ctx.lineWidth = 2
        ctx.stroke()
        ctx.fillStyle = "#fff"
        ctx.fillText(n.label, n.cx, n.cy + 1)
      }

      dirty = true
    },

    clear() {
      ctx.clearRect(0, 0, WIDTH, HEIGHT)
      dirty = true
    },
  }
}
