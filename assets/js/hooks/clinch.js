import {
  invoker,
  managementAvailable,
  putPayload,
  errorMessage,
  safeEntry,
} from "../lib/clinch.js"

// The Clinch's management gate, browser side.
//
// The load-bearing detail is what this hook does NOT do: the value never becomes
// a LiveView event. The input carries no phx-change and no phx-submit, the hook
// reads it straight out of the DOM, hands it to Tauri, and clears it. The server
// learns that a credential was stored — never what it is. That is what makes the
// old `<input type="password" value={...}>` round-trip impossible here rather
// than merely discouraged.
//
// In a plain browser (including one reached over an SSH tunnel) there is no
// __TAURI__, so the form is replaced with a notice rather than a control that
// would fail on click.
export const ClinchManager = {
  mounted() {
    this.invoke = invoker()
    this.form = this.el.querySelector("[data-clinch-form]")
    this.notice = this.el.querySelector("[data-clinch-unavailable]")
    this.status = this.el.querySelector("[data-clinch-status]")

    if (!managementAvailable()) {
      this.form?.setAttribute("hidden", "hidden")
      this.notice?.removeAttribute("hidden")
      return
    }

    this.notice?.setAttribute("hidden", "hidden")

    this.onSubmit = (event) => {
      event.preventDefault()
      this.store()
    }

    this.form?.addEventListener("submit", this.onSubmit)
  },

  destroyed() {
    if (this.onSubmit) this.form?.removeEventListener("submit", this.onSubmit)
  },

  field(name) {
    return this.el.querySelector(`[data-clinch-${name}]`)
  },

  store() {
    const kindEl = this.field("kind")
    const nameEl = this.field("name")
    const valueEl = this.field("value")
    const noteEl = this.field("note")

    const {payload, error} = putPayload({
      kind: kindEl?.value,
      name: nameEl?.value,
      value: valueEl?.value,
      note: noteEl?.value,
    })

    if (error) return this.say(errorMessage(error))

    this.say("Storing…")

    this.invoke("clinch_put", payload)
      .then((response) => {
        // Clear the value from the DOM the moment it is stored. It was never in
        // an assign; it should not linger in an input either.
        if (valueEl) valueEl.value = ""
        if (noteEl) noteEl.value = ""

        const entry = safeEntry(response?.entry)
        this.say(entry?.name ? `Stored "${entry.name}".` : "Stored.")

        // Tell the server to re-read Clinch.list/0 — names and metadata only.
        this.pushEvent("clinch:changed", {})
      })
      .catch((reason) => this.say(errorMessage(reason)))
  },

  say(message) {
    if (this.status) this.status.textContent = message
  },
}

// "Reveal key" for the master recovery key.
//
// This never touches the server. Rust reads the Keychain and hands the value
// back to a DOM node this hook owns — so the key that decrypts every other
// credential is not a LiveView assign, is not in a diff, and cannot cross a
// tunnel. It used to be all three.
export const RecoveryKey = {
  mounted() {
    this.invoke = invoker()
    this.button = this.el.querySelector("[data-recovery-toggle]")
    this.output = this.el.querySelector("[data-recovery-value]")
    this.panel = this.el.querySelector("[data-recovery-panel]")
    this.notice = this.el.querySelector("[data-recovery-unavailable]")

    if (!managementAvailable()) {
      this.button?.setAttribute("hidden", "hidden")
      this.notice?.removeAttribute("hidden")
      return
    }

    this.notice?.setAttribute("hidden", "hidden")
    this.revealed = false

    this.onClick = () => (this.revealed ? this.hide() : this.reveal())
    this.button?.addEventListener("click", this.onClick)
  },

  destroyed() {
    if (this.onClick) this.button?.removeEventListener("click", this.onClick)
    this.hide()
  },

  reveal() {
    this.invoke("clinch_reveal_recovery_key")
      .then((key) => {
        if (this.output) this.output.value = key
        this.panel?.removeAttribute("hidden")
        if (this.button) this.button.textContent = "Hide key"
        this.revealed = true
      })
      .catch((reason) => {
        if (this.output) this.output.value = ""
        this.panel?.removeAttribute("hidden")
        if (this.output) this.output.value = errorMessage(reason)
      })
  },

  hide() {
    // Drop the value out of the DOM entirely rather than just hiding the node.
    if (this.output) this.output.value = ""
    this.panel?.setAttribute("hidden", "hidden")
    if (this.button) this.button.textContent = "Reveal key"
    this.revealed = false
  },
}
