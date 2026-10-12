import {createOlympus} from "../olympus/scene.js"

export const Olympus = {
  mounted() {
    try {
      this.disposeScene = createOlympus(this.el)
    } catch (error) {
      this.el.dataset.state = "error"
      this.el.querySelector("[data-status]").textContent = "Unable to start the 3D scene. Enable hardware acceleration and reload."
      console.error("Olympus renderer:", error)
    }
  },
  destroyed() { this.disposeScene?.() },
}
