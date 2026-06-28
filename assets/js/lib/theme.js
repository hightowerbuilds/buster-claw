// ---- Terminal color themes -------------------------------------------------
// xterm palettes selectable from Settings → Appearance. The chosen key is
// stored in localStorage["bc:term-theme"]; "industrial" derives its colors from
// the app's CSS tokens so it tracks the light/dark app theme.
const TERM_THEME_KEY = "bc:term-theme"
const TERM_THEME_DEFAULT = "industrial"
const TERM_THEMES = {
  industrial: null, // sentinel — resolved from CSS tokens, see termThemePalette
  light: {
    background: "#fafafa", foreground: "#1a1a1a", cursor: "#1a1a1a",
    cursorAccent: "#fafafa", selectionBackground: "#c7d2fe", selectionForeground: "#1a1a1a"
  },
  solarized: {
    background: "#002b36", foreground: "#839496", cursor: "#93a1a1",
    cursorAccent: "#002b36", selectionBackground: "#073642",
    black: "#073642", red: "#dc322f", green: "#859900", yellow: "#b58900",
    blue: "#268bd2", magenta: "#d33682", cyan: "#2aa198", white: "#eee8d5",
    brightBlack: "#586e75", brightRed: "#cb4b16", brightGreen: "#586e75", brightYellow: "#657b83",
    brightBlue: "#839496", brightMagenta: "#6c71c4", brightCyan: "#93a1a1", brightWhite: "#fdf6e3"
  },
  dracula: {
    background: "#282a36", foreground: "#f8f8f2", cursor: "#f8f8f2",
    cursorAccent: "#282a36", selectionBackground: "#44475a",
    black: "#21222c", red: "#ff5555", green: "#50fa7b", yellow: "#f1fa8c",
    blue: "#bd93f9", magenta: "#ff79c6", cyan: "#8be9fd", white: "#f8f8f2",
    brightBlack: "#6272a4", brightRed: "#ff6e6e", brightGreen: "#69ff94", brightYellow: "#ffffa5",
    brightBlue: "#d6acff", brightMagenta: "#ff92df", brightCyan: "#a4ffff", brightWhite: "#ffffff"
  },
  nord: {
    background: "#2e3440", foreground: "#d8dee9", cursor: "#d8dee9",
    cursorAccent: "#2e3440", selectionBackground: "#434c5e",
    black: "#3b4252", red: "#bf616a", green: "#a3be8c", yellow: "#ebcb8b",
    blue: "#81a1c1", magenta: "#b48ead", cyan: "#88c0d0", white: "#e5e9f0",
    brightBlack: "#4c566a", brightRed: "#bf616a", brightGreen: "#a3be8c", brightYellow: "#ebcb8b",
    brightBlue: "#81a1c1", brightMagenta: "#b48ead", brightCyan: "#8fbcbb", brightWhite: "#eceff4"
  },
  gruvbox: {
    background: "#282828", foreground: "#ebdbb2", cursor: "#ebdbb2",
    cursorAccent: "#282828", selectionBackground: "#504945",
    black: "#282828", red: "#cc241d", green: "#98971a", yellow: "#d79921",
    blue: "#458588", magenta: "#b16286", cyan: "#689d6a", white: "#a89984",
    brightBlack: "#928374", brightRed: "#fb4934", brightGreen: "#b8bb26", brightYellow: "#fabd2f",
    brightBlue: "#83a598", brightMagenta: "#d3869b", brightCyan: "#8ec07c", brightWhite: "#ebdbb2"
  },
  monokai: {
    background: "#272822", foreground: "#f8f8f2", cursor: "#f8f8f0",
    cursorAccent: "#272822", selectionBackground: "#49483e",
    black: "#272822", red: "#f92672", green: "#a6e22e", yellow: "#f4bf75",
    blue: "#66d9ef", magenta: "#ae81ff", cyan: "#a1efe4", white: "#f8f8f2",
    brightBlack: "#75715e", brightRed: "#f92672", brightGreen: "#a6e22e", brightYellow: "#f4bf75",
    brightBlue: "#66d9ef", brightMagenta: "#ae81ff", brightCyan: "#a1efe4", brightWhite: "#f9f8f5"
  },
  "tokyo-night": {
    background: "#1a1b26", foreground: "#c0caf5", cursor: "#c0caf5",
    cursorAccent: "#1a1b26", selectionBackground: "#283457",
    black: "#15161e", red: "#f7768e", green: "#9ece6a", yellow: "#e0af68",
    blue: "#7aa2f7", magenta: "#bb9af7", cyan: "#7dcfff", white: "#a9b1d6",
    brightBlack: "#414868", brightRed: "#f7768e", brightGreen: "#9ece6a", brightYellow: "#e0af68",
    brightBlue: "#7aa2f7", brightMagenta: "#bb9af7", brightCyan: "#7dcfff", brightWhite: "#c0caf5"
  },
  matrix: {
    background: "#000000", foreground: "#00ff41", cursor: "#00ff41",
    cursorAccent: "#000000", selectionBackground: "#0f3d0f"
  }
}

export function currentTermTheme() {
  return localStorage.getItem(TERM_THEME_KEY) || TERM_THEME_DEFAULT
}

function termThemePalette(key) {
  const preset = TERM_THEMES[key]
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
