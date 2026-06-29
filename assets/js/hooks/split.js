import {SPLIT_RATIO_KEY} from "../lib/tabs.js"

// Resizable + swappable joined view (/split). The grabbable divider sets the
// left pane's width via the `--split-left` CSS var (persisted in localStorage);
// the swap button flips the two sides by reusing the tab strip's swapSides.
export const SplitResizer = {
  mounted() {
    this.applyStoredRatio()
    this.onPointerDown = (e) => this.startDrag(e)
    this.onClick = (e) => this.handleClick(e)
    this.el.addEventListener("pointerdown", this.onPointerDown)
    this.el.addEventListener("click", this.onClick)
  },
  updated() {
    // A server re-render rewrites the style attr; re-apply the saved width.
    if (!this.dragging) this.applyStoredRatio()
  },
  destroyed() {
    this.el.removeEventListener("pointerdown", this.onPointerDown)
    this.el.removeEventListener("click", this.onClick)
    this.endDrag()
  },
  storedRatio() {
    const raw = parseFloat(localStorage.getItem(SPLIT_RATIO_KEY))
    return isFinite(raw) ? Math.min(0.85, Math.max(0.15, raw)) : 0.5
  },
  applyStoredRatio() {
    this.setRatio(this.storedRatio())
  },
  setRatio(ratio) {
    this.el.style.setProperty("--split-left", `${(ratio * 100).toFixed(2)}%`)
  },
  handleClick(e) {
    if (e.target.closest("[data-split-swap]")) {
      e.preventDefault()
      window.dispatchEvent(new CustomEvent("bc:swap-split"))
      return
    }
    const close = e.target.closest("[data-split-close]")
    if (close) {
      e.preventDefault()
      window.dispatchEvent(
        new CustomEvent("bc:close-split-pane", {detail: {side: close.getAttribute("data-split-close")}})
      )
    }
  },
  startDrag(e) {
    const onDivider = e.target.closest("[data-split-divider]")
    if (!onDivider || e.target.closest("[data-split-swap]")) return
    e.preventDefault()
    this.dragging = true
    document.body.style.userSelect = "none"
    document.body.style.cursor = "col-resize"
    this.onMove = (ev) => this.drag(ev)
    this.onUp = () => this.endDrag()
    window.addEventListener("pointermove", this.onMove)
    window.addEventListener("pointerup", this.onUp)
  },
  drag(e) {
    if (!this.dragging) return
    const rect = this.el.getBoundingClientRect()
    if (rect.width <= 0) return
    this.ratio = Math.min(0.85, Math.max(0.15, (e.clientX - rect.left) / rect.width))
    this.setRatio(this.ratio)
  },
  endDrag() {
    if (this.onMove) window.removeEventListener("pointermove", this.onMove)
    if (this.onUp) window.removeEventListener("pointerup", this.onUp)
    this.onMove = this.onUp = null
    if (this.dragging) {
      document.body.style.userSelect = ""
      document.body.style.cursor = ""
      if (typeof this.ratio === "number") {
        localStorage.setItem(SPLIT_RATIO_KEY, String(this.ratio))
      }
    }
    this.dragging = false
  }
}
