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
import {SMOKE_WGSL} from "./smoke.wgsl.js"
import {UNIFORM_FLOATS} from "./params.js"

export class SmokeGpuError extends Error {
  constructor(reason) {
    super("WebGPU unavailable: " + reason)
    this.reason = reason
  }
}

export async function createSmoke(canvas, {contentWidth = 2, contentHeight = 2} = {}) {
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

  const module = device.createShaderModule({code: SMOKE_WGSL})
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

  return {
    // Resolves when the GPU goes away (never rejects) — the hook uses it to
    // stop drawing on a dead device.
    lost: device.lost,

    // Draw one frame. `uniforms` is the packed Float32Array. `contentSource` /
    // `contentDirty` are unused by the background (always false) but kept so the
    // renderer stays general.
    render({uniforms, contentSource, contentDirty}) {
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
