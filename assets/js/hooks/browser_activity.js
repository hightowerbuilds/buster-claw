import {BrowserActivityView} from "../lib/browser_activity_view.js"

export const BrowserActivity = {
  mounted() { this.graph = new BrowserActivityView(this.el) },
  destroyed() { this.graph.destroy() },
}
