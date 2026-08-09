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

// ---- The custom theme, edited live -----------------------------------------
// The <meta> is server-rendered and cannot change without a reload, so an edit in
// Settings arrives as a server event instead. Two jobs: patch the cached table so
// the terminal restyles on this page as the colour picker moves, and mirror the
// palette into localStorage so OTHER windows' terminals pick it up through the
// `storage` listener already below. Durable storage is `Settings` on the server;
// localStorage here is only the cross-window nudge, which is why load-time trusts
// the <meta> and not this.
const TERM_CUSTOM_KEY = "bc:term-custom"

function patchCustom(palette) {
  const table = termThemes()
  if (palette) {
    table.custom = palette
  } else {
    delete table.custom
  }
  applyTermTheme(currentTermTheme())
}

window.addEventListener("phx:bc-term-custom", (e) => {
  const palette = e.detail?.palette || null
  patchCustom(palette)
  try {
    if (palette) {
      localStorage.setItem(TERM_CUSTOM_KEY, JSON.stringify(palette))
    } else {
      localStorage.removeItem(TERM_CUSTOM_KEY)
    }
  } catch (_e) {
    // A full or blocked localStorage costs cross-window sync, not the edit — the
    // palette is already saved server-side and this page has already applied it.
  }
})
// ---- Wear this theme now ---------------------------------------------------
// The server-side counterpart of `bc:set-term-theme` (a click). A command has no
// socket and the selected theme lives in localStorage, so `BusterClaw.TerminalPaint`
// broadcasts and ChromeHook pushes this. One event does both jobs, because from
// here selecting and painting are the same act: know the palette, then wear it.
const TERM_AGENT_KEY = "bc:term-agent"

window.addEventListener("phx:bc-term-apply", (e) => {
  const key = e.detail?.key
  const palette = e.detail?.palette || null
  if (!key) return

  if (palette) {
    termThemes()[key] = palette
    try {
      // Mirror for other windows, the same nudge the custom palette uses. Only
      // the agent slot is mirrored: presets are already in the server-rendered
      // <meta>, and the operator's custom slot has its own key above.
      if (key === "agent") localStorage.setItem(TERM_AGENT_KEY, JSON.stringify(palette))
    } catch (_e) {
      // Cross-window sync is the only casualty; this window has already applied.
    }
  }

  setTermTheme(key)
})

window.addEventListener("storage", (e) => {
  if (e.key === TERM_THEME_KEY) applyTermTheme(currentTermTheme())
  if (e.key === TERM_AGENT_KEY) {
    try {
      const table = termThemes()
      if (e.newValue) {
        table.agent = JSON.parse(e.newValue)
      } else {
        delete table.agent
      }
      applyTermTheme(currentTermTheme())
    } catch (_e) {
      // A malformed write from another window is ignored rather than dropping
      // this window's working palette.
    }
  }
  if (e.key === TERM_CUSTOM_KEY) {
    try {
      patchCustom(e.newValue ? JSON.parse(e.newValue) : null)
    } catch (_e) {
      // Ignore a malformed write from another window rather than dropping this
      // window's working terminal.
    }
  }
})
// When the app light/dark theme flips, refresh terminals that track it.
window.addEventListener("phx:set-theme", () => {
  if (currentTermTheme() === "industrial") setTimeout(() => applyTermTheme("industrial"), 0)
})
