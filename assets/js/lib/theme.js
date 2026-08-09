// ---- Terminal color themes -------------------------------------------------
// The palettes are NOT defined here. `BusterClaw.TerminalTheme` owns the list and
// the root layout renders it into <meta name="bc-term-palettes">; this file reads
// it and applies it. There used to be a copy here and a second partial copy in
// AppearanceLive, kept in step by a comment, with no test on either — so removing
// a theme could leave a dead palette in one language or a swatch selecting a
// theme that no longer existed in the other.
//
// The chosen key is stored in localStorage["bc:term-theme"]. "industrial" arrives
// with a null palette, meaning token-derived: it is resolved from the app's live
// CSS custom properties so it tracks the light/dark switch, which is the one thing
// Elixir cannot do for it.
const TERM_THEME_KEY = "bc:term-theme"
const TERM_THEME_DEFAULT = "industrial"

// Parsed once. The <meta> is server-rendered and cannot change without a reload,
// so re-reading it per terminal or per theme switch would be pure work.
let TERM_THEMES = null

function termThemes() {
  if (TERM_THEMES) return TERM_THEMES
  const meta = document.querySelector('meta[name="bc-term-palettes"]')
  try {
    TERM_THEMES = JSON.parse(meta?.content || "{}")
  } catch (_e) {
    // A malformed payload must not take the terminal with it: an empty table
    // means every key resolves token-derived, which is the default theme and is
    // always legible.
    TERM_THEMES = {}
  }
  return TERM_THEMES
}

// The stored key, resolved against the themes that actually exist. Six presets
// were removed on 08-09, so anyone who had picked Dracula has a stale key in
// localStorage; without this they would keep a legible terminal (the palette
// lookup falls through to token-derived) but the picker would highlight nothing,
// which reads as the setting being lost rather than retired.
export function currentTermTheme() {
  const stored = localStorage.getItem(TERM_THEME_KEY)
  return stored && stored in termThemes() ? stored : TERM_THEME_DEFAULT
}

function termThemePalette(key) {
  const preset = termThemes()[key]
  if (preset) return preset
  // "industrial" (or unknown) — match the live app surface via CSS tokens.
  const css = getComputedStyle(document.documentElement)
  const token = (name, fallback) => (css.getPropertyValue(name).trim() || fallback)
  const bg = token("--color-base-100", "#121212")
  const fg = token("--color-base-content", "#fafafa")
  const accent = token("--color-primary", "#ff4d1c")
  return {
    background: bg, foreground: fg, cursor: accent, cursorAccent: bg,
    selectionBackground: accent, selectionForeground: bg
  }
}

// xterm theme palette, made see-through when a terminal background image is
// active so the image shows behind the text (the `__bcBgActive` flag is set per
// terminal by the TerminalView hook).
export function termThemeWithBackground(bgActive) {
  const palette = termThemePalette(currentTermTheme())
  return bgActive ? {...palette, background: "rgba(0,0,0,0)"} : palette
}

// Open xterm instances, so a theme change applies to every live terminal.
export const liveTerminals = new Set()

export function applyTermTheme(key) {
  const palette = termThemePalette(key)
  liveTerminals.forEach((t) => {
    t.options.theme = t.__bcBgActive ? {...palette, background: "rgba(0,0,0,0)"} : palette
  })
}

function setTermTheme(key) {
  if (!key) return
  localStorage.setItem(TERM_THEME_KEY, key)
  applyTermTheme(key)
}

window.addEventListener("bc:set-term-theme", (e) => setTermTheme(e.target.dataset.termTheme))
window.addEventListener("storage", (e) => {
  if (e.key === TERM_THEME_KEY) applyTermTheme(currentTermTheme())
})
// When the app light/dark theme flips, refresh terminals that track it.
window.addEventListener("phx:set-theme", () => {
  if (currentTermTheme() === "industrial") setTimeout(() => applyTermTheme("industrial"), 0)
})
