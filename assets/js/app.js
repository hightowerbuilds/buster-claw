// If you want to use Phoenix channels, run `mix help phx.gen.channel`
// to get started and then uncomment the line below.
// import "./user_socket.js"

// You can include dependencies in two ways.
//
// The simplest option is to put them in assets/vendor and
// import them using relative paths:
//
//     import "../vendor/some-package.js"
//
// Alternatively, you can `npm install some-package --prefix assets` and import
// them using a path starting with the package name:
//
//     import "some-package"
//
// If you have dependencies that try to import CSS, esbuild will generate a separate `app.css` file.
// To load it, simply add a second `<link>` to your `root.html.heex` file.

// Include phoenix_html to handle method=PUT/DELETE in forms and buttons.
import "phoenix_html"
// Establish Phoenix Socket and LiveView configuration.
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import {hooks as colocatedHooks} from "phoenix-colocated/buster_claw"
import topbar from "../vendor/topbar"
import {Terminal as XTerm} from "@xterm/xterm"
import {FitAddon} from "@xterm/addon-fit"
import {WebglAddon} from "@xterm/addon-webgl"

// The Settings section presents several routes behind one in-page tab bar
// (Appearance, GWS, Integrations, Configuration, Security). In the top
// browser-style tab strip those routes collapse into a single "Settings" tab
// keyed by the group's canonical path, so traversing the sub-tabs only moves the
// in-page highlight — it never spawns new top-level tabs.
const TAB_GROUPS = [
  {
    key: "/settings",
    paths: new Set(["/settings", "/appearance", "/gws", "/integrations", "/security"])
  }
]

// Canonical top-tab path for a route: the owning group's key if the route is in
// a collapsed group, else null.
function canonicalGroupKey(path) {
  for (const g of TAB_GROUPS) if (g.paths.has(path)) return g.key
  return null
}

// ---- Terminal color themes -------------------------------------------------
// xterm palettes selectable from Settings → Appearance. The chosen key is
// stored in localStorage["bc:term-theme"]; "industrial" derives its colors from
// the app's CSS tokens so it tracks the light/dark app theme.
const TERM_THEME_KEY = "bc:term-theme"
const TERM_THEME_DEFAULT = "industrial"
const TERM_THEMES = {
  industrial: null, // sentinel — resolved from CSS tokens, see termThemePalette
  light: {
    background: "#fafafa", foreground: "#1a1a1a", cursor: "#1a1a1a",
    cursorAccent: "#fafafa", selectionBackground: "#c7d2fe", selectionForeground: "#1a1a1a"
  },
  solarized: {
    background: "#002b36", foreground: "#839496", cursor: "#93a1a1",
    cursorAccent: "#002b36", selectionBackground: "#073642",
    black: "#073642", red: "#dc322f", green: "#859900", yellow: "#b58900",
    blue: "#268bd2", magenta: "#d33682", cyan: "#2aa198", white: "#eee8d5",
    brightBlack: "#586e75", brightRed: "#cb4b16", brightGreen: "#586e75", brightYellow: "#657b83",
    brightBlue: "#839496", brightMagenta: "#6c71c4", brightCyan: "#93a1a1", brightWhite: "#fdf6e3"
  },
  dracula: {
    background: "#282a36", foreground: "#f8f8f2", cursor: "#f8f8f2",
    cursorAccent: "#282a36", selectionBackground: "#44475a",
    black: "#21222c", red: "#ff5555", green: "#50fa7b", yellow: "#f1fa8c",
    blue: "#bd93f9", magenta: "#ff79c6", cyan: "#8be9fd", white: "#f8f8f2",
    brightBlack: "#6272a4", brightRed: "#ff6e6e", brightGreen: "#69ff94", brightYellow: "#ffffa5",
    brightBlue: "#d6acff", brightMagenta: "#ff92df", brightCyan: "#a4ffff", brightWhite: "#ffffff"
  },
  nord: {
    background: "#2e3440", foreground: "#d8dee9", cursor: "#d8dee9",
    cursorAccent: "#2e3440", selectionBackground: "#434c5e",
    black: "#3b4252", red: "#bf616a", green: "#a3be8c", yellow: "#ebcb8b",
    blue: "#81a1c1", magenta: "#b48ead", cyan: "#88c0d0", white: "#e5e9f0",
    brightBlack: "#4c566a", brightRed: "#bf616a", brightGreen: "#a3be8c", brightYellow: "#ebcb8b",
    brightBlue: "#81a1c1", brightMagenta: "#b48ead", brightCyan: "#8fbcbb", brightWhite: "#eceff4"
  },
  gruvbox: {
    background: "#282828", foreground: "#ebdbb2", cursor: "#ebdbb2",
    cursorAccent: "#282828", selectionBackground: "#504945",
    black: "#282828", red: "#cc241d", green: "#98971a", yellow: "#d79921",
    blue: "#458588", magenta: "#b16286", cyan: "#689d6a", white: "#a89984",
    brightBlack: "#928374", brightRed: "#fb4934", brightGreen: "#b8bb26", brightYellow: "#fabd2f",
    brightBlue: "#83a598", brightMagenta: "#d3869b", brightCyan: "#8ec07c", brightWhite: "#ebdbb2"
  },
  monokai: {
    background: "#272822", foreground: "#f8f8f2", cursor: "#f8f8f0",
    cursorAccent: "#272822", selectionBackground: "#49483e",
    black: "#272822", red: "#f92672", green: "#a6e22e", yellow: "#f4bf75",
    blue: "#66d9ef", magenta: "#ae81ff", cyan: "#a1efe4", white: "#f8f8f2",
    brightBlack: "#75715e", brightRed: "#f92672", brightGreen: "#a6e22e", brightYellow: "#f4bf75",
    brightBlue: "#66d9ef", brightMagenta: "#ae81ff", brightCyan: "#a1efe4", brightWhite: "#f9f8f5"
  },
  "tokyo-night": {
    background: "#1a1b26", foreground: "#c0caf5", cursor: "#c0caf5",
    cursorAccent: "#1a1b26", selectionBackground: "#283457",
    black: "#15161e", red: "#f7768e", green: "#9ece6a", yellow: "#e0af68",
    blue: "#7aa2f7", magenta: "#bb9af7", cyan: "#7dcfff", white: "#a9b1d6",
    brightBlack: "#414868", brightRed: "#f7768e", brightGreen: "#9ece6a", brightYellow: "#e0af68",
    brightBlue: "#7aa2f7", brightMagenta: "#bb9af7", brightCyan: "#7dcfff", brightWhite: "#c0caf5"
  },
  matrix: {
    background: "#000000", foreground: "#00ff41", cursor: "#00ff41",
    cursorAccent: "#000000", selectionBackground: "#0f3d0f"
  }
}

function currentTermTheme() {
  return localStorage.getItem(TERM_THEME_KEY) || TERM_THEME_DEFAULT
}

function termThemePalette(key) {
  const preset = TERM_THEMES[key]
  if (preset) return preset
  // "industrial" (or unknown) — match the live app surface via CSS tokens.
  const css = getComputedStyle(document.documentElement)
  const token = (name, fallback) => (css.getPropertyValue(name).trim() || fallback)
  const bg = token("--color-base-100", "#121212")
  const fg = token("--color-base-content", "#fafafa")
  const accent = token("--color-primary", "#ff4d1c")
  return {
    background: bg, foreground: fg, cursor: accent, cursorAccent: bg,
    selectionBackground: accent, selectionForeground: bg
  }
}

