import {browserAppTab, knownBrowserSurfaces} from "../lib/tabs.js"
import {browserSurfaces, planTabLayout, tabSnapshot} from "../lib/tab_layout.js"

export const TabLayout = {
  setupTabCommands() {
    this.handleEvent("bc:app_tabs", request => this.onTabRequest(request))
    this.onTabsFocus = () => this.pushEvent("bc:tabs_ready", {})
    window.addEventListener("focus", this.onTabsFocus)
    this.onTabsFocus()
  },
  layoutPlan(action, args) {
    return planTabLayout(action, args, this.load(), this.currentKey(), {
      labels: this.labels,
      joinable: JSON.parse(this.el.dataset.joinable || "[]"),
      browserOwner: browserAppTab("main")
    })
  },
  async onTabRequest({ref, action, args, expires_at}) {
    let result, plan, before
    try {
      if (expires_at && Date.now() >= expires_at) throw new Error("The tab request expired. Try again.")
      if (action === "list") result = {value: tabSnapshot(this.load(), this.currentKey())}
      else {
        plan = this.layoutPlan(action, args)
        before = this.load()
        this.save(plan.tabs)
        result = {value: {...tabSnapshot(plan.tabs, plan.path), changed: plan.changed}}
      }
    } catch (error) {
      plan = undefined
      result = {error: error.message}
    }
    // Wait for the acknowledgement before leaving this LiveView; otherwise
    // navigating can discard the result and make a successful command time out.
    this.pushEvent("bc:tabs_result", {ref, result}, reply => {
      if (!reply.accepted && plan && before && JSON.stringify(this.load()) === JSON.stringify(plan.tabs)) this.save(before)
      if (reply.accepted && plan && plan.path !== this.currentKey()) this.navigateLayout(plan.path)
    })
  },
  applyLayout(action, args) {
    try {
      const plan = this.layoutPlan(action, args)
      this.save(plan.tabs)
      return this.navigateLayout(plan.path)
    } catch (error) {
      this.pushEvent("bc:tabs_notice", {error: error.message})
    }
  },
  joinTabs(a, b) { return this.applyLayout("join", {with: a, tab: b}) },
  separateTabs(tab) { return this.applyLayout("separate", {tab}) },
  swapSides(tab) { return this.applyLayout("swap", {tab}) },
  closeSplitPane(side) { return this.applyLayout("close-pane", {side}) },
  async navigateLayout(path) {
    const invoke = window.__TAURI__?.core?.invoke
    if (invoke) {
      await Promise.all(knownBrowserSurfaces().map(surfaceId => invoke("browser_hide", {surfaceId}).catch(() => {})))
    }
    window.location.href = path
  },
  // Only tab deletion destroys a browser; layout changes merely reposition it.
  tearDownSplitBrowsers(...paths) {
    const invoke = window.__TAURI__?.core?.invoke
    if (!invoke) return Promise.resolve()
    const surfaces = [...new Set(paths.filter(Boolean).flatMap(browserSurfaces))]
    return Promise.all(surfaces.map(surfaceId => invoke("browser_close", {surfaceId}).catch(() => {})))
  },
  reconcileBrowserSurfaces() {
    const invoke = window.__TAURI__?.core?.invoke
    if (!invoke) return
    const shown = new Set(browserSurfaces(window.location.pathname + window.location.search))
    for (const surfaceId of knownBrowserSurfaces()) {
      if (!shown.has(surfaceId)) invoke("browser_hide", {surfaceId}).catch(() => {})
    }
  }
}
