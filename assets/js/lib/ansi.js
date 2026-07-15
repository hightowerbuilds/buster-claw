// Full-screen TUIs (Claude Code, opencode, vim, …) fill their surface with the
// terminal's *default dark background* — but rarely pure black. Claude paints a
// near-black neutral (e.g. 48;2;26;26;26), opencode its own dark grey, and so on.
// When a background (image or shader) is active the emulator is transparent, and
// those dark fills need to become the default transparent background too —
// otherwise the TUI reads as an opaque dark rectangle floating over the picture.
//
// So we strip background SGR whose color is *dark and roughly neutral*: black,
// the dark end of the 256-color grey ramp, and near-grey RGB below a brightness
// threshold. Clearly-colored backgrounds (a teal Solarized base, a saturated
// selection highlight) are kept — those are deliberate, not "the wall behind me."
//
// Only pure black is a hard case that older code caught; broadening to
// dark-neutral is what lets a real TUI show a shader/image through it.

// A background this dark (max channel) and this close to neutral (max−min) is
// the app painting "the default dark background", not a colored element.
const DARK_MAX = 64
const NEUTRAL_SPREAD = 28

export function stripTransparentBackgroundPaint(data, state) {
  const input = (state.pending || "") + String(data || "")
  state.pending = ""

  let output = ""
  let offset = 0

  while (offset < input.length) {
    const csiStart = input.indexOf("\x1b[", offset)
    if (csiStart === -1) {
      output += input.slice(offset)
      break
    }

    output += input.slice(offset, csiStart)

    const csiEnd = findCsiEnd(input, csiStart + 2)
    if (csiEnd === -1) {
      state.pending = input.slice(csiStart)
      break
    }

    const sequence = input.slice(csiStart, csiEnd + 1)
    output += input[csiEnd] === "m"
      ? stripDarkBackgroundSgr(sequence, input.slice(csiStart + 2, csiEnd))
      : sequence
    offset = csiEnd + 1
  }

  return output
}

export function flushTransparentBackgroundPaint(state) {
  const pending = state.pending || ""
  state.pending = ""
  return pending
}

function findCsiEnd(input, offset) {
  for (let i = offset; i < input.length; i++) {
    const code = input.charCodeAt(i)
    if (code >= 0x40 && code <= 0x7e) return i
  }

  return -1
}

function stripDarkBackgroundSgr(sequence, paramsText) {
  if (paramsText === "") return sequence

  const params = paramsText.split(";")
  const kept = []
  let changed = false

  for (let i = 0; i < params.length; i++) {
    const param = params[i]

    // ANSI black background (40) or a colon-form background color.
    if (param === "40" || isDarkColonBackground(param)) {
      changed = true
      continue
    }

    if (param === "48" && params[i + 1] === "5" && isDarkAnsiColor(params[i + 2])) {
      i += 2
      changed = true
      continue
    }

    if (param === "48" && params[i + 1] === "2" && isDarkNeutralRgb(params.slice(i + 2, i + 5))) {
      i += 4
      changed = true
      continue
    }

    kept.push(param)
  }

  if (!changed) return sequence
  if (kept.length === 0) return ""

  return `\x1b[${kept.join(";")}m`
}

function isDarkColonBackground(param) {
  if (!param.startsWith("48:")) return false

  const parts = param.split(":")
  if (parts[1] === "5") return isDarkAnsiColor(parts[2])
  if (parts[1] !== "2") return false

  return isDarkNeutralRgb(parts.slice(2).filter((part) => part !== "").slice(0, 3))
}

// 256-color: pure black (0, 16) and the dark end of the 24-step grey ramp
// (232 ≈ #080808 … 237 ≈ #3a3a3a). 238+ is light enough to keep.
function isDarkAnsiColor(value) {
  if (!/^\d+$/.test(String(value || ""))) return false

  const index = Number.parseInt(value, 10)
  return index === 0 || index === 16 || (index >= 232 && index <= 237)
}

// A dark, roughly-neutral RGB triple — the shape of a "default background" fill.
function isDarkNeutralRgb(values) {
  if (values.length !== 3) return false
  if (!values.every((value) => /^\d+$/.test(String(value)))) return false

  const [r, g, b] = values.map((value) => Number.parseInt(value, 10))
  const max = Math.max(r, g, b)
  const min = Math.min(r, g, b)
  return max <= DARK_MAX && max - min <= NEUTRAL_SPREAD
}
