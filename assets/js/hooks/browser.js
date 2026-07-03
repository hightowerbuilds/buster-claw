// Always-mounted bridge (layout header). When the agent requests a screenshot,
// Phoenix pushes "bc:screenshot_request"; we invoke the Tauri browser_screenshot
// command for the active tab and POST the PNG (base64) back to /browser/screenshot,
// correlated by ref. Outside the desktop app there's no Tauri → report an error so
// the waiting command fails fast instead of timing out.
export const ScreenshotBridge = {
  mounted() {
    this.handleEvent("bc:screenshot_request", async ({ref}) => {
      const invoke = window.__TAURI__?.core?.invoke
      if (!invoke) {
        this.report(ref, {error: "desktop app required for screenshots"})
        return
      }
      try {
        const shot = await invoke("browser_screenshot")
        this.report(ref, {url: shot.url, data: shot.data})
      } catch (e) {
        this.report(ref, {error: String(e).slice(0, 200)})
      }
    })
    // Agent co-presence: read/drive the live browser tab. The server pushes
    // "bc:browser_command" with {ref, action, payload}; we invoke the matching
    // Tauri command and POST the result back to /browser/command.
    this.handleEvent("bc:browser_command", async ({ref, action, payload}) => {
      const invoke = window.__TAURI__?.core?.invoke
      if (!invoke) {
        this.reportCommand(ref, {error: "desktop app required for browser commands"})
        return
      }
      try {
        let data = {ok: true}
        if (action === "current") {
          const cur = await invoke("browser_current")
          data = {ok: true, url: cur.url, title: cur.title}
        } else if (action === "navigate") {
          await invoke("browser_navigate_active", {url: payload.url})
        } else if (action === "open_tab") {
          await invoke("browser_open_tab_active", {url: payload.url})
        } else {
          this.reportCommand(ref, {error: "unknown browser command"})
          return
        }
        this.reportCommand(ref, data)
      } catch (e) {
        this.reportCommand(ref, {error: String(e).slice(0, 200)})
      }
    })
  },
  report(ref, payload) {
    fetch("/browser/screenshot", {
      method: "POST",
      headers: {"content-type": "application/json"},
      body: JSON.stringify({ref, ...payload}),
    }).catch(() => {})
  },
  reportCommand(ref, payload) {
    fetch("/browser/command", {
      method: "POST",
      headers: {"content-type": "application/json"},
      body: JSON.stringify({ref, ...payload}),
    }).catch(() => {})
  },
}

// Positions the embedded browser's two native child webviews (chrome toolbar +
// content) over the /browse surface. The toolbar lives in the native chrome
// webview, so it's never covered. Only active in the desktop app
// (window.__TAURI__); a plain browser shows the fallback notice.
export const EmbeddedBrowser = {
  mounted() {
    this.invoke = window.__TAURI__?.core?.invoke || null
    this.surface = this.el.querySelector("[data-browser-surface]")
    this.fallback = this.el.querySelector("[data-browser-fallback]")
    this.origin = window.location.origin
    this.opened = false
    // Browser surface id: "main" for the solo /browse, "left"/"right" for the
    // two panes of a browser+browser split. Keeps the native surfaces (and
    // their chromes) independent so two browsers can sit side by side.
    this.sid = this.el.dataset.surfaceId || "main"

    if (!this.invoke) {
      if (this.fallback) {
        this.fallback.classList.remove("hidden")
        this.fallback.classList.add("grid")
      }
      return
    }

    const initial = (this.el.dataset.initialUrl || "").trim()
    this.chromeUrl =
      `${this.origin}/browser/chrome?sid=${encodeURIComponent(this.sid)}` +
      (initial ? `&url=${encodeURIComponent(initial)}` : "")
    this.contentUrl = this.resolveContent(initial)

    // Keep both native webviews glued to the surface box. Tauri on macOS can
    // position child webviews relative to the window frame (incl. title bar)
    // rather than the content area, so correct by the chrome height (outer−inner).
    this.sync = () => {
      if (!this.surface) return
      const r = this.surface.getBoundingClientRect()
      const offY = Math.max(0, window.outerHeight - window.innerHeight)
      const offX = Math.max(0, Math.round((window.outerWidth - window.innerWidth) / 2))
      const bounds = {
        x: Math.round(r.left) + offX,
        y: Math.round(r.top) + offY,
        width: Math.round(r.width),
        height: Math.round(r.height)
      }
      if (bounds.width <= 0 || bounds.height <= 0) return
      if (!this.opened) {
        this.opened = true
        this.invoke("browser_open", {
          surfaceId: this.sid,
          chromeUrl: this.chromeUrl,
          contentUrl: this.contentUrl,
          ...bounds
        }).catch(() => {})
      } else {
        this.invoke("browser_set_bounds", { surfaceId: this.sid, ...bounds }).catch(() => {})
      }
    }
    this.scheduleSync = () => {
      if (this.raf) cancelAnimationFrame(this.raf)
      this.raf = requestAnimationFrame(() => this.sync())
    }

    this.ro = new ResizeObserver(() => this.scheduleSync())
    if (this.surface) this.ro.observe(this.surface)
    this.onResize = () => this.scheduleSync()
    this.onScroll = () => this.scheduleSync()
    window.addEventListener("resize", this.onResize)
    window.addEventListener("scroll", this.onScroll, true)
    this.scheduleSync()
    this.settle = setTimeout(() => this.scheduleSync(), 250)
  },

  // Initial content URL: scheme kept, absolute workspace path → /ws/file,
  // bare domain → https://, empty → the browser homepage (recent URLs).
  resolveContent(raw) {
    const v = (raw || "").trim()
    if (v === "") return `${this.origin}/browser/home`
    if (/^[a-z]+:\/\//i.test(v)) return v
    if (v.startsWith("/")) return `${this.origin}/ws/file?path=${encodeURIComponent(v)}`
    return `https://${v}`
  },

  destroyed() {
    if (this.ro) this.ro.disconnect()
    if (this.onResize) window.removeEventListener("resize", this.onResize)
    if (this.onScroll) window.removeEventListener("scroll", this.onScroll, true)
    if (this.raf) cancelAnimationFrame(this.raf)
    if (this.settle) clearTimeout(this.settle)
    // Hide (don't close) so the page persists when the user returns to /browse.
    if (this.invoke) this.invoke("browser_hide", { surfaceId: this.sid }).catch(() => {})
  }
}
