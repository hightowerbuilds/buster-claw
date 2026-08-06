import {composeIntent, deliveryFor} from "../lib/compose_keys.js"

// The chat composer's keyboard behaviour, for BOTH surfaces.
//
// Home's `AgentChat` and Trading's `ChatWindow` each had their own copy of
// "Enter sends, Shift+Enter is a newline". They now share this hook, mounted on
// the form itself, so the rule exists once. The decisions it makes are all in
// `../lib/compose_keys.js`, which the Bun suite covers — this file is only the
// DOM plumbing.
//
// The form carries `data-running` and `data-steerable`, re-rendered by the
// server, so the chord always resolves against the CURRENT state rather than
// whatever was true when the hook mounted.
export const Composer = {
  mounted() {
    this.input = this.el.querySelector("[data-chat-input]")
    this.delivery = this.el.querySelector("[data-delivery]")

    this.onKeydown = (e) => {
      const intent = composeIntent(e)
      if (!intent) return

      // A newline is the textarea's own default. Returning without
      // preventDefault is what actually inserts it.
      if (intent === "newline") return

      e.preventDefault()
      if (this.input.value.trim() === "") return

      this.setDelivery(intent)
      this.el.requestSubmit()
    }

    // Clear after LiveView has serialized the form, and put the delivery back to
    // whatever the current state implies — an inverted chord must apply to one
    // message, not to every message after it.
    this.onSubmit = () => {
      requestAnimationFrame(() => {
        this.input.value = ""
        this.setDelivery("primary")
      })
    }

    this.input.addEventListener("keydown", this.onKeydown)
    this.el.addEventListener("submit", this.onSubmit)
  },

  destroyed() {
    this.input?.removeEventListener("keydown", this.onKeydown)
    this.el.removeEventListener("submit", this.onSubmit)
  },

  state() {
    return {
      running: this.el.dataset.running === "true",
      steerable: this.el.dataset.steerable === "true",
    }
  },

  setDelivery(which) {
    if (this.delivery) this.delivery.value = deliveryFor(this.state(), which)
  },
}
