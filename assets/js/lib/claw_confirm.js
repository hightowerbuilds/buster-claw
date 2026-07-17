// Replacement for LiveView's `data-confirm`, which gates the event behind a
// synchronous `window.confirm()`. In the Tauri/WKWebView shell there is no
// WKUIDelegate to service native JS dialogs, so `window.confirm()` is a no-op
// that returns `false` — every native-confirm-gated action (delete wallet,
// delete transaction, untrust contact, …) silently did nothing.
//
// Instead we own the dialog. Destructive controls carry `data-claw-confirm="…"`,
// and a capture-phase click interceptor shows an Industrial Claw modal, then —
// only on confirm — re-dispatches the click so LiveView's normal `phx-click`
// fires with all of its `phx-value-*` / `phx-target` intact. Nothing about the
// server handler changes; we just supply a confirmation the webview can render.

const ATTR = "data-claw-confirm"

// True only for the moment we re-dispatch an already-confirmed click, so the
// interceptor lets that one pass straight through to LiveView.
let bypassNext = false

// Promise-based confirm modal. Resolves true on Confirm, false on
// Cancel / Escape / backdrop click. Async by nature — which is exactly why it
// can't back LiveView's synchronous `data-confirm`, and why we re-dispatch.
export function clawConfirm(message) {
  return new Promise((resolve) => {
    const overlay = document.createElement("div")
    overlay.className = "fixed inset-0 z-[100] grid place-items-center bg-black/50"
    overlay.setAttribute("data-claw-confirm-modal", "")
    overlay.innerHTML =
      `<div role="alertdialog" aria-modal="true" ` +
      `class="w-80 max-w-[90vw] border-2 border-base-content bg-base-100 p-5 text-base-content shadow-lg">` +
      `<p class="text-sm">${escapeHtml(message)}</p>` +
      `<div class="mt-5 flex justify-end gap-2">` +
      `<button type="button" data-claw-cancel ` +
      `class="border-2 border-base-content px-3 py-1 text-sm font-medium hover:bg-base-200">Cancel</button>` +
      `<button type="button" data-claw-ok ` +
      `class="border-2 border-error bg-error px-3 py-1 text-sm font-medium text-error-content hover:opacity-90">Confirm</button>` +
      `</div></div>`

    const finish = (result) => {
      document.removeEventListener("keydown", onKey, true)
      overlay.remove()
      resolve(result)
    }
    const onKey = (e) => {
      if (e.key === "Escape") {
        e.preventDefault()
        e.stopPropagation()
        finish(false)
      } else if (e.key === "Enter") {
        e.preventDefault()
        e.stopPropagation()
        finish(true)
      }
    }
    overlay.addEventListener("click", (e) => {
      if (e.target === overlay || e.target.closest("[data-claw-cancel]")) finish(false)
      else if (e.target.closest("[data-claw-ok]")) finish(true)
    })
    document.addEventListener("keydown", onKey, true)
    document.body.appendChild(overlay)
    overlay.querySelector("[data-claw-ok]")?.focus()
  })
}

// Install the global interceptor once (from app.js, like installCaretKeys). Runs
// in the capture phase so it beats LiveView's window-level (bubble-phase)
// phx-click handler and can suppress it until the user confirms.
export function installClawConfirm() {
  document.addEventListener(
    "click",
    (e) => {
      if (bypassNext) return
      const el = e.target.closest?.(`[${ATTR}]`)
      if (!el) return

      // Block LiveView's phx-click for now; we'll re-issue it on confirm.
      e.preventDefault()
      e.stopImmediatePropagation()

      clawConfirm(el.getAttribute(ATTR)).then((ok) => {
        if (!ok) return
        bypassNext = true
        try {
          el.click()
        } finally {
          bypassNext = false
        }
      })
    },
    true,
  )
}

function escapeHtml(value) {
  return String(value).replace(
    /[&<>"']/g,
    (char) => ({"&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;"})[char],
  )
}
