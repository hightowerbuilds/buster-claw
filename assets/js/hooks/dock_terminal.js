import {openNewTerminalTab} from "../lib/tabs.js"

// The footer dock's Terminal button opens a NEW shell on every click — a fresh
// session key in a new tab, exactly like Cmd-T (`openNewTerminalTab`). A plain
// `/terminal` navigation would reattach to the shared "main" shell, so the
// button is a hook-driven action instead of a tab link.
export const DockNewTerminal = {
  mounted() {
    this.onClick = (e) => {
      e.preventDefault()
      openNewTerminalTab()
    }
    this.el.addEventListener("click", this.onClick)
  },
  destroyed() {
    this.el.removeEventListener("click", this.onClick)
  },
}
