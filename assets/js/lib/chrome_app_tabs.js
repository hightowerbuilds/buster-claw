// The browser chrome's row of app tabs — Home plus every open app tab.
//
// The native browser webviews paint over the app's DOM, tab strip included, so
// on /browse this row IS the tab strip. Until 09-13 it could switch tabs but not
// close them, and the Browser tab you were on had no × anywhere you could reach.
// The close rule is `closeTabIn` from lib/tabs.js — the same one the DOM strip
// uses — so the two cannot disagree about which tab takes the screen.
//
// WHAT IT CANNOT DO FROM HERE: tear the browser surface down. The chrome's
// capability grants `browser_app_navigate` but not `browser_close` (only the
// main window may close surfaces), so closing the tab you are on navigates the
// main window to the next tab, and that page's TabStrip hides the surface on
// arrival (`reconcileBrowserSurfaces`). The web tabs are hidden, not destroyed —
// what switching away does too — and the saved session restores them either way.
//
// Extracted from chrome.js, which is FROZEN at its size cap: a new feature there
// either fits or takes an extraction, and this row was the separable part.
import {browserAppTab, chromeChips, closeTabIn, loadTabs, saveTabs, tabDestination} from "./tabs.js"

export function renderAppTabChips(el, sid, inv) {
  if (!el) return
  el.textContent = ""
  const rerender = () => renderAppTabChips(el, sid, inv)
  for (const chip of chromeChips(loadTabs(), browserAppTab(sid))) {
    el.appendChild(chipElement(chip, sid, inv, rerender))
  }
}

function chipElement(chip, sid, inv, rerender) {
  const name = chip.label || chip.path
  const wrap = document.createElement("span")
  wrap.className = "atab" + (chip.current ? " current" : "")

  const label = document.createElement("button")
  label.type = "button"
  label.className = "atab-label"
  label.title = chip.current ? "You are here" : "Switch to " + name
  label.textContent = name
  if (!chip.current) {
    label.onclick = () => inv("browser_app_navigate", {path: tabDestination(chip) || "/"})
  }
  wrap.appendChild(label)

  if (chip.closable) {
    const close = document.createElement("button")
    close.type = "button"
    close.className = "atab-x"
    close.title = "Close tab"
    close.setAttribute("aria-label", "Close " + name)
    close.textContent = "×"
    close.onclick = (event) => {
      event.stopPropagation()
      closeAppTab(chip, sid, inv, rerender)
    }
    wrap.appendChild(close)
  }

  return wrap
}

function closeAppTab(chip, sid, inv, rerender) {
  const {tabs, closed, next} = closeTabIn(loadTabs(), chip.path)
  if (!closed) return
  saveTabs(tabs)

  // Re-read "here" at click time: the row repaints on focus and a slow tick, so
  // the chip's own flag can be seconds stale after a switch between two
  // browser tabs that share this surface.
  const here = browserAppTab(sid)
  const onScreen = here ? chip.path === here : chip.current

  if (onScreen) {
    inv("browser_app_navigate", {path: tabDestination(next) || "/"})
  } else {
    rerender()
  }
}
