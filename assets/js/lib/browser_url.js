// URL heuristics shared by the embedded browser's chrome (assets/js/chrome.js)
// and the EmbeddedBrowser hook (assets/js/hooks/browser.js). Single source of
// truth — these used to be duplicated across the two and drifted silently.
//
// All functions take `origin` (the Phoenix origin) explicitly so they stay pure
// and testable under `bun test`.

// Address-bar input → full URL, or null when empty.
// Scheme kept as-is; absolute workspace path → /ws/file; bare domain → https://.
export function resolve(raw, origin) {
  const v = (raw || "").trim()
  if (v === "") return null
  if (/^[a-z]+:\/\//i.test(v)) return v
  if (v.startsWith("/")) return `${origin}/ws/file?path=${encodeURIComponent(v)}`
  return `https://${v}`
}

// Friendly address for the bar: our own pages display as their workspace path
// (or blank for the homepage); everything else displays verbatim.
export function display(u, origin) {
  try {
    const url = new URL(u, origin)
    if (url.origin === origin) {
      if (url.pathname === "/browser/home") return ""
      if (url.pathname === "/ws/file") return url.searchParams.get("path") || u
      if (url.pathname === "/browser/workspace") return url.searchParams.get("q") || "/"
    }
    return u
  } catch (e) {
    return u
  }
}

// Short label for a tab when no document title is available.
export function deriveLabel(u, origin) {
  if (!u || u === `${origin}/browser/home`) return "New tab"
  try {
    const url = new URL(u, origin)
    if (url.origin === origin) {
      if (url.pathname === "/browser/home") return "New tab"
      if (url.pathname === "/ws/file") {
        const p = url.searchParams.get("path") || "/"
        return p.split("/").filter(Boolean).pop() || "Workspace"
      }
      if (url.pathname === "/browser/workspace") return "Workspace"
    }
    return url.hostname.replace(/^www\./, "") || u
  } catch (e) {
    return u
  }
}

// Host favicon for a tab, matching BusterClaw.Bookmarks.favicon_url/1. Only for
// real http(s) hosts — pages on our own origin get no favicon.
export function faviconFor(u, origin) {
  try {
    const url = new URL(u, origin)
    if (url.origin === origin) return null
    if (url.protocol !== "http:" && url.protocol !== "https:") return null
    if (!url.hostname) return null
    return `https://www.google.com/s2/favicons?domain=${encodeURIComponent(url.hostname)}&sz=64`
  } catch (e) {
    return null
  }
}
