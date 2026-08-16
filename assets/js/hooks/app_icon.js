// The macOS Dock icon, while the app runs (APP_ICON_ROADMAP Phase 3).
//
// Always mounted in the layout, like VoiceBridge and for the same reason: the
// server pushes "bc:app-icon" from ChromeHook on mount and on every change, and
// a hook that only existed on one page would miss both.
//
// `path` is null when the operator has applied nothing, or has applied something
// and then replaced the file. Null is an instruction, not an absence — it tells
// AppKit to restore the icon baked into the bundle — so it is forwarded rather
// than filtered out.
//
// Outside the desktop app there is no Dock and no __TAURI__, so this is a no-op.
// That is the whole degradation story: the browser dev loop cannot see this
// feature at all, which is why it needs a packaged walk.
export const AppIconBridge = {
  mounted() {
    this.invoke = window.__TAURI__?.core?.invoke || null
    this.handleEvent("bc:app-icon", ({path}) => {
      if (!this.invoke) return
      this.invoke("app_icon_set", {path: path ?? null}).catch(() => {})
    })
  },
}
