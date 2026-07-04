// Humo WebGPU renderer (Phase 0.2). Owns the entire GPU lifecycle — device,
// pipeline, uniform buffer, text texture — behind a small handle so the hook
// only drives a render loop. Bare WebGPU on one fullscreen tri, no framework
// (roadmap non-goal: no three.js). Path A per the Phase 0.1 verdict; if WebGPU
// is unavailable this throws HumoGpuError with the probe reason and the caller
// falls back to a plain surface — a dead canvas never ships (Cross-cutting §B).
import {SMOKE_WGSL} from "./smoke_wgsl.js"
import {UNIFORM_FLOATS} from "./params.js"

export class HumoGpuError extends Error {
  constructor(reason) {
    super("WebGPU unavailable: " + reason)
    this.reason = reason
  }
}

export async function createSmokeRenderer(canvas, {textWidth = 1024, textHeight = 512} = {}) {
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

  const module = device.createShaderModule({code: SMOKE_WGSL})
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
  const textTex = device.createTexture({
    size: [textWidth, textHeight],
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
      {binding: 2, resource: textTex.createView()},
    ],
  })

  return {
    // Resolves when the GPU goes away (never rejects) — the hook uses it to
    // drop to the fallback surface instead of drawing on a dead device.
    lost: device.lost,

    // Draw one frame. `uniforms` is the packed Float32Array; `textSource` (a
    // canvas) is uploaded only when `textDirty` — per-token, never per-frame
    // (the Phase 0.1 spike put the enqueue at ~4.4ms; uploading every frame
    // would burn a quarter of the budget).
    render({uniforms, textSource, textDirty}) {
      if (textDirty && textSource) {
        device.queue.copyExternalImageToTexture(
          {source: textSource},
          {texture: textTex},
          [textWidth, textHeight]
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
      textTex.destroy()
      ubuf.destroy()
      device.destroy()
    },
  }
}
