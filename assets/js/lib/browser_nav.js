// Fixed browser-toolbar navigation. Graph toggles the app's own pane so it
// cannot replace the content tab the agent is currently working in.
export function installBrowserNav(inv, activeId, origin, homeUrl, sid) {
  const on = (id, fn) => document.getElementById(id)?.addEventListener("click", fn)
  on("home", () => inv("browser_navigate", {tabId: activeId(), url: homeUrl}))
  on("pages", () => inv("browser_navigate", {tabId: activeId(), url: origin + "/browser/pages"}))
  on("back", () => inv("browser_back", {tabId: activeId()}))
  on("fwd", () => inv("browser_forward", {tabId: activeId()}))
  on("reload", () => inv("browser_reload", {tabId: activeId()}))
  on("activity", () => {
    try {
      localStorage.setItem("bc.browser.activity", JSON.stringify({sid, at: Date.now()}))
    } catch {
      inv("browser_app_navigate", {path: "/browse?activity=1"})
    }
  })
}
