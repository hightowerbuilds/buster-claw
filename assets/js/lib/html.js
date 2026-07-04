// Escape a string for safe interpolation into innerHTML (tab labels, terminal
// error text). Shared by the terminal and tab-strip hooks so the two agree on
// exactly which characters are entity-encoded.
export function escapeHtml(value) {
  return String(value).replace(/[&<>"']/g, (c) =>
    ({"&": "&amp;", "<": "&lt;", ">": "&gt;", "\"": "&quot;", "'": "&#39;"}[c]))
}
