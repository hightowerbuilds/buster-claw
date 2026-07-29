// DTMF — the real ITU-T Q.23 frequency grid, because the dialpad belongs to a
// phone-company product and "decorative" stops being an excuse the moment it
// makes sound. Each key is one low-group (row) + one high-group (column) tone
// played together; that pair IS the standard, so this table is not tunable
// taste, it's a spec (SOUND_ROADMAP group D).
const ROWS = [697, 770, 852, 941]
const COLS = [1209, 1336, 1477]

const LAYOUT = [
  ["1", "2", "3"],
  ["4", "5", "6"],
  ["7", "8", "9"],
  ["*", "0", "#"],
]

export const DTMF = Object.fromEntries(
  LAYOUT.flatMap((row, r) => row.map((key, c) => [key, [ROWS[r], COLS[c]]]))
)

// One key's tone pair, or null for anything that isn't a dialpad key.
export function dtmfPair(key) {
  return DTMF[key] || null
}