// xterm theme palette, made see-through when a terminal background image is
// active so the image shows behind the text (the `__bcBgActive` flag is set per
// terminal by the TerminalView hook).
function termThemeWithBackground(bgActive) {
  const palette = termThemePalette(currentTermTheme())
  return bgActive ? {...palette, background: "rgba(0,0,0,0)"} : palette
}

// Full-screen TUIs often fill empty cells with ANSI black. When an image-backed
// terminal is transparent, those black background instructions need to become
// the default transparent background instead of opaque painted cells.
function stripTransparentBackgroundPaint(data, state) {
  const input = (state.pending || "") + String(data || "")
  state.pending = ""

  let output = ""
  let offset = 0

  while (offset < input.length) {
    const csiStart = input.indexOf("\x1b[", offset)
    if (csiStart === -1) {
      output += input.slice(offset)
      break
    }

    output += input.slice(offset, csiStart)

    const csiEnd = findCsiEnd(input, csiStart + 2)
    if (csiEnd === -1) {
      state.pending = input.slice(csiStart)
      break
    }

    const sequence = input.slice(csiStart, csiEnd + 1)
    output += input[csiEnd] === "m"
      ? stripBlackBackgroundSgr(sequence, input.slice(csiStart + 2, csiEnd))
      : sequence
    offset = csiEnd + 1
  }

  return output
}

function flushTransparentBackgroundPaint(state) {
  const pending = state.pending || ""
  state.pending = ""
  return pending
}

function findCsiEnd(input, offset) {
  for (let i = offset; i < input.length; i++) {
    const code = input.charCodeAt(i)
    if (code >= 0x40 && code <= 0x7e) return i
  }

  return -1
}

function stripBlackBackgroundSgr(sequence, paramsText) {
  if (paramsText === "") return sequence

  const params = paramsText.split(";")
  const kept = []
  let changed = false

  for (let i = 0; i < params.length; i++) {
    const param = params[i]

    if (param === "40" || isBlackColonBackground(param)) {
      changed = true
      continue
    }

    if (param === "48" && params[i + 1] === "5" && isBlackAnsiColor(params[i + 2])) {
      i += 2
      changed = true
      continue
    }

    if (param === "48" && params[i + 1] === "2" && isBlackRgb(params.slice(i + 2, i + 5))) {
      i += 4
      changed = true
      continue
    }

    kept.push(param)
  }

  if (!changed) return sequence
  if (kept.length === 0) return ""

  return `\x1b[${kept.join(";")}m`
}

function isBlackColonBackground(param) {
  if (!param.startsWith("48:")) return false

  const parts = param.split(":")
  if (parts[1] === "5") return isBlackAnsiColor(parts[2])
  if (parts[1] !== "2") return false

  return isBlackRgb(parts.slice(2).filter((part) => part !== "").slice(0, 3))
}

function isBlackAnsiColor(value) {
  if (!/^\d+$/.test(String(value || ""))) return false

  const index = Number.parseInt(value, 10)
  return index === 0 || index === 16
}

function isBlackRgb(values) {
  return values.length === 3 &&
    values.every((value) => /^\d+$/.test(String(value)) && Number.parseInt(value, 10) === 0)
}

// Open xterm instances, so a theme change applies to every live terminal.
const liveTerminals = new Set()
function applyTermTheme(key) {
  const palette = termThemePalette(key)
  liveTerminals.forEach((t) => {
    t.options.theme = t.__bcBgActive ? {...palette, background: "rgba(0,0,0,0)"} : palette
  })
}
function setTermTheme(key) {
  if (!key) return
  localStorage.setItem(TERM_THEME_KEY, key)
  applyTermTheme(key)
}
window.addEventListener("bc:set-term-theme", (e) => setTermTheme(e.target.dataset.termTheme))
window.addEventListener("storage", (e) => {
  if (e.key === TERM_THEME_KEY) applyTermTheme(currentTermTheme())
})
// When the app light/dark theme flips, refresh terminals that track it.
window.addEventListener("phx:set-theme", () => {
  if (currentTermTheme() === "industrial") setTimeout(() => applyTermTheme("industrial"), 0)
})

const TAB_STORAGE_KEY = "bc:tabs"
const SPLIT_RATIO_KEY = "bc:split-ratio"

function splitPathQuery(fullPath) {
  const value = String(fullPath || "")
  const idx = value.indexOf("?")
  if (idx === -1) return [value, ""]
  return [value.slice(0, idx), value.slice(idx + 1)]
}

function loadTabs() {
  try { return JSON.parse(localStorage.getItem(TAB_STORAGE_KEY)) || [] } catch (_e) { return [] }
}

function saveTabs(tabs) {
  localStorage.setItem(TAB_STORAGE_KEY, JSON.stringify(tabs))
}

function terminalLabelFromQuery(query, labels = {}) {
  const params = new URLSearchParams(query || "")
  return params.get("label") || labels["/terminal"] || "Terminal"
}

function labelForPath(fullPath, labels = {}) {
  if (!fullPath) return "?"
  const [path, query] = splitPathQuery(fullPath)
  if (path === "/terminal") return terminalLabelFromQuery(query, labels)
  if (path === "/split") {
    const params = new URLSearchParams(query || "")
    return `${labelForPath(params.get("left"), labels)} | ${labelForPath(params.get("right"), labels)}`
  }
  return labels[path] || path
}

function newTerminalKey() {
  const stamp = new Date().toISOString().replace(/\D/g, "").slice(0, 14)
  const token = Math.random().toString(36).slice(2, 6)
  return `term-${stamp}-${token}`
}

function nextTerminalNumber(tabs, labels = {}) {
  const usedNumbers = tabs.flatMap((t) => {
    const [path] = splitPathQuery(t.path)
    if (path !== "/terminal") return []

    const match = String(t.label || labelForPath(t.path, labels)).match(/^Terminal(?:\s+(\d+))?$/)
    if (!match) return []

    return [match[1] ? parseInt(match[1], 10) : 1]
  })

  return Math.max(1, ...usedNumbers) + 1
}

function createTerminalTab(tabs = loadTabs(), labels = {}) {
  const key = newTerminalKey()
  const label = `Terminal ${nextTerminalNumber(tabs, labels)}`
  const path = `/terminal?session=${encodeURIComponent(key)}&label=${encodeURIComponent(label)}`
  return {path, label}
}

function openNewTerminalTab(labels = {}) {
  const tabs = loadTabs()
  const tab = createTerminalTab(tabs, labels)
  tabs.push(tab)
  saveTabs(tabs)
  window.location.href = tab.path
}

function splitPathForTerminal(currentPath, side, labels = {}) {
  const other = createTerminalTab(loadTabs(), labels)
  const left = side === "left" ? other.path : currentPath
  const right = side === "left" ? currentPath : other.path
  return `/split?left=${encodeURIComponent(left)}&right=${encodeURIComponent(right)}`
}

function openTerminalSplit(currentPath, side, labels = {}) {
  const splitPath = splitPathForTerminal(currentPath, side, labels)
  const currentTabPath = window.location.pathname + window.location.search
  const tabs = loadTabs().filter((t) => t.path !== currentPath && t.path !== currentTabPath)
  tabs.push({path: splitPath, label: labelForPath(splitPath, labels)})
  saveTabs(tabs)
  window.location.href = splitPath
}

