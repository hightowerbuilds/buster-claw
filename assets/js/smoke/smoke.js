// The smoke field — the one WebGPU pipeline behind the homepage chat. Owns the
// GPU lifecycle (device, pipeline, uniform buffer) behind a small handle so the
// hook only drives a render loop. Bare WebGPU on one fullscreen triangle, ONE
// pipeline fed by a uniform buffer + a texture — the pattern WKWebView's WebGPU
// is stable with (no second pipeline, no storage buffer; that combination once
// crashed the GPU process).
//
// Honest note: this shader still carries a content-texture sampling path (it was
// once Humo's reading surface). As a *background* we never upload content —
// `render` is called with `contentDirty: false`, and reveal/lens are held at 0 —
// so that path no-ops and the shader draws pure drifting smoke + the post stack.
//
// If WebGPU is unavailable this throws SmokeGpuError with the probe reason and
// the caller simply drops the canvas — the chat above it is unaffected.
import {SHADERS, DEFAULT_SHADER} from "./shaders.js"
import {WGSL_PRELUDE} from "./prelude.wgsl.js"
import {UNIFORM_FLOATS} from "./params.js"

export class SmokeGpuError extends Error {
  constructor(reason) {
    super("WebGPU unavailable: " + reason)
    this.reason = reason
  }
}

// Fetch a custom shader's raw WGSL body (served at /shaders/<name>). Returns the
// text, or null on any network/HTTP failure so the caller can fall back cleanly.
export async function fetchShaderSource(url) {
  try {
    const res = await fetch(url, {cache: "no-store"})
    if (!res.ok) return null
    return await res.text()
  } catch (_e) {
    return null
  }
}

// `shader` selects a bundled built-in by name; `source` (optional) is a raw WGSL
// fs_main body for a custom pattern — the bundled prelude is prepended and the
// result compiled live, so a custom shader needs no rebuild. A bad `source`
// throws SmokeGpuError from the compile check (same path as a built-in).
export async function createSmoke(
  canvas,
  {contentWidth = 2, contentHeight = 2, shader = DEFAULT_SHADER, source = null} = {}
) {
  if (!navigator.gpu) throw new SmokeGpuError("navigator.gpu absent")
  let adapter
  try {
    adapter = await navigator.gpu.requestAdapter()
  } catch (e) {
    throw new SmokeGpuError("requestAdapter threw: " + e.message)
  }
  if (!adapter) throw new SmokeGpuError("adapter null")
  const device = await adapter.requestDevice().catch((e) => {
    throw new SmokeGpuError("requestDevice threw: " + e.message)
  })

  const ctx = canvas.getContext("webgpu")
  if (!ctx) throw new SmokeGpuError("canvas webgpu context null")
  const format = navigator.gpu.getPreferredCanvasFormat()
  const configure = () => ctx.configure({device, format, alphaMode: "opaque"})
  configure()

  const code = source ? WGSL_PRELUDE + source : SHADERS[shader] || SHADERS[DEFAULT_SHADER]
  const module = device.createShaderModule({code})
  const info = await module.getCompilationInfo()
  const fatal = info.messages.filter((m) => m.type === "error")
  if (fatal.length) {
    throw new SmokeGpuError(
      "WGSL: " + fatal.map((m) => m.lineNum + ":" + m.message).join(" | ")
    )
  }

  const pipeline = device.createRenderPipeline({
    layout: "auto",
    vertex: {module, entryPoint: "vs_main"},
    fragment: {module, entryPoint: "fs_main", targets: [{format}]},
    primitive: {topology: "triangle-list"},
  })

  const ubuf = device.createBuffer({
    size: UNIFORM_FLOATS * 4,
    usage: GPUBufferUsage.UNIFORM | GPUBufferUsage.COPY_DST,
  })
  // Content texture — the shader samples it, but for the background it is never
  // written (kept tiny). RENDER_ATTACHMENT is kept because
  // copyExternalImageToTexture (unused here) would require it.
  const contentTex = device.createTexture({
    size: [contentWidth, contentHeight],
    format: "rgba8unorm",
    usage:
      GPUTextureUsage.TEXTURE_BINDING |
      GPUTextureUsage.COPY_DST |
      GPUTextureUsage.RENDER_ATTACHMENT,
  })
  const sampler = device.createSampler({magFilter: "linear", minFilter: "linear"})
  const bind = device.createBindGroup({
    layout: pipeline.getBindGroupLayout(0),
    entries: [
      {binding: 0, resource: {buffer: ubuf}},
      {binding: 1, resource: sampler},
      {binding: 2, resource: contentTex.createView()},
    ],
  })

  // Set the moment the GPU device is lost. The hook watches `lost` (the promise)
  // to tear the canvas down, but that cleanup is async — frames can still fire in
  // the gap between loss and teardown. This flag lets `render` bail synchronously
  // so a queue/getCurrentTexture call never throws out of the rAF callback.
  let deviceLost = false
  device.lost.then(() => {
    deviceLost = true
  })

  return {
    // Resolves when the GPU goes away (never rejects) — the hook uses it to
    // stop drawing on a dead device.
    lost: device.lost,

    // Draw one frame. `uniforms` is the packed Float32Array. `contentSource` /
    // `contentDirty` are unused by the background (always false) but kept so the
    // renderer stays general.
    render({uniforms, contentSource, contentDirty}) {
      // Bail if the device is (or has just gone) lost — issuing GPU work against
      // a dead device throws, and here that would escape the rAF callback.
      if (deviceLost) return
      try {
        if (contentDirty && contentSource) {
          device.queue.copyExternalImageToTexture(
            {source: contentSource},
            {texture: contentTex},
            [contentWidth, contentHeight]
          )
        }
        device.queue.writeBuffer(ubuf, 0, uniforms)
        const enc = device.createCommandEncoder()
        const pass = enc.beginRenderPass({
          colorAttachments: [
            {
              view: ctx.getCurrentTexture().createView(),
              loadOp: "clear",
              storeOp: "store",
              clearValue: {r: 0.055, g: 0.055, b: 0.055, a: 1},
            },
          ],
        })
        pass.setPipeline(pipeline)
        pass.setBindGroup(0, bind)
        pass.draw(3)
        pass.end()
        device.queue.submit([enc.finish()])
      } catch (_e) {
        // Device lost mid-frame (before device.lost resolved): mark it so the
        // loop stops instead of throwing every frame until teardown catches up.
        deviceLost = true
      }
    },

    // Call after the canvas backing size changes.
    resize: configure,

    destroy() {
      contentTex.destroy()
      ubuf.destroy()
      device.destroy()
    },
  }
}
