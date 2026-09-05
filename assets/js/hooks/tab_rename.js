// Tab renaming is independent of navigation and native browser ownership.
export const TabRename = {
  // ----- Double-click rename -----
  onRenameStart(e) {
    const tab = e.target.closest("[data-path]")
    if (!tab) return
    if (tab.getAttribute("data-path") === "/duty") return
    e.preventDefault()
    this.editingPath = tab.getAttribute("data-path")
    this.render()
  },
  onRenameKeydown(e) {
    if (!e.target.closest("[data-tab-edit]")) return
    if (e.key === "Enter") {
      e.preventDefault()
      this.commitRename(e.target.value)
    } else if (e.key === "Escape") {
      e.preventDefault()
      this.cancelRename()
    }
  },
  onRenameBlur(e) {
    const input = e.target.closest("[data-tab-edit]")
    if (input) this.commitRename(input.value)
  },
  commitRename(value) {
    if (!this.editingPath) return
    const path = this.editingPath
    this.editingPath = null
    const name = String(value || "").trim()
    if (name) {
      const tabs = this.load()
      const tab = tabs.find((t) => t.path === path)
      if (tab) {
        tab.label = name
        this.save(tabs)
      }
    }
    this.render()
  },
  cancelRename() {
    this.editingPath = null
    this.render()
  },
}
