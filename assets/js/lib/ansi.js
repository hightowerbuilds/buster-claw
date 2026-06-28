// Full-screen TUIs often fill empty cells with ANSI black. When an image-backed
// terminal is transparent, those black background instructions need to become
// the default transparent background instead of opaque painted cells.
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
      ? stripBlackBackgroundSgr(sequence, input.slice(csiStart + 2, csiEnd))
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

function stripBlackBackgroundSgr(sequence, paramsText) {
  if (paramsText === "") return sequence

  const params = paramsText.split(";")
  const kept = []
  let changed = false

  for (let i = 0; i < params.length; i++) {
    const param = params[i]

    if (param === "40" || isBlackColonBackground(param)) {
      changed = true
      continue
    }

    if (param === "48" && params[i + 1] === "5" && isBlackAnsiColor(params[i + 2])) {
      i += 2
      changed = true
      continue
    }

    if (param === "48" && params[i + 1] === "2" && isBlackRgb(params.slice(i + 2, i + 5))) {
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

function isBlackColonBackground(param) {
  if (!param.startsWith("48:")) return false

  const parts = param.split(":")
  if (parts[1] === "5") return isBlackAnsiColor(parts[2])
  if (parts[1] !== "2") return false

  return isBlackRgb(parts.slice(2).filter((part) => part !== "").slice(0, 3))
}

function isBlackAnsiColor(value) {
  if (!/^\d+$/.test(String(value || ""))) return false

  const index = Number.parseInt(value, 10)
  return index === 0 || index === 16
}

function isBlackRgb(values) {
  return values.length === 3 &&
    values.every((value) => /^\d+$/.test(String(value)) && Number.parseInt(value, 10) === 0)
}
