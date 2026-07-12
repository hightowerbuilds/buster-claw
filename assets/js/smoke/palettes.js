// Built-in 3-color palettes per shader design (used when custom colors are off)
// and hex→uniform helpers. The three colors are, per design: a base/background,
// a mid/accent, and a highlight — each shader uses them in its own natural way.
export const SHADER_PALETTES = {
  smoke: ["#0e0e0e", "#ff4d1c", "#f4f1ea"],
  waves: ["#080a10", "#5a99e6", "#a8c8f2"],
  mandel: ["#04060d", "#3b6ea5", "#ffd089"],
  weather: ["#1a2838", "#6b7a89", "#eef4f8"],
}

export const DEFAULT_PALETTE = SHADER_PALETTES.smoke

export function hexToRgb(hex) {
  const h = String(hex || "").replace("#", "").trim()
  const n = h.length === 3 ? h.split("").map((c) => c + c).join("") : h.padEnd(6, "0").slice(0, 6)
  const int = parseInt(n, 16)
  if (isNaN(int)) return [0, 0, 0]
  return [((int >> 16) & 255) / 255, ((int >> 8) & 255) / 255, (int & 255) / 255]
}

// [hexA, hexB, hexC] → {a, b, c} of [r,g,b] floats for packUniforms.
export function colorsForUniform(hexes) {
  return {a: hexToRgb(hexes[0]), b: hexToRgb(hexes[1]), c: hexToRgb(hexes[2])}
}
