// Rotary phone dialer — drives the SVG fingerwheel in the Phone tab's Playback
// panel. Real dial mechanics: put a pointer in a hole, wind the wheel clockwise
// to the finger stop, release, and the wheel returns at governed speed while
// the digit's pulse train ticks (WebAudio). A plain click on a hole auto-dials
// it (wind + return) for anyone who doesn't want to drag. Registered digits go
// to LiveView via pushEvent("dial_digit").
//
// Geometry contract with the HEEx markup: the hook element contains an SVG with
// a rotating group `[data-rotor]` (rotated about data-cx/data-cy) and one hit
// target per hole carrying `data-digit` and `data-travel` (degrees of clockwise
// wind needed to reach the finger stop).

const RETURN_SPEED = 285 // deg/sec — governed return, ~1.15s for a full "0"
const WIND_SPEED = 520 // deg/sec — auto-dial wind (finger pulling)
const STOP_PAUSE_MS = 110 // rest against the finger stop before release
const REGISTER_TOLERANCE = 9 // deg short of the stop that still counts
const PULSE_OFFSET = 35 // deg — wind below this produces no pulses

export const RotaryDial = {
  mounted() {
    this.svg = this.el.querySelector("svg")
    this.rotor = this.el.querySelector("[data-rotor]")
    this.cx = parseFloat(this.rotor.getAttribute("data-cx"))
    this.cy = parseFloat(this.rotor.getAttribute("data-cy"))
    this.angle = 0
    this.busy = false
    this.drag = null
    this.raf = null
    this.audio = null

    this.onDown = (e) => this.pointerDown(e)
    this.onMove = (e) => this.pointerMove(e)
    this.onUp = (e) => this.pointerUp(e)

    for (const hole of this.el.querySelectorAll("[data-digit]")) {
      hole.addEventListener("pointerdown", this.onDown)
    }
    this.el.addEventListener("pointermove", this.onMove)
    this.el.addEventListener("pointerup", this.onUp)
    this.el.addEventListener("pointercancel", this.onUp)
  },

  destroyed() {
    if (this.raf != null) cancelAnimationFrame(this.raf)
    this.audio?.close?.().catch(() => {})
  },

  // --- pointer mechanics ------------------------------------------------

  pointerAngle(e) {
    const rect = this.svg.getBoundingClientRect()
    const scaleX = rect.width / this.svg.viewBox.baseVal.width
    const scaleY = rect.height / this.svg.viewBox.baseVal.height
    const x = (e.clientX - rect.left) / scaleX - this.cx
    const y = (e.clientY - rect.top) / scaleY - this.cy
    return (Math.atan2(y, x) * 180) / Math.PI
  },

  pointerDown(e) {
    if (this.busy || this.drag) return
    const digit = e.currentTarget.getAttribute("data-digit")
    const travel = parseFloat(e.currentTarget.getAttribute("data-travel"))
    this.drag = {
      digit,
      travel,
      last: this.pointerAngle(e),
      moved: 0,
    }
    this.el.setPointerCapture?.(e.pointerId)
    e.preventDefault()
  },

  pointerMove(e) {
    if (!this.drag) return
    const now = this.pointerAngle(e)
    // Accumulate the small normalized delta so crossing the ±180° seam of
    // atan2 doesn't teleport the wheel.
    let delta = now - this.drag.last
    if (delta > 180) delta -= 360
    if (delta < -180) delta += 360
    this.drag.last = now
    this.drag.moved += Math.abs(delta)
    this.setAngle(Math.min(this.drag.travel, Math.max(0, this.angle + delta)))
  },

  pointerUp(e) {
    if (!this.drag) return
    const {digit, travel, moved} = this.drag
    this.drag = null
    this.el.releasePointerCapture?.(e.pointerId)

    if (moved < 8 && this.angle < 8) {
      // A click, not a wind: dial this digit automatically.
      this.autoDial(digit, travel)
      return
    }

    if (this.angle >= travel - REGISTER_TOLERANCE) {
      this.clunk()
      this.register(digit)
    }
    this.returnHome()
  },

  autoDial(digit, travel) {
    this.busy = true
    this.animateTo(travel, WIND_SPEED, () => {
      this.clunk()
      this.register(digit)
      setTimeout(() => this.returnHome(), STOP_PAUSE_MS)
    })
  },

  register(digit) {
    this.pushEvent("dial_digit", {digit})
  },

  returnHome() {
    this.busy = true
    this.animateTo(0, RETURN_SPEED, () => {
      this.busy = false
    })
  },

  // Constant angular velocity toward `target`, ticking the pulse train on the
  // way home (each 30° hole-pitch crossed above the pulse offset is one pulse —
  // which lands exactly on the digit's pulse count, 0 = ten).
  animateTo(target, speed, done) {
    if (this.raf != null) cancelAnimationFrame(this.raf)
    let last = null
    const step = (now) => {
      this.raf = null
      if (last == null) last = now
      const dt = (now - last) / 1000
      last = now
      const dir = Math.sign(target - this.angle)
      let next = this.angle + dir * speed * dt
      if ((dir > 0 && next >= target) || (dir < 0 && next <= target)) next = target

      if (dir < 0) {
        const before = Math.floor((this.angle - PULSE_OFFSET) / 30)
        const after = Math.floor((next - PULSE_OFFSET) / 30)
        for (let i = 0; i < before - after; i++) this.tick()
      }

      this.setAngle(next)
      if (this.angle === target) {
        done?.()
      } else {
        this.raf = requestAnimationFrame(step)
      }
    }
    this.raf = requestAnimationFrame(step)
  },

  setAngle(deg) {
    this.angle = deg
    this.rotor.setAttribute("transform", `rotate(${deg} ${this.cx} ${this.cy})`)
  },

  // --- sound ---------------------------------------------------------------
  // Quiet mechanical noises, synthesized so nothing ships as an asset: the
  // pulse tick is a filtered click, the finger-stop clunk a lower thud.

  ctx() {
    if (this.audio) return this.audio
    try {
      this.audio = new (window.AudioContext || window.webkitAudioContext)()
    } catch (_e) {
      this.audio = null
    }
    return this.audio
  },

  blip(freq, gain, ms) {
    const ctx = this.ctx()
    if (!ctx) return
    const osc = ctx.createOscillator()
    const amp = ctx.createGain()
    osc.type = "square"
    osc.frequency.value = freq
    amp.gain.setValueAtTime(gain, ctx.currentTime)
    amp.gain.exponentialRampToValueAtTime(0.0001, ctx.currentTime + ms / 1000)
    osc.connect(amp).connect(ctx.destination)
    osc.start()
    osc.stop(ctx.currentTime + ms / 1000)
  },

  tick() {
    this.blip(2600, 0.028, 14)
  },

  clunk() {
    this.blip(180, 0.05, 45)
  },
}
