// The Mix menu bar's open/close behaviour, and nothing else.
//
// Each menu is a `<details>`/`<summary>` pair, so the browser already handles
// click-to-open and keyboard focus. This hook adds only the three things a
// desktop menu bar has that `<details>` does not:
//
//   1. clicking outside closes every menu
//   2. Escape closes every menu
//   3. opening one closes its siblings
//
// It never writes markup and never reads state off the DOM — the server owns
// every item in here, which is why the element carries no `phx-update="ignore"`.
// A LiveView re-render drops the `open` attribute and closes the menus, which is
// the behaviour you want after choosing something.

const MENU = "[data-studio-menu]"

export default {
  mounted() {
    this.menus = () => [...this.el.querySelectorAll(MENU)]

    // Opening one closes the others. `toggle` fires on the element whose state
    // changed, so this only has to act when that change was an OPEN.
    this.onToggle = (e) => {
      const opened = e.target
      if (!opened.open || !opened.matches(MENU)) return
      this.menus().forEach((m) => {
        if (m !== opened) m.open = false
      })
    }

    // Capture phase, because a menu item's own click closes the menu that
    // contains it — and by the time a bubbled listener ran, LiveView may
    // already have replaced the node the event came from.
    this.onDocClick = (e) => {
      if (this.el.contains(e.target)) {
        // Inside: a click on a summary is the browser toggling a menu and must
        // be left alone. A click on an item is a choice, so everything closes.
        if (!e.target.closest("summary")) this.closeAll()
        return
      }
      this.closeAll()
    }

    this.onKey = (e) => {
      if (e.key === "Escape") this.closeAll()
    }

    this.el.addEventListener("toggle", this.onToggle, true)
    document.addEventListener("click", this.onDocClick, true)
    document.addEventListener("keydown", this.onKey)
  },

  destroyed() {
    document.removeEventListener("click", this.onDocClick, true)
    document.removeEventListener("keydown", this.onKey)
  },

  closeAll() {
    // Submenus too: `details` inside `details` stay open on their own otherwise,
    // so the next opening of a menu would show a nested list already expanded.
    this.el.querySelectorAll("details").forEach((d) => {
      d.open = false
    })
  },
}
