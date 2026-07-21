// The corner widget's analog clock. The SVG face is server-rendered and frozen
// (phx-update="ignore"); this hook owns the motion — hand rotations via SVG
// rotate(deg cx cy) transforms and the digital readout — off the machine's own
// clock, so nothing ticks across the LiveView socket.
export const Clock = {
  mounted() {
    this.hour = this.el.querySelector('[data-hand="hour"]')
    this.minute = this.el.querySelector('[data-hand="minute"]')
    this.second = this.el.querySelector('[data-hand="second"]')
    this.digital = this.el.querySelector("[data-clock-digital]")
    this.date = this.el.querySelector("[data-clock-date]")

    this.tick()
    this.timer = setInterval(() => this.tick(), 1000)
  },

  destroyed() {
    clearInterval(this.timer)
  },

  tick() {
    const now = new Date()
    const s = now.getSeconds()
    const m = now.getMinutes()
    const h = now.getHours()

    this.rotate(this.second, s * 6)
    this.rotate(this.minute, m * 6 + s * 0.1)
    this.rotate(this.hour, (h % 12) * 30 + m * 0.5)

    if (this.digital) {
      const pad = n => String(n).padStart(2, "0")
      const h12 = h % 12 || 12
      const ampm = h < 12 ? "AM" : "PM"
      this.digital.textContent = `${h12}:${pad(m)}:${pad(s)} ${ampm}`
    }

    if (this.date) {
      this.date.textContent = now.toLocaleDateString(undefined, {
        weekday: "long",
        month: "short",
        day: "numeric",
      })
    }
  },

  rotate(group, deg) {
    if (group) group.setAttribute("transform", `rotate(${deg} 100 100)`)
  },
}

// The dock's status widget (DockLive, sticky in the footer). One 1s interval
// drives everything time-shaped in it, client-side off the machine's clock:
//   [data-clock]     → local HH:MM
//   [data-countdown] → time remaining until the ISO instant (m:ss / h:mm:ss);
//                      "now" once it arrives (the ring modal is NotifyLive's job)
//   [data-walltime]  → the ISO instant as local wall-clock HH:MM
// Elements are re-queried every tick because LiveView patches chips in and out
// as notifications come and go; the spans are server-rendered empty, so there's
// no server-owned text to fight over.
export const DockClock = {
  mounted() {
    this.tick()
    this.timer = setInterval(() => this.tick(), 1000)
  },
  updated() {
    this.tick()
  },
  destroyed() {
    clearInterval(this.timer)
  },
  tick() {
    const pad = (n) => String(n).padStart(2, "0")
    const now = new Date()

    this.el.querySelectorAll("[data-clock]").forEach((el) => {
      el.textContent = pad(now.getHours()) + ":" + pad(now.getMinutes())
    })

    this.el.querySelectorAll("[data-walltime]").forEach((el) => {
      const at = new Date(el.dataset.walltime)
      if (isNaN(at)) return
      el.textContent = pad(at.getHours()) + ":" + pad(at.getMinutes())
    })

    this.el.querySelectorAll("[data-countdown]").forEach((el) => {
      const at = new Date(el.dataset.countdown)
      if (isNaN(at)) return
      const left = Math.max(0, Math.round((at - now) / 1000))
      if (left === 0) {
        el.textContent = "now"
        return
      }
      const h = Math.floor(left / 3600)
      const m = Math.floor((left % 3600) / 60)
      const s = left % 60
      el.textContent = h > 0 ? `${h}:${pad(m)}:${pad(s)}` : `${m}:${pad(s)}`
    })
  },
}
