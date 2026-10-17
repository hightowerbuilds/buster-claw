import {anyTerminalBusy} from "../lib/tabs.js"

// The one confirm the strip ever shows: closing the active tab while its
// terminal is running something. Idle terminals and non-terminal tabs resolve
// true without a prompt. Split out of tab_strip.js on 10-16 (CODE_QUALITY_SWEEP
// Phase 8) as a mixin, like TabRename.
export const TabCloseConfirm = {
  // Resolve true to proceed with a close, false to abort. When the active tab's
  // terminal is running a foreground process, ask first; idle terminals and
  // non-terminal tabs resolve true immediately (no prompt).
  async confirmCloseBusyTerminal() {
    if (!(await anyTerminalBusy())) return true
    return this.showCloseConfirm()
  },
  // Minimal Industrial Claw confirm modal (brutalist 2px borders, app color
  // tokens). Resolves true on Close, false on Cancel / Escape / backdrop click.
  showCloseConfirm() {
    return new Promise((resolve) => {
      const overlay = document.createElement("div")
      overlay.className = "fixed inset-0 z-[100] grid place-items-center bg-black/50"
      overlay.innerHTML =
        `<div role="dialog" aria-modal="true" ` +
        `class="w-80 max-w-[90vw] border-2 border-base-content bg-base-100 p-5 text-base-content shadow-lg">` +
        `<p class="text-sm">This terminal is running something. Close it anyway?</p>` +
        `<div class="mt-5 flex justify-end gap-2">` +
        `<button type="button" data-confirm-cancel ` +
        `class="border-2 border-base-content px-3 py-1 text-sm font-medium hover:bg-base-200">Cancel</button>` +
        `<button type="button" data-confirm-close ` +
        `class="border-2 border-primary bg-primary px-3 py-1 text-sm font-medium text-primary-content hover:opacity-90">Close</button>` +
        `</div></div>`

      const finish = (result) => {
        document.removeEventListener("keydown", onKey, true)
        overlay.remove()
        resolve(result)
      }
      const onKey = (e) => {
        if (e.key === "Escape") { e.preventDefault(); e.stopPropagation(); finish(false) }
        else if (e.key === "Enter") { e.preventDefault(); e.stopPropagation(); finish(true) }
      }
      overlay.addEventListener("click", (e) => {
        if (e.target === overlay || e.target.closest("[data-confirm-cancel]")) finish(false)
        else if (e.target.closest("[data-confirm-close]")) finish(true)
      })
      document.addEventListener("keydown", onKey, true)
      document.body.appendChild(overlay)
      overlay.querySelector("[data-confirm-close]")?.focus()
    })
  },
  // Defined for completeness but intentionally unreachable from the ⌘W path:
  // ⌘W must never quit the app (see closeCurrentTab).
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
}