const Hooks = {
  // Always-mounted bridge (layout header). When the agent requests a screenshot,
  // Phoenix pushes "bc:screenshot_request"; we invoke the Tauri browser_screenshot
  // command for the active tab and POST the PNG (base64) back to /browser/screenshot,
  // correlated by ref. Outside the desktop app there's no Tauri → report an error so
  // the waiting command fails fast instead of timing out.
  ScreenshotBridge: {
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
    },
    report(ref, payload) {
      fetch("/browser/screenshot", {
        method: "POST",
        headers: {"content-type": "application/json"},
        body: JSON.stringify({ref, ...payload}),
      }).catch(() => {})
    },
  },
  // Homepage chat: keep the transcript scrolled to the newest message, and make
  // Enter submit the message (Shift+Enter inserts a newline). The textarea is
  // cleared optimistically on submit; the user echo comes back over PubSub.
  AgentChat: {
    mounted() {
      this.log = this.el.querySelector("[data-chat-log]")
      this.input = this.el.querySelector("[data-chat-input]")
      this.form = this.el.querySelector("[data-chat-form]")
      this.handle = this.el.querySelector("[data-resize-handle]")
      this.applyHeight()
      this.scrollToBottom()

      this.onKeydown = (e) => {
        if (e.key === "Enter" && !e.shiftKey) {
          e.preventDefault()
          if (this.input.value.trim() !== "") {
            this.form.requestSubmit()
            this.input.value = ""
          }
        }
      }
      this.onSubmit = () => {
        // Clear after the framework has serialized the form values.
        requestAnimationFrame(() => {
          this.input.value = ""
        })
      }

      // Drag the bottom handle to resize the chat height. Persisted in
      // localStorage and re-applied on updated() (LiveView patches would
      // otherwise drop the inline height on the next render).
      this.onHandleDown = (e) => {
        e.preventDefault()
        this.dragging = true
        this.dragStartY = e.clientY
        this.dragStartH = this.el.offsetHeight
        window.addEventListener("pointermove", this.onHandleMove)
        window.addEventListener("pointerup", this.onHandleUp)
        document.body.style.userSelect = "none"
        document.body.style.cursor = "ns-resize"
      }
      this.onHandleMove = (e) => {
        this.el.style.height = this.clampHeight(this.dragStartH + (e.clientY - this.dragStartY)) + "px"
      }
      this.onHandleUp = () => {
        this.dragging = false
        window.removeEventListener("pointermove", this.onHandleMove)
        window.removeEventListener("pointerup", this.onHandleUp)
        document.body.style.userSelect = ""
        document.body.style.cursor = ""
        const h = parseInt(this.el.style.height, 10)
        if (!isNaN(h)) localStorage.setItem("bc:chat-height", String(h))
      }

      this.input.addEventListener("keydown", this.onKeydown)
      this.form.addEventListener("submit", this.onSubmit)
      this.handle?.addEventListener("pointerdown", this.onHandleDown)
    },
    updated() {
      this.applyHeight()
      this.scrollToBottom()
    },
    destroyed() {
      this.input.removeEventListener("keydown", this.onKeydown)
      this.form.removeEventListener("submit", this.onSubmit)
      this.handle?.removeEventListener("pointerdown", this.onHandleDown)
      window.removeEventListener("pointermove", this.onHandleMove)
      window.removeEventListener("pointerup", this.onHandleUp)
    },
    scrollToBottom() {
      if (this.log) this.log.scrollTop = this.log.scrollHeight
    },
    clampHeight(h) {
      const min = 240
      const max = Math.round(window.innerHeight * 0.9)
      return Math.max(min, Math.min(max, h))
    },
    applyHeight() {
      if (this.dragging) return
      const saved = parseInt(localStorage.getItem("bc:chat-height"), 10)
      if (!isNaN(saved)) this.el.style.height = this.clampHeight(saved) + "px"
    },
  },
  // Live chat "thinking" timer. While data-state="running" it ticks up from the
  // moment it mounted (no server round-trips); when the first token lands the
  // server flips data-state="done" with the authoritative data-ms, and we freeze
  // the label to that. The element only exists while a turn is in flight, so
  // mount/destroy bound the timer's lifetime.
  ThinkingTimer: {
    mounted() {
      this.labelEl = this.el.querySelector("[data-thinking-label]")
      this.render()
    },
    updated() {
      this.render()
    },
    destroyed() {
      this.stop()
    },
    render() {
      if (this.el.dataset.state === "done") {
        this.stop()
        const ms = parseInt(this.el.dataset.ms, 10)
        this.setLabel("Thought " + this.fmt(isNaN(ms) ? 0 : ms))
      } else {
        if (this.startedAt == null) this.startedAt = performance.now()
        if (!this.timer) this.timer = setInterval(() => this.tick(), 100)
        this.tick()
      }
    },
    tick() {
      if (this.startedAt != null) this.setLabel("Thinking " + this.fmt(performance.now() - this.startedAt))
    },
    stop() {
      if (this.timer) {
        clearInterval(this.timer)
        this.timer = null
      }
    },
    setLabel(text) {
      if (this.labelEl) this.labelEl.textContent = text
    },
    fmt(ms) {
      return (Math.max(0, ms) / 1000).toFixed(1) + "s"
    },
  },
  // Tracks the pointer over a `.ic-scanlines` heading and writes its position
  // into --crt-x/--crt-y so the CSS reveals a stronger chromatic-aberration
  // overlay in a circle under the cursor. Throttled to one write per frame; no
  // server round-trips. Toggles data-crt-active to fade the overlay in/out.
  CrtAberration: {
    mounted() {
      this.frame = null
      this.onEnter = () => this.el.setAttribute("data-crt-active", "1")
      this.onLeave = () => {
        this.el.setAttribute("data-crt-active", "0")
        if (this.frame) cancelAnimationFrame(this.frame)
        this.frame = null
      }
      this.onMove = (e) => {
        const rect = this.el.getBoundingClientRect()
        this.x = e.clientX - rect.left
        this.y = e.clientY - rect.top
        if (this.frame) return
        this.frame = requestAnimationFrame(() => {
          this.frame = null
          this.el.style.setProperty("--crt-x", `${this.x}px`)
          this.el.style.setProperty("--crt-y", `${this.y}px`)
        })
      }
      this.el.addEventListener("pointerenter", this.onEnter)
      this.el.addEventListener("pointerleave", this.onLeave)
      this.el.addEventListener("pointermove", this.onMove)
    },
    destroyed() {
      this.el.removeEventListener("pointerenter", this.onEnter)
      this.el.removeEventListener("pointerleave", this.onLeave)
      this.el.removeEventListener("pointermove", this.onMove)
      if (this.frame) cancelAnimationFrame(this.frame)
    },
  },

  // Positions the embedded browser's two native child webviews (chrome toolbar +
  // content) over the /browse surface. The toolbar lives in the native chrome
  // webview, so it's never covered. Only active in the desktop app
  // (window.__TAURI__); a plain browser shows the fallback notice.
  EmbeddedBrowser: {
    mounted() {
      this.invoke = window.__TAURI__?.core?.invoke || null
      this.surface = this.el.querySelector("[data-browser-surface]")
      this.fallback = this.el.querySelector("[data-browser-fallback]")
      this.origin = window.location.origin
      this.opened = false

      if (!this.invoke) {
        if (this.fallback) {
          this.fallback.classList.remove("hidden")
          this.fallback.classList.add("grid")
        }
        return
      }

      const initial = (this.el.dataset.initialUrl || "").trim()
      this.chromeUrl =
        `${this.origin}/browser/chrome` + (initial ? `?url=${encodeURIComponent(initial)}` : "")
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
            chromeUrl: this.chromeUrl,
            contentUrl: this.contentUrl,
            ...bounds
          }).catch(() => {})
        } else {
          this.invoke("browser_set_bounds", bounds).catch(() => {})
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
      if (this.invoke) this.invoke("browser_hide").catch(() => {})
    }
  },

  CalendarDrag: {
    mounted() {
      let draggingId = null
      let lastTarget = null

      this.el.addEventListener("dragstart", (e) => {
        const chip = e.target.closest("[data-event-id]")
        if (!chip) return
        draggingId = chip.dataset.eventId
        e.dataTransfer.effectAllowed = "move"
        // some browsers need this for the drag to fire
        e.dataTransfer.setData("text/plain", draggingId)
        chip.classList.add("opacity-50")
      })

      this.el.addEventListener("dragend", (e) => {
        const chip = e.target.closest("[data-event-id]")
        if (chip) chip.classList.remove("opacity-50")
        if (lastTarget) {
          lastTarget.classList.remove("ring-2", "ring-base-content")
          lastTarget = null
        }
        draggingId = null
      })

      this.el.addEventListener("dragover", (e) => {
        const cell = e.target.closest("[data-drop-date]")
        if (!cell) return
        e.preventDefault()
        e.dataTransfer.dropEffect = "move"
        if (lastTarget !== cell) {
          if (lastTarget) lastTarget.classList.remove("ring-2", "ring-base-content")
          cell.classList.add("ring-2", "ring-base-content")
          lastTarget = cell
        }
      })

      this.el.addEventListener("dragleave", (e) => {
        const cell = e.target.closest("[data-drop-date]")
        if (cell && cell === lastTarget && !cell.contains(e.relatedTarget)) {
          cell.classList.remove("ring-2", "ring-base-content")
          lastTarget = null
        }
      })

      this.el.addEventListener("drop", (e) => {
        const cell = e.target.closest("[data-drop-date]")
        if (!cell || !draggingId) return
        e.preventDefault()
        const newDate = cell.dataset.dropDate
        cell.classList.remove("ring-2", "ring-base-content")
        lastTarget = null
        this.pushEvent("move_event", {id: draggingId, date: newDate})
        draggingId = null
      })
    }
  },

  // Browser-style tab strip. Open routes are persisted client-side in
  // localStorage so they survive LiveView navigations; the dock buttons open
  // routes, and each open route shows up here as a tab with a close (×) button.
  TabStrip: {
    mounted() {
      this.labels = this.parseLabels()
      this.el.addEventListener("click", (e) => this.onClick(e))
      // Drag one tab onto another to join them into a side-by-side split tab.
      this.el.addEventListener("dragstart", (e) => this.onDragStart(e))
      this.el.addEventListener("dragover", (e) => this.onDragOver(e))
      this.el.addEventListener("drop", (e) => this.onDrop(e))
      // Right-click a tab for the context menu (Join tabs, ...).
      this.el.addEventListener("contextmenu", (e) => this.onContextMenu(e))
      // Double-click a tab to rename it; Enter/blur commits, Escape cancels.
      this.editingPath = null
      this.el.addEventListener("dblclick", (e) => this.onRenameStart(e))
      this.el.addEventListener("keydown", (e) => this.onRenameKeydown(e))
      this.el.addEventListener("focusout", (e) => this.onRenameBlur(e))
      this.onNav = () => {this.closeMenu(); this.sync(); this.render()}
      // Re-render on every LiveView navigation so the active tab tracks the URL.
      window.addEventListener("phx:page-loading-stop", this.onNav)
      // BrowseLive pushes the loaded page's title/url so the tab reflects it.
      this.handleEvent("bc:tab_meta", (m) => this.onTabMeta(m))
      // Commands/CLI can request a visible in-app terminal tab.
      this.handleEvent("bc:open_terminal", (request) => this.onOpenTerminalRequest(request))
      // ⌘T opens a terminal tab; ⌘W closes the active tab, then the window once
      // no tabs remain. Capture phase so we beat xterm's own key handling.
      this.onKeydown = (e) => this.handleShortcut(e)
      window.addEventListener("keydown", this.onKeydown, true)
      // The joined-tab "swap sides" control (rendered in /split) asks us to swap,
      // so the persisted tab path + label stay in sync.
      this.onSwapSplit = () => this.swapSides(this.currentKey())
      window.addEventListener("bc:swap-split", this.onSwapSplit)
      // The per-pane close (×) in /split asks us to drop one side and keep the
      // other as a solo tab.
      this.onCloseSplitPane = (e) => this.closeSplitPane(e.detail && e.detail.side)
      window.addEventListener("bc:close-split-pane", this.onCloseSplitPane)
      this.sync()
      this.render()
    },
    destroyed() {
      this.closeMenu()
      window.removeEventListener("phx:page-loading-stop", this.onNav)
      window.removeEventListener("keydown", this.onKeydown, true)
      window.removeEventListener("bc:swap-split", this.onSwapSplit)
      window.removeEventListener("bc:close-split-pane", this.onCloseSplitPane)
    },
    parseLabels() {
      try { return JSON.parse(this.el.dataset.labels || "{}") } catch (_e) { return {} }
    },
    load() { return loadTabs() },
    save(tabs) { saveTabs(tabs) },
    // Tab key is the full path incl. query, so multiple /browse tabs
    // (each /browse?t=<id>) are distinct, independent tabs. Any Settings
    // sub-route collapses to the single /settings key so they share one top tab.
    currentKey() {
      const group = canonicalGroupKey(window.location.pathname)
      if (group) return group
      return window.location.pathname + window.location.search
    },
    labelFor(key) {
      return labelForPath(key, this.labels)
    },
    shortLabel(fullPath) {
      return labelForPath(fullPath, this.labels)
    },
    sync() {
      const key = this.currentKey()
      const tabs = this.load()
      // Drop legacy per-subroute tabs for any collapsed group; they fold into
      // the group's single canonical tab. Keep canonical and ungrouped tabs.
      const pruned = tabs.filter((t) => {
        const group = canonicalGroupKey(t.path)
        return !group || group === t.path
      })
      let changed = pruned.length !== tabs.length
      if (!pruned.some((t) => t.path === key)) {
        pruned.push({path: key, label: this.labelFor(key)})
        changed = true
      }
      if (changed) this.save(pruned)
    },
    // A loaded page tells us its title/url; reflect both on the current tab so
    // it shows the page title (not "Browse") and can carry the url into a split.
    onTabMeta({title, url}) {
      const key = this.currentKey()
      const tabs = this.load()
      const tab = tabs.find((t) => t.path === key)
      if (!tab) return
      if (title) tab.label = title
      tab.url = url
      this.save(tabs)
      this.render()
    },
    onOpenTerminalRequest(request) {
      const path = request?.path
      if (!path) return

      const label = request.label || this.labelFor(path)
      const tabs = this.load().filter((t) => t.path !== path)
      tabs.push({
        path,
        label,
        role_key: request.role_key,
        agent_name: request.agent_name,
        purpose: request.purpose,
        startup_profile: request.startup_profile
      })
      this.save(tabs)

      if (request.activate === false) {
        this.render()
      } else {
        window.location.href = path
      }
    },
    render() {
      const active = this.currentKey()
      const tabs = this.load().map((t) => this.tabHtml(t, t.path === active)).join("")
      this.el.innerHTML = tabs
      if (this.editingPath) {
        const input = this.el.querySelector("[data-tab-edit]")
        if (input) input.focus()
      }
    },
    tabHtml(tab, isActive) {
      const wrap = isActive
        ? "group flex shrink-0 items-center gap-1 rounded-t-lg border border-b-0 border-base-300 bg-base-100 px-3 py-1.5 text-sm font-medium text-base-content"
        : "group flex shrink-0 items-center gap-1 rounded-t-lg border border-transparent bg-base-200 px-3 py-1.5 text-sm text-base-content/60 hover:bg-base-100/70 hover:text-base-content"
      const label = this.escape(tab.label)
      const path = this.escape(tab.path)
      // While renaming: the name is replaced by an empty focused input.
      if (tab.path === this.editingPath) {
        return `<span class="${wrap}" data-path="${path}">` +
          `<input data-tab-edit type="text" value="" aria-label="Rename tab" ` +
          `autocomplete="off" spellcheck="false" ` +
          `class="w-32 max-w-[12rem] bg-transparent text-sm outline-none" /></span>`
      }
      return `<span class="${wrap}" data-path="${path}" draggable="true">` +
        `<a href="${path}" draggable="false" data-phx-link="redirect" data-phx-link-state="push" class="max-w-[12rem] truncate">${label}</a>` +
        `<button type="button" data-close="${path}" aria-label="Close ${label}" ` +
        `class="grid size-4 shrink-0 place-items-center rounded text-base-content/40 hover:bg-base-300 hover:text-base-content">&times;</button>` +
        `</span>`
    },
    // ----- Double-click rename -----
    onRenameStart(e) {
      const tab = e.target.closest("[data-path]")
      if (!tab) return
      e.preventDefault()
      this.editingPath = tab.getAttribute("data-path")
      this.render()
    },
    onRenameKeydown(e) {
      if (!e.target.closest("[data-tab-edit]")) return
      if (e.key === "Enter") {
        e.preventDefault()
        this.commitRename(e.target.value)
      } else if (e.key === "Escape") {
        e.preventDefault()
        this.cancelRename()
      }
    },
    onRenameBlur(e) {
      const input = e.target.closest("[data-tab-edit]")
      if (input) this.commitRename(input.value)
    },
    commitRename(value) {
      if (!this.editingPath) return
      const path = this.editingPath
      this.editingPath = null
      const name = String(value || "").trim()
      if (name) {
        const tabs = this.load()
        const tab = tabs.find((t) => t.path === path)
        if (tab) {
          tab.label = name
          this.save(tabs)
        }
      }
      this.render()
    },
    cancelRename() {
      this.editingPath = null
      this.render()
    },
    onClick(e) {
      const newTab = e.target.closest("[data-newtab]")
      if (newTab) {
        e.preventDefault()
        this.openBrowserTab()
        return
      }
      const newTerminal = e.target.closest("[data-newterminal]")
      if (newTerminal) {
        e.preventDefault()
        this.openTerminalTab()
        return
      }
      const closeBtn = e.target.closest("[data-close]")
      if (!closeBtn) return
      e.preventDefault()
      e.stopPropagation()
      this.closeTab(closeBtn.getAttribute("data-close"))
    },
    openBrowserTab() {
      const token = Math.random().toString(36).slice(2, 8)
      window.location.href = `/browse?t=${token}`
    },
    openTerminalTab() {
      openNewTerminalTab(this.labels)
    },
    onDragStart(e) {
      const tab = e.target.closest("[data-path]")
      this.dragPath = tab ? tab.getAttribute("data-path") : null
      if (this.dragPath && e.dataTransfer) e.dataTransfer.effectAllowed = "move"
    },
    onDragOver(e) {
      if (this.dragPath && e.target.closest("[data-path]")) e.preventDefault()
    },
    onDrop(e) {
      const tab = e.target.closest("[data-path]")
      if (!tab || !this.dragPath) return
      e.preventDefault()
      const targetPath = tab.getAttribute("data-path")
      // Default drag reorders; hold Alt to join two tabs into a split.
      if (e.altKey) {
        this.joinTabs(this.dragPath, targetPath)
      } else {
        this.reorderTab(this.dragPath, targetPath)
      }
      this.dragPath = null
    },
    // Move the dragged tab to the dropped target's position; persisted order is
    // the render order, so this survives navigations.
    reorderTab(from, to) {
      if (!from || !to || from === to) return
      const tabs = this.load()
      const fromIdx = tabs.findIndex((t) => t.path === from)
      const toIdx = tabs.findIndex((t) => t.path === to)
      if (fromIdx === -1 || toIdx === -1) return
      const [moved] = tabs.splice(fromIdx, 1)
      tabs.splice(toIdx, 0, moved)
      this.save(tabs)
      this.render()
    },
    // A pane carries its browsed page as ?url=<page> so the split can load it.
    paneParam(tabPath) {
      const tab = this.load().find((t) => t.path === tabPath)
      if (tab && tab.url) {
        return tabPath.split("?")[0] + "?url=" + encodeURIComponent(tab.url)
      }
      return tabPath
    },
    joinTabs(a, b) {
      // Don't join a tab to itself or nest splits inside splits.
      if (!a || !b || a === b) return
      if (a.split("?")[0] === "/split" || b.split("?")[0] === "/split") return
      const left = this.paneParam(a)
      const right = this.paneParam(b)
      // The two source tabs now live inside the joined tab — drop them.
      this.save(this.load().filter((t) => t.path !== a && t.path !== b))
      window.location.href = `/split?left=${encodeURIComponent(left)}&right=${encodeURIComponent(right)}`
    },
    // Swap the two sides of a joined tab.
    swapSides(splitPath) {
      const params = new URLSearchParams(splitPath.split("?")[1] || "")
      const left = params.get("left")
      const right = params.get("right")
      if (!left || !right) return
      const newPath = `/split?left=${encodeURIComponent(right)}&right=${encodeURIComponent(left)}`
      this.save(
        this.load().map((t) =>
          t.path === splitPath ? {path: newPath, label: this.labelFor(newPath)} : t
        )
      )
      window.location.href = newPath
    },
    // Close one pane of a joined tab; the other side stays open as a solo tab.
    closeSplitPane(side) {
      const cur = this.currentKey()
      if (cur.split("?")[0] !== "/split") return
      const params = new URLSearchParams(cur.split("?")[1] || "")
      const keep = side === "left" ? params.get("right") : params.get("left")
      if (!keep) return
      const tabs = this.load().filter((t) => t.path !== cur)
      if (!tabs.some((t) => t.path === keep)) {
        tabs.push({path: keep, label: this.labelFor(keep)})
      }
      this.save(tabs)
      window.location.href = keep
    },
    // Split a joined tab back into its two component tabs.
    separateTabs(splitPath) {
      const params = new URLSearchParams(splitPath.split("?")[1] || "")
      const left = params.get("left")
      const right = params.get("right")
      if (!left || !right) return
      const tabs = this.load().filter((t) => t.path !== splitPath)
      for (const p of [left, right]) {
        if (!tabs.some((t) => t.path === p)) tabs.push({path: p, label: this.labelFor(p)})
      }
      this.save(tabs)
      window.location.href = left
    },
    // ----- Right-click context menu -----
    onContextMenu(e) {
      const tab = e.target.closest("[data-path]")
      if (!tab) return
      e.preventDefault()
      this.openMenu(tab.getAttribute("data-path"), e.clientX, e.clientY)
    },
    openMenu(path, x, y) {
      this.closeMenu()
      this.menuPath = path
      const menu = document.createElement("div")
      menu.className =
        "fixed z-50 min-w-44 rounded-lg border border-base-300 bg-base-100 p-1 text-sm shadow-lg"
      menu.addEventListener("click", (e) => this.onMenuClick(e))
      menu.addEventListener("contextmenu", (e) => e.preventDefault())
      document.body.appendChild(menu)
      this.menuEl = menu
      this.renderMenuRoot()

      // Position at the cursor, clamped to the viewport.
      const rect = menu.getBoundingClientRect()
      const left = Math.max(8, Math.min(x, window.innerWidth - rect.width - 8))
      const top = Math.max(8, Math.min(y, window.innerHeight - rect.height - 8))
      menu.style.left = `${left}px`
      menu.style.top = `${top}px`

      // Dismiss on outside click / Escape (deferred so the opening event doesn't close it).
      this.onDocClick = (ev) => {
        if (this.menuEl && !this.menuEl.contains(ev.target)) this.closeMenu()
      }
      this.onMenuKey = (ev) => {
        if (ev.key === "Escape") this.closeMenu()
      }
      setTimeout(() => {
        document.addEventListener("click", this.onDocClick)
        document.addEventListener("keydown", this.onMenuKey)
      }, 0)
    },
    renderMenuRoot() {
      const isSplit = (this.menuPath || "").split("?")[0] === "/split"
      const item = "flex w-full items-center gap-3 rounded px-3 py-1.5 text-left hover:bg-base-200"
      this.menuEl.innerHTML = isSplit
        ? `<button type="button" data-menu="swap" class="${item}"><span>Swap sides</span></button>` +
            `<button type="button" data-menu="separate" class="${item}"><span>Separate tabs</span></button>`
        : `<button type="button" data-menu="join" class="${item} justify-between">` +
            `<span>Join tabs</span><span class="text-base-content/40">&#9656;</span></button>`
    },
    renderJoinList() {
      const candidates = this.load().filter(
        (t) => t.path !== this.menuPath && !t.path.startsWith("/split")
      )
      const header =
        `<div class="px-3 py-1 text-xs font-semibold uppercase tracking-wide text-base-content/50">Join with…</div>`
      if (candidates.length === 0) {
        this.menuEl.innerHTML =
          header + `<div class="px-3 py-2 text-xs text-base-content/50">No other tabs open.</div>`
        return
      }
      const rows = candidates
        .map(
          (t) =>
            `<button type="button" data-jointarget="${this.escape(t.path)}" ` +
            `class="block w-full truncate rounded px-3 py-1.5 text-left hover:bg-base-200">${this.escape(t.label)}</button>`
        )
        .join("")
      this.menuEl.innerHTML = header + rows
    },
    onMenuClick(e) {
      const join = e.target.closest("[data-menu='join']")
      if (join) {
        e.stopPropagation()
        this.renderJoinList()
        return
      }
      const swap = e.target.closest("[data-menu='swap']")
      if (swap) {
        e.stopPropagation()
        const source = this.menuPath
        this.closeMenu()
        this.swapSides(source)
        return
      }
      const separate = e.target.closest("[data-menu='separate']")
      if (separate) {
        e.stopPropagation()
        const source = this.menuPath
        this.closeMenu()
        this.separateTabs(source)
        return
      }
      const target = e.target.closest("[data-jointarget]")
      if (target) {
        e.stopPropagation()
        const source = this.menuPath
        this.closeMenu()
        this.joinTabs(source, target.getAttribute("data-jointarget"))
      }
    },
    closeMenu() {
      if (this.onDocClick) {
        document.removeEventListener("click", this.onDocClick)
        this.onDocClick = null
      }
      if (this.onMenuKey) {
        document.removeEventListener("keydown", this.onMenuKey)
        this.onMenuKey = null
      }
      if (this.menuEl) {
        this.menuEl.remove()
        this.menuEl = null
      }
      this.menuPath = null
    },
    closeTab(path) {
      const tabs = this.load()
      const idx = tabs.findIndex((t) => t.path === path)
      if (idx === -1) return
      // Closing the Browser tab must destroy its native webviews — the embedded
      // browser hook only *hides* them on tab switch (to persist the page), so
      // without this they'd linger after the tab is gone.
      if (path.startsWith("/browse")) {
        const invoke = window.__TAURI__?.core?.invoke
        if (invoke) invoke("browser_close").catch(() => {})
      }
      tabs.splice(idx, 1)
      this.save(tabs)
      if (path === this.currentKey()) {
        const next = tabs[idx] || tabs[idx - 1]
        window.location.href = next ? next.path : "/"
      } else {
        this.render()
      }
    },
    handleShortcut(e) {
      if (e.altKey || e.shiftKey || !(e.metaKey || e.ctrlKey)) return
      const key = (e.key || "").toLowerCase()
      if (key !== "t" && key !== "w") return
      // Handle it ourselves and keep it from reaching the terminal / PTY.
      e.preventDefault()
      e.stopPropagation()
      if (key === "t") this.openTerminalTab()
      else this.closeCurrentTabOrWindow()
    },
    // ⌘W closes the active tab; once none remain it closes the window instead.
    closeCurrentTabOrWindow() {
      const active = this.currentKey()
      const remaining = this.load().filter((t) => t.path !== active)
      if (remaining.length === 0) {
        this.closeWindow()
      } else {
        this.closeTab(active)
      }
    },
    closeWindow() {
      try {
        const appWindow = window.__TAURI__?.window?.getCurrentWindow?.()
        if (appWindow) {
          appWindow.close()
          return
        }
      } catch (_e) {
        /* not in the desktop shell — fall through */
      }
      window.close()
    },
    escape(s) {
      return String(s).replace(/[&<>"']/g, (c) =>
        ({"&": "&amp;", "<": "&lt;", ">": "&gt;", "\"": "&quot;", "'": "&#39;"}[c]))
    }
  },

  // Resizable + swappable joined view (/split). The grabbable divider sets the
  // left pane's width via the `--split-left` CSS var (persisted in localStorage);
  // the swap button flips the two sides by reusing the tab strip's swapSides.
  SplitResizer: {
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
  },

  // PTY-backed terminal (desktop only). xterm.js renders here; the PTY lives in
  // the Tauri Rust backend, reached over IPC. In a plain browser (no Tauri) we
  // show a notice instead of a terminal.
  //
  // When the element carries `data-session-key`, the PTY persists across tab
  // switches: the LiveView unmount disposes the xterm UI but keeps the shell
  // alive, and remounting reattaches and replays the server-buffered scrollback.
  TerminalView: {
    async mounted() {
      this.sessionKey = this.el.dataset.sessionKey || null
      this.storageKey = this.sessionKey ? `bc:term:${this.sessionKey}` : null
      this.startupCommand = (this.el.dataset.startupCommand || "").trim()
      // Whether to press enter after typing the startup command. Defaults to
      // true; the onboarding/prefill path sets `data-startup-submit="false"`
      // so the command is pre-typed and left for the user to run.
      this.startupSubmit = this.el.dataset.startupSubmit !== "false"
      this.terminalPath = this.el.dataset.terminalPath || window.location.pathname + window.location.search
      this.toolbar = document.getElementById(this.el.dataset.toolbarId || "")
      this.statusEl = document.getElementById(this.el.dataset.statusId || "")
      this.onToolbarClick = (e) => this.handleToolbarClick(e)
      this.toolbar?.addEventListener("click", this.onToolbarClick)
      this.setStatus("Connecting")

      // Terminal background image (Settings → Appearance). When active, the xterm
      // palette goes transparent; standalone terminals paint the image on their
      // own host, while split panes leave it to the shared split container.
      this.transparentBgFilterState = {pending: ""}
      this.bgActive = false
      this.bgSource = "none"
      this.setTransparencyState(
        this.el.dataset.terminalBgActive === "true",
        this.el.dataset.terminalBgSource || null
      )
      this.applyBackgroundImage(this.el.dataset.terminalBgImage || "")
      this.handleEvent("terminal-background", ({active, image, source}) =>
        this.setBackground(active, image, source)
      )

      try {
        const tauri = window.__TAURI__
        if (!tauri) {
          this.setStatus("Desktop only")
          this.el.innerHTML =
            `<div class="grid h-full place-items-center p-8 text-center text-sm text-base-content/60">` +
            `Terminal is available in the Buster Claw desktop app.</div>`
          return
        }
        if (!tauri.core?.invoke || !tauri.event?.listen) {
          throw new Error("Tauri terminal bridge unavailable")
        }
        const {invoke} = tauri.core
        const {listen} = tauri.event

        // Wait for the self-hosted monospace font to load before measuring the
        // cell grid. xterm sizes every cell from the font's glyph advance at
        // open()-time; if 'IBM Plex Mono' is still loading it measures the
        // fallback font, and once Plex swaps in the different advance drifts
        // characters out of their cells (most visible on long TUI lines). Guard
        // with a timeout so a font that never resolves can't hang the terminal.
        await this.fontsReady()

        // Color palette comes from Settings → Appearance (Terminal theme); the
        // default "industrial" derives from the app's CSS tokens.
        const term = new XTerm({
          fontFamily: "'IBM Plex Mono', ui-monospace, SFMono-Regular, Menlo, monospace",
          fontSize: 16,
          cursorBlink: true,
          allowTransparency: true,
          // The WebGL renderer needs this for its texture-atlas glyph cache.
          allowProposedApi: true,
          theme: termThemeWithBackground(this.bgActive),
        })
        term.__bcBgActive = this.bgActive
        const fit = new FitAddon()
        term.loadAddon(fit)
        term.open(this.el)
        // GPU-accelerated renderer: TUIs like Claude Code and Codex repaint the
        // whole screen rapidly (spinners, scrolling output) — the default DOM
        // renderer tears and misaligns under that load, while WebGL draws the
        // full cell grid to a canvas cell-accurately. Fall back to the DOM
        // renderer if WebGL is unavailable or its context is lost.
        this.loadWebglRenderer(term)
        this.setTransparencyState(this.bgActive, this.bgSource)
        fit.fit()
        this.term = term
        liveTerminals.add(term)

        // Try to reattach to a persisted session first.
        const storedId = this.storageKey ? localStorage.getItem(this.storageKey) : null
        let openedNewSession = false
        let scrollback = null
        if (storedId) {
          this.setStatus("Attaching")
          scrollback = await invoke("terminal_attach", {id: storedId})
        }

        if (storedId && scrollback !== null) {
          this.id = storedId
          if (scrollback) this.writeTerminal(scrollback)
          this.setStatus("Attached")
        } else {
          const cwd = this.el.dataset.cwd || null
          this.setStatus("Opening")
          this.id = await invoke("terminal_open", {cols: term.cols, rows: term.rows, cwd})
          if (this.storageKey) localStorage.setItem(this.storageKey, this.id)
          this.setStatus("Open")
          openedNewSession = true
        }

        this.unlistenData = await listen(`terminal:data:${this.id}`, (ev) => this.writeTerminal(ev.payload))
        this.unlistenExit = await listen(`terminal:exit:${this.id}`, () => {
          term.write("\r\n[process exited]\r\n")
          if (this.storageKey) localStorage.removeItem(this.storageKey)
          this.id = null
          this.setStatus("Exited")
        })
        term.onData((data) => this.id && invoke("terminal_input", {id: this.id, data}))

        // Debounce refits: a burst of ResizeObserver callbacks (window drag,
        // split open) would otherwise fire fit()/PTY-resize many times a frame
        // and let xterm and the PTY momentarily disagree on cols/rows, which a
        // mid-redraw TUI renders as wrapped/misaligned lines. Coalesce to the
        // final size.
        this.resizeObserver = new ResizeObserver(() => {
          if (this.resizeRaf) cancelAnimationFrame(this.resizeRaf)
          this.resizeRaf = requestAnimationFrame(() => {
            this.resizeRaf = null
            try { fit.fit() } catch (_e) { return }
            if (this.id) invoke("terminal_resize", {id: this.id, cols: term.cols, rows: term.rows})
          })
        })
        this.resizeObserver.observe(this.el)
        // Sync the PTY to the current viewport (important after a reattach).
        if (this.id) invoke("terminal_resize", {id: this.id, cols: term.cols, rows: term.rows})
        term.focus()
        if (openedNewSession) await this.runStartupCommand(invoke)
      } catch (e) {
        this.setStatus("Error")
        if (this.term) {
          this.term.write(`\r\n[failed to open terminal: ${e}]\r\n`)
        } else {
          this.el.innerHTML =
            `<div class="grid h-full place-items-center p-8 text-center text-sm text-error">` +
            `Failed to open terminal: ${this.escapeHtml(e)}</div>`
        }
        console.error("Buster Claw terminal failed to open", e)
      }
    },
    // Resolve once the monospace web font is ready, but never block the terminal
    // for more than ~600ms if the FontFaceSet stalls.
    async fontsReady() {
      if (!document.fonts) return
      try {
        document.fonts.load("16px 'IBM Plex Mono'")
        await Promise.race([
          document.fonts.ready,
          new Promise((resolve) => window.setTimeout(resolve, 600)),
        ])
      } catch (_e) {
        // Font measurement is best-effort; fall through to open with whatever
        // metrics are available.
      }
    },
    // Attach the WebGL renderer with a DOM fallback. If the GPU context is lost
    // (driver reset, tab backgrounded for too long) dispose the addon so xterm
    // falls back to the DOM renderer instead of freezing.
    loadWebglRenderer(term) {
      try {
        const webgl = new WebglAddon()
        webgl.onContextLoss(() => {
          try { webgl.dispose() } catch (_e) { /* already gone */ }
        })
        term.loadAddon(webgl)
      } catch (_e) {
        // No WebGL in this webview — xterm keeps its default DOM renderer.
      }
    },
    async runStartupCommand(invoke) {
      if (!this.startupCommand || !this.id) return

      this.setStatus("Starting")
      await new Promise((resolve) => window.setTimeout(resolve, 250))
      // Prefill-only (onboarding): type the command without the trailing \r so
      // the user presses enter themselves. Default: append \r to run it.
      const data = this.startupSubmit ? `${this.startupCommand}\r` : this.startupCommand
      await invoke("terminal_input", {id: this.id, data})
      this.setStatus(this.startupSubmit ? "Running" : "Ready")
    },
    handleToolbarClick(e) {
      const button = e.target.closest("[data-terminal-action]")
      if (!button || (this.toolbar && !this.toolbar.contains(button))) return

      e.preventDefault()
      const action = button.dataset.terminalAction

      if (action === "new") {
        openNewTerminalTab()
        return
      }

      if (action === "split") {
        openTerminalSplit(this.terminalPath, button.dataset.splitSide || "right")
        return
      }

      if (action === "copy-key") {
        this.copySessionKey()
        return
      }
    },
    setStatus(status) {
      if (this.statusEl) this.statusEl.textContent = status
    },
    writeTerminal(data) {
      if (!this.term) return

      const output = this.bgActive
        ? stripTransparentBackgroundPaint(data, this.transparentBgFilterState)
        : flushTransparentBackgroundPaint(this.transparentBgFilterState) + String(data || "")

      if (output) this.term.write(output)
    },
    // Live-update the background when the user changes it in Settings → Appearance.
    setBackground(active, image, source = null) {
      if (!active && this.term) {
        this.term.write(flushTransparentBackgroundPaint(this.transparentBgFilterState))
      }

      this.setTransparencyState(active, source)

      if (this.term) {
        this.term.__bcBgActive = active
        this.term.options.theme = termThemeWithBackground(active)
      }
      this.applyBackgroundImage(image || "")
    },
    setTransparencyState(active, source = null) {
      const bgActive = !!active
      const bgSource = bgActive ? (source || this.el.dataset.terminalBgSource || "host") : "none"

      this.bgActive = bgActive
      this.bgSource = bgSource
      this.el.dataset.terminalBgActive = String(bgActive)
      this.el.dataset.terminalBgSource = bgSource
      this.el.classList.toggle("bc-terminal-bg-active", bgActive)
      this.el.classList.toggle("bc-terminal-bg-shared", bgActive && bgSource === "shared")
      this.el.classList.toggle("bc-terminal-bg-host", bgActive && bgSource === "host")

      if (this.term) this.term.__bcBgActive = bgActive
    },
    applyBackgroundImage(image) {
      if (image) {
        this.el.style.backgroundImage = `url('${image}')`
        this.el.style.backgroundSize = "cover"
        this.el.style.backgroundPosition = "center"
        // Anchor to the viewport so joined terminals read as ONE continuous
        // image — each pane reveals only its slice of the same window-fixed
        // picture instead of repeating the whole image per pane.
        this.el.style.backgroundAttachment = "fixed"
      } else {
        this.el.style.backgroundImage = ""
        this.el.style.backgroundAttachment = ""
      }
    },
    escapeHtml(value) {
      return String(value).replace(/[&<>"']/g, (c) =>
        ({"&": "&amp;", "<": "&lt;", ">": "&gt;", "\"": "&quot;", "'": "&#39;"}[c]))
    },
    async copySessionKey() {
      const key = this.sessionKey || "main"
      try {
        await navigator.clipboard.writeText(key)
        this.setStatus("Copied")
      } catch (_e) {
        this.setStatus("Copy failed")
      }
    },
    destroyed() {
      if (this.toolbar && this.onToolbarClick) {
        this.toolbar.removeEventListener("click", this.onToolbarClick)
      }
      this.resizeObserver?.disconnect()
      if (this.resizeRaf) cancelAnimationFrame(this.resizeRaf)
      this.unlistenData?.()
      this.unlistenExit?.()
      // A session key means the PTY persists across unmounts (tab switches and
      // joining into a split pane both reattach to it); keyless terminals close.
      if (this.id && !this.sessionKey && window.__TAURI__) {
        window.__TAURI__.core.invoke("terminal_close", {id: this.id})
      }
      if (this.term) liveTerminals.delete(this.term)
      this.term?.dispose()
    },
  },

  // Highlights the active terminal-theme button in Settings → Appearance and
  // keeps the highlight in sync after the user picks one.
  TermThemePicker: {
    mounted() {
      this.mark = () => {
        const cur = currentTermTheme()
        this.el.querySelectorAll("[data-term-theme]").forEach((b) => {
          const active = b.dataset.termTheme === cur
          b.classList.toggle("ring-2", active)
          b.classList.toggle("ring-primary", active)
          b.setAttribute("aria-pressed", active ? "true" : "false")
        })
      }
      this.onClick = (e) => {
        if (e.target.closest("[data-term-theme]")) setTimeout(this.mark, 0)
      }
      this.el.addEventListener("click", this.onClick)
      this.mark()
    },
    destroyed() {
      this.el.removeEventListener("click", this.onClick)
    }
  }
}

const documentsSidebarStorageKey = "bc:documents-sidebar"
const setDocumentsSidebarState = (state) => {
  const nextState = state === "closed" ? "closed" : "open"
  document.documentElement.dataset.documentsSidebar = nextState
  localStorage.setItem(documentsSidebarStorageKey, nextState)
}

setDocumentsSidebarState(localStorage.getItem(documentsSidebarStorageKey))

window.addEventListener("storage", (event) => {
  if (event.key === documentsSidebarStorageKey) setDocumentsSidebarState(event.newValue)
})

window.addEventListener("bc:toggle-documents-sidebar", () => {
  const nextState = document.documentElement.dataset.documentsSidebar === "closed" ? "open" : "closed"
  setDocumentsSidebarState(nextState)
})

window.addEventListener("click", async (event) => {
  const button = event.target.closest("[data-terminal-command-copy]")
  if (!button) return

  event.preventDefault()
  const command = button.dataset.terminalCommandCopy || ""
  const label = button.querySelector("[data-terminal-command-copy-label]")

  try {
    await navigator.clipboard.writeText(command)
    if (label) {
      const previous = label.textContent
      label.textContent = "Copied"
      window.setTimeout(() => { label.textContent = previous || "Copy" }, 1200)
    }
  } catch (_e) {
    if (label) {
      const previous = label.textContent
      label.textContent = "Failed"
      window.setTimeout(() => { label.textContent = previous || "Copy" }, 1200)
    }
  }
})

const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
const liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: {_csrf_token: csrfToken},
  hooks: {...colocatedHooks, ...Hooks},
})

