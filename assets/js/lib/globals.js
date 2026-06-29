// Page-level glue not tied to any one LiveView hook: the documents sidebar
// open/closed state (shared across tabs via localStorage) and the
// "copy terminal command" buttons used throughout the user guide / docs.

const documentsSidebarStorageKey = "bc:documents-sidebar"
const setDocumentsSidebarState = (state) => {
  const nextState = state === "closed" ? "closed" : "open"
  document.documentElement.dataset.documentsSidebar = nextState
  localStorage.setItem(documentsSidebarStorageKey, nextState)
}

setDocumentsSidebarState(localStorage.getItem(documentsSidebarStorageKey))

window.addEventListener("storage", (event) => {
  if (event.key === documentsSidebarStorageKey) setDocumentsSidebarState(event.newValue)
})

window.addEventListener("bc:toggle-documents-sidebar", () => {
  const nextState = document.documentElement.dataset.documentsSidebar === "closed" ? "open" : "closed"
  setDocumentsSidebarState(nextState)
})

window.addEventListener("click", async (event) => {
  const button = event.target.closest("[data-terminal-command-copy]")
  if (!button) return

  event.preventDefault()
  const command = button.dataset.terminalCommandCopy || ""
  const label = button.querySelector("[data-terminal-command-copy-label]")

  try {
    await navigator.clipboard.writeText(command)
    if (label) {
      const previous = label.textContent
      label.textContent = "Copied"
      window.setTimeout(() => { label.textContent = previous || "Copy" }, 1200)
    }
  } catch (_e) {
    if (label) {
      const previous = label.textContent
      label.textContent = "Failed"
      window.setTimeout(() => { label.textContent = previous || "Copy" }, 1200)
    }
  }
})
