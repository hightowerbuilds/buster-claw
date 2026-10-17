import {layoutDots, readLayout, leavesOf} from "../lib/workbench.js"
import {requestNewTerminal} from "../lib/tabs.js"

export const WorkbenchMenu = {
  mounted() {
    this.root = null
    this.onClick = event => {
      const mode = event.target.closest("[data-workbench-mode]")
      if (mode && !mode.disabled) {
        window.dispatchEvent(new CustomEvent("bc:workbench-mode", {detail: {mode: mode.dataset.workbenchMode}}))
        return
      }
      if (event.target.closest("[data-workbench-reset]")) {
        window.dispatchEvent(new CustomEvent("bc:workbench-reset"))
        return
      }
      const layout = event.target.closest("[data-workbench-layout]")
      if (layout && !layout.disabled && document.querySelector("#workbench-controller")) {
        window.dispatchEvent(new CustomEvent("bc:workbench-layout", {detail: {preset: layout.dataset.workbenchLayout}}))
        return
      }
      if (event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return
      // Terminal always creates (TERMINAL_PANELS D3) — here or on arrival.
      if (event.target.closest("[data-workbench-terminal-new]")) {
        event.preventDefault()
        event.stopImmediatePropagation()
        requestNewTerminal()
        return
      }
      const link = event.target.closest("[data-workbench-open]")
      if (!link || !document.querySelector("#workbench-controller")) return
      event.preventDefault()
      event.stopImmediatePropagation()
      window.dispatchEvent(new CustomEvent("bc:workbench-open", {detail: {key: link.dataset.workbenchOpen}}))
    }
    this.onState = event => {this.state = event.detail; this.bindRoot(); this.paint()}
    this.onNavigate = () => {this.bindRoot(); this.paint()}
    this.onNarrow = event => {
      this.narrow = event.detail
      this.root?.querySelector("[data-workbench-narrow-hint]")?.toggleAttribute("hidden", !(this.narrow && this.state?.mode === "overlap"))
    }
    window.addEventListener("bc:workbench-narrow", this.onNarrow)
    // A click at the limit: the server refused, the button says so for a beat.
    this.onLimit = () => {
      const button = this.root?.querySelector("[data-workbench-terminal-new]")
      if (!button) return
      button.classList.remove("is-refused")
      void button.offsetWidth
      button.classList.add("is-refused")
    }
    this.bindRoot()
    window.addEventListener("bc:workbench-state", this.onState)
    window.addEventListener("bc:workbench-limit", this.onLimit)
    window.addEventListener("phx:page-loading-stop", this.onNavigate)
    try { this.state = readLayout(window.localStorage) } catch { this.state = null }
    this.paint()
  },
  bindRoot() {
    // The menu is sticky, but the surrounding layout (including the picker)
    // is replaced on navigation. Listen on its current sidebar each time.
    const root = this.el.closest("#app-sidebar")
    if (!root) return
    if (root !== this.root) {
      this.root?.removeEventListener("click", this.onClick, true)
      this.root = root
      this.root.addEventListener("click", this.onClick, true)
      this.defaultLayouts = JSON.parse(this.root.querySelector("#workbench-layout-picker").dataset.layouts)
    }
  },
  paint() {
    if (!this.root?.isConnected) return
    const onWorkArea = Boolean(document.querySelector("#workbench-controller"))
    const open = new Set(leavesOf(this.state?.tree))
    const allOpen = new Set((this.state?.areas || []).flatMap(area => leavesOf(area.tree)))
    const overlap = this.state?.mode === "overlap"
    for (const button of this.root.querySelectorAll("[data-workbench-mode]")) {
      button.disabled = !onWorkArea
      button.setAttribute("aria-pressed", String(onWorkArea && button.dataset.workbenchMode === (this.state?.mode || "grid")))
    }
    this.root.querySelector("[data-workbench-presets]").hidden = overlap
    this.root.querySelector("[data-workbench-reset]").hidden = !onWorkArea || !overlap
    this.root.querySelector("[data-workbench-narrow-hint]").hidden = !(onWorkArea && overlap && this.narrow)
    for (const link of this.root.querySelectorAll("[data-workbench-open]")) {
      const key = link.dataset.workbenchOpen
      link.dataset.active = String(onWorkArea && this.state?.active === key)
      link.querySelector(".ic-workbench-open-dot").hidden = !(allOpen.has(key) || open.has(key))
    }
    const terminal = this.root.querySelector("[data-workbench-terminal-new]")
    if (terminal) {
      const count = Number(this.state?.terminal_count) || 0
      const badge = terminal.querySelector("[data-workbench-terminal-count]")
      badge.textContent = String(count)
      badge.hidden = count === 0
      terminal.title = onWorkArea && open.size >= 4 ? "Open a terminal in a new Work Area" : "Open a terminal"

    }
    this.root.querySelector("#workbench-browser").dataset.active = String(location.pathname === "/browse")
    this.root.querySelector("#workbench-settings").dataset.active = String(["/appearance", "/settings", "/notify-settings", "/security"].includes(location.pathname))
    for (const layout of this.state?.layouts || this.defaultLayouts) {
      const button = this.root.querySelector(`#workbench-layout-${layout.key}`)
      button.disabled = !onWorkArea || !layout.enabled
      button.setAttribute("aria-pressed", String(onWorkArea && this.state?.preset === layout.key && layout.enabled))
      button.title = !onWorkArea ? "Open a panel to arrange your work area"
        : !layout.enabled ? `${layout.label} — ${layout.hint}`
        : `${layout.label} — ${open.size} panels`
      const dots = layoutDots(layout.tree).map(point => {
        const dot = document.createElement("span")
        dot.style.left = `${point.x}%`
        dot.style.top = `${point.y}%`
        return dot
      })
      button.querySelector(".ic-workbench-layout-dots").replaceChildren(...dots)
    }
  },
  destroyed() {
    this.root.removeEventListener("click", this.onClick, true)
    window.removeEventListener("bc:workbench-state", this.onState)
    window.removeEventListener("bc:workbench-narrow", this.onNarrow)
    window.removeEventListener("bc:workbench-limit", this.onLimit)
    window.removeEventListener("phx:page-loading-stop", this.onNavigate)
  },
}
