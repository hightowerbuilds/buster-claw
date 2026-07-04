// The Humo screen — the one WebGPU pipeline that is the surface (HUMO screen
// rewrite; see .claude/plans/vivid-hopping-dahl.md). Owns the whole GPU
// lifecycle (device, pipeline, uniform buffer, content texture) behind a small
// handle so the hook only drives a render loop. Bare WebGPU on one fullscreen
// triangle, no framework — and crucially ONE pipeline fed by a uniform buffer +
// a texture, the pattern WKWebView's WebGPU is stable with. There is no second
// pipeline and no storage buffer: that combination crashed the GPU process
// (the black-screen bug this rewrite exists to kill).
//
// If WebGPU is unavailable this throws HumoGpuError with the probe reason and
// the caller falls back to the plain DOM transcript — a dead canvas never ships.
import {SCREEN_WGSL} from "./screen.wgsl.js"
import {UNIFORM_FLOATS} from "./params.js"

export class HumoGpuError extends Error {
  constructor(reason) {
    super("WebGPU unavailable: " + reason)
    this.reason = reason
  }
}

export async function createScreen(canvas, {contentWidth = 1024, contentHeight = 512} = {}) {
  if (!navigator.gpu) throw new HumoGpuError("navigator.gpu absent")
  let adapter
  try {
    adapter = await navigator.gpu.requestAdapter()
  } catch (e) {
    throw new HumoGpuError("requestAdapter threw: " + e.message)
  }
  if (!adapter) throw new HumoGpuError("adapter null")
  const device = await adapter.requestDevice().catch((e) => {
    throw new HumoGpuError("requestDevice threw: " + e.message)
  })

  const ctx = canvas.getContext("webgpu")
  if (!ctx) throw new HumoGpuError("canvas webgpu context null")
  const format = navigator.gpu.getPreferredCanvasFormat()
  const configure = () => ctx.configure({device, format, alphaMode: "opaque"})
  configure()

  const module = device.createShaderModule({code: SCREEN_WGSL})
  const info = await module.getCompilationInfo()
  const fatal = info.messages.filter((m) => m.type === "error")
  if (fatal.length) {
    throw new HumoGpuError(
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
  // The content texture: chat type / diagrams / drawings, authored on a Canvas2D
  // and uploaded here (COPY_DST) on dirty frames. No RENDER_ATTACHMENT — nothing
  // renders *into* it on the GPU (that was the retired SDF pass); it is a pure
  // content source the fullscreen shader samples.
  const contentTex = device.createTexture({
    size: [contentWidth, contentHeight],
    format: "rgba8unorm",
    usage: GPUTextureUsage.TEXTURE_BINDING | GPUTextureUsage.COPY_DST,
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
    // drop to the fallback surface instead of drawing on a dead device.
    lost: device.lost,

    // Draw one frame. `uniforms` is the packed Float32Array; `contentSource` (a
    // canvas) is uploaded to the content texture only when `contentDirty` —
    // per-token, never per-frame.
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
