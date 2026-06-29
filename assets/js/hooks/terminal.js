import {Terminal as XTerm} from "@xterm/xterm"
import {FitAddon} from "@xterm/addon-fit"
import {WebglAddon} from "@xterm/addon-webgl"

import {liveTerminals, currentTermTheme, termThemeWithBackground} from "../lib/theme.js"
import {stripTransparentBackgroundPaint, flushTransparentBackgroundPaint} from "../lib/ansi.js"
import {openNewTerminalTab, openTerminalSplit, registerTerminal, unregisterTerminal} from "../lib/tabs.js"

// PTY-backed terminal (desktop only). xterm.js renders here; the PTY lives in
// the Tauri Rust backend, reached over IPC. In a plain browser (no Tauri) we
// show a notice instead of a terminal.
//
// When the element carries `data-session-key`, the PTY persists across tab
// switches: the LiveView unmount disposes the xterm UI but keeps the shell
// alive, and remounting reattaches and replays the server-buffered scrollback.
export const TerminalView = {
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
      // Let the TabStrip check this terminal before closing its tab, so a
      // running build/command/agent session prompts for confirmation.
      registerTerminal(this)

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
  // Whether this PTY has a foreground process other than its idle shell — asked
  // by the TabStrip before closing the tab. Native query (tcgetpgrp); any error
  // or a torn-down session reads as not-busy so it never blocks closing.
  async isBusy() {
    const invoke = window.__TAURI__?.core?.invoke
    if (!this.id || !invoke) return false
    try {
      return await invoke("terminal_busy", {id: this.id})
    } catch (_e) {
      return false
    }
  },
  destroyed() {
    unregisterTerminal(this)
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
}

// Highlights the active terminal-theme button in Settings → Appearance and
// keeps the highlight in sync after the user picks one.
export const TermThemePicker = {
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
