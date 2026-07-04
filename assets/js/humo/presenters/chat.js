// Chat presenter — authors the conversation onto an offscreen Canvas2D that
// feeds the screen's content texture (HUMO screen rewrite, Phase 0). This is a
// "content author": it owns the 2D canvas and the typography; the hook owns the
// timing (the readout state machine) and asks this to draw a page of words or
// clear. Canvas2D is the reliable substrate; the screen shader stylizes whatever
// lands here (reveal, glow, grain, lens).
//
// The pure word-wrap / page-fit math lives in text_layout.js (bun-tested); this
// module is the DOM/Canvas2D glue around it.
import {layoutPage} from "../text_layout.js"

const WIDTH = 1024
const HEIGHT = 512
const FONT = "600 14px ui-monospace, Menlo, monospace"
const LINE_H = 20
const PAD_X = 48
const PAD_Y = 48
const MAX_LINES = Math.floor((HEIGHT - PAD_Y * 2) / LINE_H)
const TEXT_MAX_W = WIDTH - PAD_X * 2

export function createChatPresenter() {
  const canvas = document.createElement("canvas")
  canvas.width = WIDTH
  canvas.height = HEIGHT
  const ctx = canvas.getContext("2d")
  let dirty = true

  const measure = (s) => {
    ctx.font = FONT
    return ctx.measureText(s).width
  }

  return {
    // The content source uploaded to the screen's content texture, and its dims.
    source: canvas,
    dims: {width: WIDTH, height: HEIGHT},

    // True when the canvas changed since the last upload; the hook uploads on
    // dirty frames only, then calls markClean().
    get dirty() {
      return dirty
    },
    markClean() {
      dirty = false
    },

    // Would `words` fit on one page? The readout machine uses this to decide
    // when to dissolve the current page and start the next.
    fits(words) {
      return layoutPage(measure, words, TEXT_MAX_W, MAX_LINES).fits
    },

    // Rasterize a page of words (white on transparent — the shader colours it).
    draw(words) {
      ctx.clearRect(0, 0, WIDTH, HEIGHT)
      ctx.font = FONT
      ctx.fillStyle = "#fff"
      const {lines} = layoutPage(measure, words, TEXT_MAX_W, MAX_LINES)
      lines.forEach((line, i) => ctx.fillText(line, PAD_X, PAD_Y + 14 + i * LINE_H))
      dirty = true
    },

    // Blank the content texture (nothing lingers under the fog).
    clear() {
      ctx.clearRect(0, 0, WIDTH, HEIGHT)
      dirty = true
    },
  }
}
