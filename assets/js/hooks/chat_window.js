// A floating chat window: drag by its title bar, resize from its corner, and
// come back where you left it. Geometry lives in localStorage keyed by the
// conversation, because a window that forgets where it was is a window the user
// has to re-place every single visit.
//
// Deliberately NOT the AgentChat hook. That one registers a window-level Escape
// listener and pushes a conversation-less `cut_run`, which is correct when there
// is exactly one chat on the page and wrong the moment there are several — every
// mounted instance would answer the same keypress. Everything here is scoped to
// this element and every event it pushes names its conversation.

const MIN_W = 300
const MIN_H = 220
const MARGIN = 8

const keyFor = (conv) => `bc:trading-chat-window:${conv}`

export const ChatWindow = {
  mounted() {
    this.conv = this.el.dataset.conv
    this.log = this.el.querySelector("[data-chat-log]")
    this.input = this.el.querySelector("[data-chat-input]")
    this.form = this.el.querySelector("[data-chat-form]")

    this.applyStoredGeometry()
    this.scrollToBottom()

    // Enter/Shift+Enter/chord handling lives in the `Composer` hook on the form
    // itself, shared with Home's panel — see assets/js/lib/compose_keys.js.

    // Escape stops THIS window's run, and only while it is the focused one —
    // otherwise a single keypress would cut every in-flight conversation.
    this.onEscape = (e) => {
      if (e.key !== "Escape") return
      if (this.el.dataset.running !== "true") return
      if (!this.el.contains(document.activeElement)) return
      e.preventDefault()
      this.pushEvent("cut_run", {conv: this.conv})
    }

    window.addEventListener("keydown", this.onEscape)

    this.bindDrag()
    this.bindResize()
  },

  updated() {
    // A server patch rewrites the style attribute; put the geometry back or the
    // window jumps to its default position on every message.
    if (!this.dragging && !this.resizing) this.applyStoredGeometry()
    this.scrollToBottom()
  },

  destroyed() {
    window.removeEventListener("keydown", this.onEscape)
    this.endDrag()
    this.endResize()
  },

  // --- geometry ---

  storedGeometry() {
    try {
      const raw = localStorage.getItem(keyFor(this.conv))
      if (!raw) return null
      const g = JSON.parse(raw)
      return typeof g === "object" && g ? g : null
    } catch (_e) {
      return null
    }
  },

  storeGeometry(g) {
    try {
      localStorage.setItem(keyFor(this.conv), JSON.stringify(g))
    } catch (_e) {
      // A full or disabled localStorage costs the user their layout, not their
      // chat. Never let it take the window down with it.
    }
  },

  docked() {
    return this.el.dataset.docked === "true"
  },

  applyStoredGeometry() {
    // A docked chat is sized by the tab it fills. Writing left/top/width onto it
    // would drag it back out of the flow and pin it over its own panel.
    if (this.docked()) return

    const g = this.storedGeometry() || this.defaultGeometry()
    const clamped = this.clamp(g)
    this.el.style.left = clamped.x + "px"
    this.el.style.top = clamped.y + "px"
    this.el.style.width = clamped.w + "px"
    // A minimised window is title-bar height only; leaving an explicit height on
    // it would hold the collapsed bar open at full size.
    this.el.style.height = this.minimized() ? "" : clamped.h + "px"
  },

  minimized() {
    return this.el.dataset.minimized === "true"
  },

  // The box this window may move in, and where that box starts in client coords.
  //
  // A `fixed` window has no `offsetParent` — the spec returns null for fixed
  // position — so the viewport answer is self-selecting and the normal Trading
  // tab keeps exactly the geometry it had. Joined into a split pane the window
  // renders `absolute` (see `ChatPanel.float_class/1`) and `offsetParent`
  // becomes `#trading-root`, so it clamps to its own half instead of sailing
  // over the neighbouring pane.
  frame() {
    const parent = this.el.offsetParent
    if (parent && parent !== document.body) {
      const r = parent.getBoundingClientRect()
      return {ox: r.left, oy: r.top, w: r.width, h: r.height}
    }
    return {ox: 0, oy: 0, w: window.innerWidth, h: window.innerHeight}
  },

  // Cascade successive windows so a second one does not land exactly on top of
  // the first. Index comes from the server's render order.
  defaultGeometry() {
    const i = parseInt(this.el.dataset.index, 10) || 0
    const f = this.frame()
    const w = Math.min(420, Math.max(MIN_W, f.w - 2 * MARGIN))
    const h = Math.min(520, Math.max(MIN_H, f.h - 160))
    return {
      x: Math.max(MARGIN, f.w - w - MARGIN - i * 28),
      y: Math.max(MARGIN, f.h - h - MARGIN - i * 28),
      w,
      h,
    }
  },

  clamp(g) {
    const f = this.frame()
    const w = Math.max(MIN_W, Math.min(g.w || MIN_W, f.w - 2 * MARGIN))
    const h = Math.max(MIN_H, Math.min(g.h || MIN_H, f.h - 2 * MARGIN))
    // Keep at least the title bar reachable: a window dragged off-screen and
    // then persisted there would be unrecoverable without clearing storage.
    const x = Math.max(MARGIN - w + 80, Math.min(g.x ?? MARGIN, f.w - 80))
    const y = Math.max(MARGIN, Math.min(g.y ?? MARGIN, f.h - 40))
    return {x, y, w, h}
  },

  currentGeometry() {
    return {
      x: parseInt(this.el.style.left, 10) || 0,
      y: parseInt(this.el.style.top, 10) || 0,
      w: parseInt(this.el.style.width, 10) || MIN_W,
      h: parseInt(this.el.style.height, 10) || MIN_H,
    }
  },

  // --- drag ---

  bindDrag() {
    this.handle = this.el.querySelector("[data-window-drag]")
    if (!this.handle) return

    this.onDragDown = (e) => {
      // Ignore the title bar's own buttons (minimise/close).
      if (e.target.closest("button")) return
      e.preventDefault()
      const g = this.currentGeometry()
      // `left`/`top` are relative to the frame, the pointer is in client coords —
      // the same numbers only while the frame IS the viewport.
      const f = this.frame()
      this.dragging = {dx: e.clientX - f.ox - g.x, dy: e.clientY - f.oy - g.y}
      window.addEventListener("pointermove", this.onDragMove)
      window.addEventListener("pointerup", this.onDragUp)
      document.body.style.userSelect = "none"
    }
    this.onDragMove = (e) => {
      const f = this.frame()
      const g = this.clamp({
        ...this.currentGeometry(),
        x: e.clientX - f.ox - this.dragging.dx,
        y: e.clientY - f.oy - this.dragging.dy,
      })
      this.el.style.left = g.x + "px"
      this.el.style.top = g.y + "px"
      this.highlightDropzone(this.overDropzone(e))
    }
    this.onDragUp = (e) => {
      const dropping = this.overDropzone(e)
      this.highlightDropzone(false)

      if (dropping) {
        // Dock: hand the conversation to the tab bar. Geometry is still stored
        // first, so floating it again puts the window back where it was rather
        // than in the default corner.
        this.storeGeometry(this.currentGeometry())
        this.pushEvent("trading_dock_chat", {id: this.conv})
      } else {
        this.storeGeometry(this.currentGeometry())
      }

      this.endDrag()
    }

    this.handle.addEventListener("pointerdown", this.onDragDown)
  },

  // The tab bar is the drop target. Hit-tested by pointer position rather than
  // HTML5 drag-and-drop: this is a pointer-driven window drag, and mixing the
  // two APIs would mean two different drag models on the same element.
  dropzone() {
    return document.querySelector("[data-tab-dropzone]")
  },

  overDropzone(e) {
    const zone = this.dropzone()
    if (!zone || !e) return false
    const r = zone.getBoundingClientRect()
    return e.clientX >= r.left && e.clientX <= r.right && e.clientY >= r.top && e.clientY <= r.bottom
  },

  highlightDropzone(on) {
    const zone = this.dropzone()
    if (!zone) return
    // NOT `bc-dropzone-active` — the workspace file dropzone already owns that
    // name, and reusing it would light that surface up during a chat drag.
    zone.classList.toggle("bc-tab-dropzone-active", !!on)
  },

  endDrag() {
    this.dragging = null
    this.highlightDropzone(false)
    window.removeEventListener("pointermove", this.onDragMove)
    window.removeEventListener("pointerup", this.onDragUp)
    document.body.style.userSelect = ""
  },

  // --- resize ---

  bindResize() {
    this.grip = this.el.querySelector("[data-window-resize]")
    if (!this.grip) return

    this.onResizeDown = (e) => {
      e.preventDefault()
      e.stopPropagation()
      const g = this.currentGeometry()
      this.resizing = {x: e.clientX, y: e.clientY, w: g.w, h: g.h}
      window.addEventListener("pointermove", this.onResizeMove)
      window.addEventListener("pointerup", this.onResizeUp)
      document.body.style.userSelect = "none"
    }
    this.onResizeMove = (e) => {
      const g = this.clamp({
        ...this.currentGeometry(),
        w: this.resizing.w + (e.clientX - this.resizing.x),
        h: this.resizing.h + (e.clientY - this.resizing.y),
      })
      this.el.style.width = g.w + "px"
      this.el.style.height = g.h + "px"
    }
    this.onResizeUp = () => {
      this.storeGeometry(this.currentGeometry())
      this.endResize()
    }

    this.grip.addEventListener("pointerdown", this.onResizeDown)
  },

  endResize() {
    this.resizing = null
    window.removeEventListener("pointermove", this.onResizeMove)
    window.removeEventListener("pointerup", this.onResizeUp)
    document.body.style.userSelect = ""
  },

  scrollToBottom() {
    if (this.log) this.log.scrollTop = this.log.scrollHeight
  },
}
