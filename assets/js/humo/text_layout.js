// Pure word-wrap + page-fit for the Humo text texture: given a measure
// function (px width of a string), wrap words into lines that fit maxWidth,
// and decide whether they still fit a page of maxLines. Extracted from the
// render path so it's bun-testable with a stub measure.
export function layoutLines(measure, words, maxWidth) {
  const lines = []
  let line = ""
  for (const w of words) {
    const probe = line ? line + " " + w : w
    if (line && measure(probe) > maxWidth) {
      lines.push(line)
      line = w
    } else {
      line = probe
    }
  }
  if (line) lines.push(line)
  return lines
}

// Page-fit check for the smoke readout: words fill a page until the wrap
// would exceed maxLines — the caller then dissolves the page and starts the
// next one ("read out to a point, then disappear, making room").
export function layoutPage(measure, words, maxWidth, maxLines) {
  const lines = layoutLines(measure, words, maxWidth)
  return {lines, fits: lines.length <= maxLines}
}
