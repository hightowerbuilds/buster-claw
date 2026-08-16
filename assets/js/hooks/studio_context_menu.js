// Right-click menu for the Studio sidebar: Info, Add to new audio, Delete.
//
// The menu is a component-rendered element under `phx-update="ignore"`; this
// hook owns its position, visibility, which items are offered, and the delete
// confirm state. Deleting is irreversible, so the first click ARMS the button
// ("Really delete?") and only the second click pushes — an inline two-step
// instead of a native confirm(), which would block the webview's event loop.
//
// `contextmenu` binds on the document, scoped by existence: this element only
// exists while the Studio tab is open (same argument as StudioKeys), and only a
// press on a sidebar item hijacks the native menu.
//
// ## Which items appear
//
// The server decides, per row, via data attributes — `data-deletable` (there is
// a file of YOURS to remove) and `data-sourceable` (it is a real audio file, so
// it has facts to show and can become a clip). The hook only reads them. An
// arrangement offers Delete but not Info; a built-in chime is the reverse.

export const StudioContextMenu = {
  mounted() {
    // Missing nodes become inert stand-ins rather than nulls. A renamed data
    // attribute once made one of these null, and the TypeError thrown here in
    // mounted() killed the WHOLE hook — contextmenu listener included — so the
    // menu silently stopped existing rather than losing one item. Degrade.
    const item = (sel) => this.el.querySelector(sel) || document.createElement("button")

    this.items = {
      info: item("[data-ctx-info]"),
      rename: item("[data-ctx-rename]"),
      newMix: item("[data-ctx-new-mix]"),
      delete: item("[data-ctx-delete]"),
      duplicateClip: item("[data-ctx-duplicate-clip]"),
      removeClip: item("[data-ctx-remove-clip]"),
    }
    this.renameInput = item("[data-ctx-rename-input]")

    this.targetId = null
    this.armed = false

    this.onContext = (e) => {
      // Clips first: a clip block sits inside the arranger, never inside the
      // sidebar, so the two selectors cannot both match — but checking the more
      // specific one first keeps that true if the markup ever nests.
      const clip = e.target.closest("[data-clip]")
      if (clip) {
        e.preventDefault()
        this.openClip(clip)
        return
      }

      const row = e.target.closest("[data-studio-source]")
      if (!row) {
        this.hide()
        return
      }
      e.preventDefault()
      this.open(row)
    }
    // Capture phase, so a click that selects another source still dismisses.
    this.onAway = (e) => {
      if (!this.el.contains(e.target)) this.hide()
    }
    this.onKey = (e) => {
      if (e.key === "Escape") this.hide()
    }
    // One scroll of the sidebar and an anchored menu is pointing at the wrong
    // row, so it closes rather than lying about what it acts on.
    this.onScroll = () => this.hide()

    document.addEventListener("contextmenu", this.onContext)
    document.addEventListener("pointerdown", this.onAway, true)
    window.addEventListener("keydown", this.onKey)
    window.addEventListener("scroll", this.onScroll, true)
    window.addEventListener("resize", this.onScroll)

    this.items.info.addEventListener("click", () => this.push("source_info"))
    this.items.rename.addEventListener("click", () => this.startRename())
    this.items.newMix.addEventListener("click", () => this.push("new_mix_from_source"))
    this.items.delete.addEventListener("click", (e) => this.onDelete(e))

    // No two-step. Removing a clip deletes no file and ⌘Z puts it back, so an
    // "are you sure?" here would train the reflex that makes the confirm on
    // `data-ctx-delete` — which DOES destroy a file — worth ignoring.
    this.items.duplicateClip.addEventListener("click", () => {
      if (this.clipId) this.pushEventTo(this.el, "duplicate_clip", {id: this.clipId})
      this.hide()
    })

    this.items.removeClip.addEventListener("click", () => {
      if (this.clipId) this.pushEventTo(this.el, "remove_clip", {id: this.clipId})
      this.hide()
    })

    // Enter commits, Escape abandons. Keydown rather than change/blur: a blur
    // commit renames on a stray click somewhere else, which is a destructive
    // thing to do by accident.
    this.renameInput.addEventListener("keydown", (e) => {
      if (e.key === "Enter") {
        e.preventDefault()
        const value = this.renameInput.value.trim()
        if (value && value !== this.renameFrom) {
          this.pushEventTo(this.el, "rename_source", {id: this.targetId, name: value})
        }
        this.hide()
      } else if (e.key === "Escape") {
        e.preventDefault()
        e.stopPropagation()
        this.hide()
      }
    })
  },

  destroyed() {
    document.removeEventListener("contextmenu", this.onContext)
    document.removeEventListener("pointerdown", this.onAway, true)
    window.removeEventListener("keydown", this.onKey)
    window.removeEventListener("scroll", this.onScroll, true)
    window.removeEventListener("resize", this.onScroll)
  },

  // A clip's menu is one item, so it skips `open/1`'s deletability questions
  // entirely — there is no "is this yours" for a block you placed yourself.
  openClip(clip) {
    this.clipId = clip.dataset.clipId
    this.targetId = null

    this.renameInput.hidden = true
    Object.values(this.items).forEach((el) => (el.hidden = true))
    this.items.duplicateClip.hidden = false
    this.items.removeClip.hidden = false

    this.el.hidden = false
    this.place(clip.getBoundingClientRect())
  },

  open(row) {
    this.clipId = null
    this.targetId = row.dataset.studioSource
    const label = row.dataset.sourceLabel || this.targetId
    const sourceable = !!row.dataset.sourceable
    const owned = !!row.dataset.deletable

    this.renameFrom = label
    this.renameInput.hidden = true
    this.items.info.hidden = !sourceable
    this.items.newMix.hidden = !sourceable
    // Renaming and deleting are the same permission: it is your file or it
    // isn't. A built-in chime has nothing of yours to rename either.
    this.items.rename.hidden = !owned
    this.items.delete.hidden = !owned
    this.items.removeClip.hidden = true
    this.items.duplicateClip.hidden = true
    this.disarm(label)

    // Nothing this row can offer — don't flash an empty box at the user.
    if (Object.values(this.items).every((el) => el.hidden)) {
      this.hide()
      return
    }

    this.el.hidden = false
    this.place(row.getBoundingClientRect())
  },

  // The menu becomes the field. Measuring happens before the swap so the box
  // does not jump under the cursor as items disappear.
  startRename() {
    Object.values(this.items).forEach((el) => (el.hidden = true))
    this.renameInput.hidden = false
    this.renameInput.value = this.renameFrom
    this.renameInput.focus()
    this.renameInput.select()
  },

  // Anchored to the row: top-aligned, just off its right edge.
  //
  // `position: fixed` resolves against the nearest ancestor carrying a
  // transform / filter / backdrop-filter — NOT the viewport. The Studio lives
  // in `.ic-panel`, which on the homepage has `backdrop-filter: blur(10px)`, so
  // the panel IS that ancestor and viewport coordinates put the menu somewhere
  // around the middle of the screen. Rather than hardcode which ancestor wins,
  // park the element at 0,0 and measure where that actually lands: the offset
  // between the two is the correction, whatever the containing block turns out
  // to be.
  place(anchor) {
    const el = this.el
    el.style.left = "0px"
    el.style.top = "0px"
    const origin = el.getBoundingClientRect()
    const {width, height} = origin
    const margin = 8

    let x = anchor.right + 4
    let y = anchor.top

    // Flip to the row's left rather than hang off the window edge.
    if (x + width > window.innerWidth - margin) {
      x = Math.max(margin, anchor.left - width - 4)
    }
    y = Math.max(margin, Math.min(y, window.innerHeight - height - margin))

    el.style.left = `${x - origin.left}px`
    el.style.top = `${y - origin.top}px`
  },

  push(event) {
    if (this.targetId) this.pushEventTo(this.el, event, {id: this.targetId})
    this.hide()
  },

  onDelete(e) {
    e.preventDefault()
    if (!this.armed) {
      this.arm()
      return
    }
    this.push("delete_source")
  },

  hide() {
    this.el.hidden = true
    this.renameInput.hidden = true
    this.targetId = null
    this.renameFrom = null
    this.armed = false
  },

  arm() {
    this.armed = true
    this.items.delete.textContent = "Really delete?"
    this.items.delete.classList.add("text-error")
  },

  disarm(label) {
    this.armed = false
    this.items.delete.textContent = `Delete ${label}`
    this.items.delete.classList.remove("text-error")
  },
}
