import {vertexSource, fragmentSource} from "./shaders.js"

// All scene resources belong to this instance. Gods can later be composed into
// the renderer without tying their lifecycle to LiveView's DOM patches.
export function createOlympus(root) {
  const canvas = root.querySelector("canvas")
  const status = root.querySelector("[data-status]")
  const gl = canvas.getContext("webgl2", {alpha: false, antialias: false, powerPreference: "high-performance"})
  if (!gl) throw new Error("This scene needs WebGL 2. Please enable hardware acceleration in your browser.")

  const shaders = []
  const program = gl.createProgram()
  let buffer
  function dispose() {
    if (buffer) gl.deleteBuffer(buffer)
    gl.deleteProgram(program)
    shaders.forEach(shader => gl.deleteShader(shader))
  }
  try {
    for (const [type, source] of [[gl.VERTEX_SHADER, vertexSource], [gl.FRAGMENT_SHADER, fragmentSource]]) {
      const shader = gl.createShader(type)
      shaders.push(shader)
      gl.shaderSource(shader, source)
      gl.compileShader(shader)
      if (!gl.getShaderParameter(shader, gl.COMPILE_STATUS)) throw new Error(gl.getShaderInfoLog(shader))
      gl.attachShader(program, shader)
    }
    gl.linkProgram(program)
    if (!gl.getProgramParameter(program, gl.LINK_STATUS)) throw new Error(gl.getProgramInfoLog(program))
    gl.useProgram(program)
    buffer = gl.createBuffer()
    gl.bindBuffer(gl.ARRAY_BUFFER, buffer)
    gl.bufferData(gl.ARRAY_BUFFER, new Float32Array([-1,-1,3,-1,-1,3]), gl.STATIC_DRAW)
    const position = gl.getAttribLocation(program, "position")
    gl.enableVertexAttribArray(position)
    gl.vertexAttribPointer(position, 2, gl.FLOAT, false, 0, 0)
  } catch (error) {
    dispose()
    throw error
  }
  const uniforms = Object.fromEntries(["resolution", "time", "camera", "cloudCover", "interference"].map(name => [name, gl.getUniformLocation(program, name)]))
  const reduced = window.matchMedia("(prefers-reduced-motion: reduce)")
  const state = {azimuth: .18, elevation: .27, radius: 38, time: 0, cloudCover: .72, interference: 1, paused: reduced.matches, orbit: false}
  const abort = new AbortController()
  const listen = (el, event, callback, options = {}) => el.addEventListener(event, callback, {...options, signal: abort.signal})
  let raf = 0, last = 0, stopped = false, pointer = null, previousFrame = ""
  let quality = Math.min(window.devicePixelRatio || 1, 1)
  let slowFrames = 0
  const resize = () => {
    const rect = canvas.getBoundingClientRect()
    const scale = Math.min(quality, 1100 / Math.max(rect.width, rect.height))
    canvas.width = Math.max(1, Math.round(rect.width * scale))
    canvas.height = Math.max(1, Math.round(rect.height * scale))
    gl.viewport(0, 0, canvas.width, canvas.height)
  }
  const observer = new ResizeObserver(resize)
  observer.observe(canvas)
  resize()

  const pauseButton = root.querySelector("[data-action=pause]")
  const orbitButton = root.querySelector("[data-action=orbit]")
  const sync = () => {
    pauseButton.textContent = state.paused ? "Resume motion" : "Pause motion"
    pauseButton.setAttribute("aria-pressed", String(state.paused))
    orbitButton.setAttribute("aria-pressed", String(state.orbit))
    status.textContent = state.paused ? "TIME SUSPENDED" : "ATMOSPHERE ACTIVE"
  }
  listen(pauseButton, "click", () => { state.paused = !state.paused; sync() })
  listen(orbitButton, "click", () => { state.orbit = !state.orbit; sync() })
  listen(root.querySelector("[data-action=reset]"), "click", () => {
    Object.assign(state, {azimuth: .18, elevation: .27, radius: 38, orbit: false})
    sync()
  })
  listen(reduced, "change", () => { state.paused = reduced.matches; sync() })
  for (const name of ["cloudCover", "interference"]) {
    const input = root.querySelector(`[data-setting=${name}]`)
    listen(input, "input", () => {
      state[name] = Number(input.value) / 100
      root.querySelector(`[data-value=${name}]`).textContent = `${input.value}%`
    })
  }
  listen(canvas, "pointerdown", event => {
    if (pointer) return
    pointer = {id: event.pointerId, x: event.clientX, y: event.clientY}
    canvas.setPointerCapture(event.pointerId)
    state.orbit = false
    sync()
  })
  listen(canvas, "pointermove", event => {
    if (!pointer || pointer.id !== event.pointerId) return
    state.azimuth -= (event.clientX-pointer.x)*.004
    state.elevation = Math.max(.10, Math.min(.7, state.elevation+(event.clientY-pointer.y)*.003))
    pointer.x = event.clientX
    pointer.y = event.clientY
  })
  for (const event of ["pointerup", "pointercancel", "lostpointercapture"]) listen(canvas, event, () => { pointer = null })
  listen(canvas, "wheel", event => {
    event.preventDefault()
    state.radius = Math.max(26, Math.min(60, state.radius+event.deltaY*.025))
  }, {passive: false})
  listen(canvas, "keydown", event => {
    const actions = {
      ArrowLeft: () => { state.azimuth -= .08 },
      ArrowRight: () => { state.azimuth += .08 },
      ArrowUp: () => { state.elevation = Math.min(.7, state.elevation+.04) },
      ArrowDown: () => { state.elevation = Math.max(.1, state.elevation-.04) },
      "+": () => { state.radius = Math.max(26, state.radius-2) },
      "=": () => { state.radius = Math.max(26, state.radius-2) },
      "-": () => { state.radius = Math.min(60, state.radius+2) },
    }
    if (actions[event.key]) { event.preventDefault(); actions[event.key]() }
  })
  function frame(now) {
    raf = 0
    if (stopped || document.hidden) return
    const elapsed = last ? (now-last)/1000 : 0
    const delta = Math.min(.25, elapsed)
    last = now
    // Bound GPU cost on smaller devices; never resize on every frame.
    slowFrames = elapsed > .055 ? slowFrames+1 : Math.max(0, slowFrames-1)
    if (slowFrames > 40 && quality > .5) { quality *= .8; slowFrames = 0; resize() }
    if (!state.paused) {
      state.time += delta
      if (state.orbit) state.azimuth += delta*.025
    }
    const signature = `${Object.values(state).join("/")}/${canvas.width}/${canvas.height}`
    if (signature === previousFrame) { raf = requestAnimationFrame(frame); return }
    previousFrame = signature
    const horizontal = Math.cos(state.elevation)*state.radius
    gl.uniform2f(uniforms.resolution, canvas.width, canvas.height)
    gl.uniform1f(uniforms.time, state.time)
    gl.uniform3f(uniforms.camera, Math.sin(state.azimuth)*horizontal, 6.8+Math.sin(state.elevation)*state.radius, Math.cos(state.azimuth)*horizontal)
    gl.uniform1f(uniforms.cloudCover, state.cloudCover)
    gl.uniform1f(uniforms.interference, state.interference)
    gl.drawArrays(gl.TRIANGLES, 0, 3)
    raf = requestAnimationFrame(frame)
  }
  listen(document, "visibilitychange", () => {
    if (document.hidden) { cancelAnimationFrame(raf); raf = 0 }
    else if (!raf && !stopped) { last = 0; raf = requestAnimationFrame(frame) }
  })
  listen(canvas, "webglcontextlost", event => {
    event.preventDefault()
    stopped = true
    cancelAnimationFrame(raf)
    status.textContent = "Graphics interrupted. Reload to return to Olympus."
    root.dataset.state = "error"
  })
  sync()
  root.dataset.state = "ready"
  raf = requestAnimationFrame(frame)
  return () => {
    stopped = true
    cancelAnimationFrame(raf)
    abort.abort()
    observer.disconnect()
    dispose()
  }
}