// Show progress bar on live navigation and form submits
topbar.config({barColors: {0: "#29d"}, shadowColor: "rgba(0, 0, 0, .3)"})
window.addEventListener("phx:page-loading-start", _info => topbar.show(300))
window.addEventListener("phx:page-loading-stop", _info => topbar.hide())

// connect if there are any LiveViews on the page
liveSocket.connect()

// expose liveSocket on window for web console debug logs and latency simulation:
// >> liveSocket.enableDebug()
// >> liveSocket.enableLatencySim(1000)  // enabled for duration of browser session
// >> liveSocket.disableLatencySim()
window.liveSocket = liveSocket

// The lines below enable quality of life phoenix_live_reload
// development features:
//
//     1. stream server logs to the browser console
//     2. click on elements to jump to their definitions in your code editor
//
if (process.env.NODE_ENV === "development") {
  window.addEventListener("phx:live_reload:attached", ({detail: reloader}) => {
    // Enable server log streaming to client.
    // Disable with reloader.disableServerLogs()
    reloader.enableServerLogs()

    // Open configured PLUG_EDITOR at file:line of the clicked element's HEEx component
    //
    //   * click with "c" key pressed to open at caller location
    //   * click with "d" key pressed to open at function component definition location
    let keyDown
    window.addEventListener("keydown", e => keyDown = e.key)
    window.addEventListener("keyup", _e => keyDown = null)
    window.addEventListener("click", e => {
      if(keyDown === "c"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtCaller(e.target)
      } else if(keyDown === "d"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtDef(e.target)
      }
    }, true)

    window.liveReloader = reloader
  })
}
