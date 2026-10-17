// The downloads shelf — the left cluster of the chrome's bottom row. Rust's
// on_download hook (browser.rs) drives it through two window globals: a chip
// with a spinner while the file lands in ~/Downloads, then ✓ (click to reveal
// in Finder, resolved by id — never by a page-supplied path) or ✕ on failure.
// Finished chips fade out after 20s.
//
// Extracted from chrome.js on 10-16 (CODE_QUALITY_SWEEP Phase 8). `onStarted`
// is the one thing the shelf has to tell the tab strip: a download never fires
// page-load-finished, so the chrome clears the active tab's spinner when one
// begins.
//
// `deps`: {el, inv, onStarted()}
export function createDownloads({el, inv, onStarted}) {
  const downloads = [] // {id, name, state: "active" | "done" | "failed"}

  function render() {
    if (!el) return
    el.textContent = ""
    downloads.forEach((d) => {
      const chip = document.createElement("button")
      chip.type = "button"
      chip.className = "dl " + d.state
      chip.title = d.state === "done" ? "Reveal in Finder" : d.name
      if (d.state === "active") {
        const spin = document.createElement("span")
        spin.className = "spin"
        chip.appendChild(spin)
      } else {
        const mark = document.createElement("span")
        mark.textContent = d.state === "done" ? "✓" : "✕"
        chip.appendChild(mark)
      }
      const t = document.createElement("span")
      t.className = "t"
      t.textContent = d.name
      chip.appendChild(t)
      if (d.state === "done") {
        chip.onclick = () => inv("browser_reveal_download", {downloadId: d.id})
      }
      el.appendChild(chip)
    })
  }

  window.__onDownloadStarted = function (id, name) {
    downloads.unshift({id, name, state: "active"})
    if (onStarted) onStarted()
    render()
  }

  window.__onDownloadFinished = function (id, success) {
    const d = downloads.find((x) => x.id === id)
    if (d) d.state = success ? "done" : "failed"
    render()
    setTimeout(function () {
      const i = downloads.findIndex((x) => x.id === id)
      if (i >= 0) { downloads.splice(i, 1); render() }
    }, 20000)
  }

  return {render, count: () => downloads.length}
}
