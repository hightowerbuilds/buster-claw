const base = path => String(path || "").split(/[?#]/)[0]
const speech = "/settings?tab=speech"
// Integrations was deleted 10-17; a remembered Settings subpage lands on the
// first tab instead of a route that no longer exists.
const appearance = "/appearance"

// A retired pane is replaced in place. Its neighbor keeps its exact path, so
// native browser surfaces and terminal sessions stay with the same pane.
export function recoverRetiredRoute(path) {
  if (base(path) === "/voice") return speech
  if (base(path) === "/integrations") return appearance
  if (base(path) !== "/split") return path
  const url = new URL(path, "http://app.local")
  let changed = false
  for (const side of ["left", "right"]) {
    if (base(url.searchParams.get(side)) !== "/voice") continue
    url.searchParams.set(side, speech)
    changed = true
  }
  return changed ? `${url.pathname}${url.search}${url.hash}` : path
}

export function recoverRetiredTabs(tabs) {
  if (!Array.isArray(tabs)) return []
  const recovered = tabs.map(tab => {
    if (!tab || typeof tab.path !== "string") return tab
    if (base(tab.path) === "/voice") return {...tab, path: "/settings", href: speech, label: "Settings"}
    const path = recoverRetiredRoute(tab.path)
    if (path !== tab.path) {
      const params = new URL(tab.path, "http://app.local").searchParams
      const panes = ["left", "right"].map((side, index) => {
        const oldPath = params.get(side)
        const pane = tab.panes?.[index] || {path: oldPath, label: tab.label?.split(" | ")[index]}
        return base(oldPath) === "/voice"
          ? {...pane, path: speech, label: "Speech", href: undefined}
          : {...pane, path: oldPath}
      })
      const label = panes.map(pane => pane.label || base(pane.path)).join(" | ")
      return {...tab, path, panes, label}
    }
    return base(tab.href) === "/voice" ? {...tab, href: speech} : tab
  })
  // The recovered speech tab belongs to the existing Settings group.
  return recovered.filter((tab, index) => tab?.path !== "/settings" ||
    recovered.findIndex(item => item?.path === "/settings") === index)
}
