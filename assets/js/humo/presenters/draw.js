// Draw presenter — authors a `humo-draw` composition onto an offscreen Canvas2D
// that feeds the screen's content texture (HUMO screen rewrite, Phase 4). Same
// content-author contract as the chat/diagram presenters, so a drawing condenses
// out of the smoke and glows under the post stack for free.
//
// Boolean ops map to Canvas2D compositing: union = draw on top, subtract =
// erase, intersect = keep the overlap. Everything is white on transparent (the
// shader tints alpha to ash). The sanitize/clamp/cap trust boundary is pure and
// lives in draw_ops.js.
import {sanitizeShapes} from "./draw_ops.js"

const WIDTH = 1024
const HEIGHT = 512
// World → canvas: centered, y up, scale so a circle of r=0.5 is ~half the height.
const S = HEIGHT / 2
const CX = WIDTH / 2
const CY = HEIGHT / 2
const X = (x) => CX + x * S
const Y = (y) => CY - y * S

const OP_GCO = {union: "source-over", subtract: "destination-out", intersect: "destination-in"}

function roundRect(ctx, x, y, w, h, r) {
  const rr = Math.min(r, w / 2, h / 2)
  ctx.moveTo(x + rr, y)
  ctx.arcTo(x + w, y, x + w, y + h, rr)
  ctx.arcTo(x + w, y + h, x, y + h, rr)
  ctx.arcTo(x, y + h, x, y, rr)
  ctx.arcTo(x, y, x + w, y, rr)
  ctx.closePath()
}

function polygon(ctx, cx, cy, radius, sides, rot) {
  for (let i = 0; i < sides; i++) {
    const a = rot + (i * 2 * Math.PI) / sides
    const px = cx + Math.cos(a) * radius
    const py = cy + Math.sin(a) * radius
    if (i === 0) ctx.moveTo(px, py)
    else ctx.lineTo(px, py)
  }
  ctx.closePath()
}

function star(ctx, cx, cy, outer, inner, points) {
  for (let i = 0; i < points * 2; i++) {
    const a = -Math.PI / 2 + (i * Math.PI) / points
    const rad = i % 2 === 0 ? outer : inner
    const px = cx + Math.cos(a) * rad
    const py = cy + Math.sin(a) * rad
    if (i === 0) ctx.moveTo(px, py)
    else ctx.lineTo(px, py)
  }
  ctx.closePath()
}

function tracePath(ctx, s) {
  switch (s.kind) {
    case "circle":
      ctx.arc(X(s.x), Y(s.y), s.r * S, 0, Math.PI * 2)
      break
    case "box":
      ctx.rect(X(s.x) - s.w * S, Y(s.y) - s.h * S, s.w * 2 * S, s.h * 2 * S)
      break
    case "roundbox":
      roundRect(ctx, X(s.x) - s.w * S, Y(s.y) - s.h * S, s.w * 2 * S, s.h * 2 * S, s.radius * S)
      break
    case "triangle":
      ctx.moveTo(X(s.x1), Y(s.y1))
      ctx.lineTo(X(s.x2), Y(s.y2))
      ctx.lineTo(X(s.x3), Y(s.y3))
      ctx.closePath()
      break
    case "hexagon":
      polygon(ctx, X(s.x), Y(s.y), s.r * S, 6, -Math.PI / 2)
      break
    case "star":
      star(ctx, X(s.x), Y(s.y), s.r * S, s.r * S * s.inner, 5)
      break
  }
}

export function createDrawPresenter() {
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

    draw(shapes) {
      const {shapes: list} = sanitizeShapes(shapes)
      ctx.clearRect(0, 0, WIDTH, HEIGHT)
      ctx.fillStyle = "#fff"
      ctx.strokeStyle = "#fff"

      for (const s of list) {
        ctx.globalCompositeOperation = OP_GCO[s.op] || "source-over"
        if (s.kind === "segment") {
          ctx.lineWidth = Math.max(1, s.th * 2 * S)
          ctx.lineCap = "round"
          ctx.beginPath()
          ctx.moveTo(X(s.x1), Y(s.y1))
          ctx.lineTo(X(s.x2), Y(s.y2))
          ctx.stroke()
        } else {
          ctx.beginPath()
          tracePath(ctx, s)
          ctx.fill()
        }
      }
      ctx.globalCompositeOperation = "source-over"
      dirty = true
    },

    clear() {
      ctx.clearRect(0, 0, WIDTH, HEIGHT)
      dirty = true
    },
  }
}
