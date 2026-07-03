// URL heuristics shared by the embedded browser's chrome (assets/js/chrome.js)
// and the EmbeddedBrowser hook (assets/js/hooks/browser.js). Single source of
// truth — these used to be duplicated across the two and drifted silently.
//
// All functions take `origin` (the Phoenix origin) explicitly so they stay pure
// and testable under `bun test`.

export const DEFAULT_SEARCH_URL = "https://duckduckgo.com/?q="

// Address-bar input → full URL, or null when empty.
// Scheme kept as-is; absolute workspace path → /ws/file; text that can't be a
// host (spaces, or no dot and not localhost) → search engine; bare domain →
// https://. Pass `opts.searchUrl` (a prefix the query is appended to) to use a
// non-default engine.
export function resolve(raw, origin, opts = {}) {
  const v = (raw || "").trim()
  if (v === "") return null
  if (/^[a-z]+:\/\//i.test(v)) return v
  if (v.startsWith("/")) return `${origin}/ws/file?path=${encodeURIComponent(v)}`
  if (looksLikeSearch(v)) return (opts.searchUrl || DEFAULT_SEARCH_URL) + encodeURIComponent(v)
  return `https://${v}`
}

// Search vs URL, the way every omnibox since the awesome bar has decided it:
// whitespace can never be a host; a single dotless word is a search unless
// it's localhost (with or without a port).
function looksLikeSearch(v) {
  if (/\s/.test(v)) return true
  const host = v.split(/[/?#]/, 1)[0]
  if (/^localhost(:\d+)?$/i.test(host)) return false
  return !host.includes(".")
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

// Host favicon for a tab: the local /browser/favicon endpoint (disk-cached by
// BusterClaw.Favicons; matches Bookmarks.favicon_url/1), so visited hosts are
// never reported to a third-party icon service. Only for real http(s) hosts —
// pages on our own origin get no favicon.
export function faviconFor(u, origin) {
  try {
    const url = new URL(u, origin)
    if (url.origin === origin) return null
    if (url.protocol !== "http:" && url.protocol !== "https:") return null
    if (!url.hostname) return null
    return `${origin}/browser/favicon?host=${encodeURIComponent(url.hostname)}`
  } catch (e) {
    return null
  }
}
