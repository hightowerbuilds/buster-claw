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
