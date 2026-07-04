// Sizes the SVG-viewer dock to match the chat panel's (resizable) height, so its
// cards scroll inside the panel instead of growing the whole page. Follows the
// chat as it's dragged (ResizeObserver) and on window resize.
export const SvgViewerDock = {
  mounted() {
    this.chat = document.getElementById("home-agent-chat")
    this.sync = () => {
      if (this.chat) this.el.style.height = this.chat.offsetHeight + "px"
    }
    this.sync()
    if (this.chat && "ResizeObserver" in window) {
      this.ro = new ResizeObserver(() => this.sync())
      this.ro.observe(this.chat)
    }
    this.onResize = () => this.sync()
    window.addEventListener("resize", this.onResize)
  },
  updated() {
    this.sync()
  },
  destroyed() {
    this.ro?.disconnect()
    window.removeEventListener("resize", this.onResize)
  },
}
