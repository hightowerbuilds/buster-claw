// Humo WebGPU renderer (Phase 0.2). Owns the entire GPU lifecycle — device,
// pipeline, uniform buffer, text texture — behind a small handle so the hook
// only drives a render loop. Bare WebGPU on one fullscreen tri, no framework
// (roadmap non-goal: no three.js). Path A per the Phase 0.1 verdict; if WebGPU
// is unavailable this throws HumoGpuError with the probe reason and the caller
// falls back to a plain surface — a dead canvas never ships (Cross-cutting §B).
import {SMOKE_WGSL} from "./smoke_wgsl.js"
import {UNIFORM_FLOATS} from "./params.js"
import {SDF_PASS_WGSL} from "./sdf/pass.wgsl.js"
import {MAX_SHAPES, SHAPE_STRIDE} from "./draw.js"

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

  // --- SDF drawing pass (built lazily on first draw) ----------------------
  // Renders a composed SDF scene INTO textTex (the same content texture the
  // smoke samples). Deliberately NOT built at renderer init: creating a second
  // WebGPU pipeline — with a fragment-stage storage buffer — is exactly the
  // kind of thing a stricter webview (WKWebView) can choke on, and *opening*
  // Humo must never risk the smoke. So only the smoke pipeline above boots; the
  // SDF pass is constructed on demand the first time a drawing arrives, isolated
  // in try/catch. A failure degrades to "no drawings" while the smoke keeps
  // running (roadmap Cross-cutting §B). See sdf/pass.wgsl.js.
  let drawPass = null
  let drawFailed = false

  function buildDrawPass() {
    if (drawPass || drawFailed) return drawPass
    try {
      const module = device.createShaderModule({code: SDF_PASS_WGSL})
      const pipeline = device.createRenderPipeline({
        layout: "auto",
        vertex: {module, entryPoint: "vs_main"},
        fragment: {module, entryPoint: "fs_main", targets: [{format: "rgba8unorm"}]},
        primitive: {topology: "triangle-list"},
      })
      const ubuf = device.createBuffer({
        size: 32, // two vec4: res, cfg
        usage: GPUBufferUsage.UNIFORM | GPUBufferUsage.COPY_DST,
      })
      const shapeBuf = device.createBuffer({
        size: MAX_SHAPES * SHAPE_STRIDE * 4,
        usage: GPUBufferUsage.STORAGE | GPUBufferUsage.COPY_DST,
      })
      const bind = device.createBindGroup({
        layout: pipeline.getBindGroupLayout(0),
        entries: [
          {binding: 0, resource: {buffer: ubuf}},
          {binding: 1, resource: {buffer: shapeBuf}},
        ],
      })
      drawPass = {pipeline, ubuf, shapeBuf, bind, u: new Float32Array(8)}
    } catch (e) {
      drawFailed = true
      console.warn("Humo: SDF drawing pass unavailable, smoke unaffected —", e.message)
    }
    return drawPass
  }

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

    // Render a composed SDF scene into the content texture, replacing whatever
    // text was there. `encoded` is the {buffer, count} from draw.js. The smoke
    // then condenses it exactly like text (the hook stops uploading the text
    // canvas while a drawing is live). Builds the pass on first use; a no-op if
    // the SDF pass can't build, so the smoke is never held hostage.
    renderDrawing({buffer, count, edge = 0.006}) {
      const dp = buildDrawPass()
      if (!dp) return

      device.queue.writeBuffer(dp.shapeBuf, 0, buffer)
      dp.u[0] = textWidth
      dp.u[1] = textHeight
      dp.u[4] = count
      dp.u[5] = edge
      device.queue.writeBuffer(dp.ubuf, 0, dp.u)

      const enc = device.createCommandEncoder()
      const pass = enc.beginRenderPass({
        colorAttachments: [
          {
            view: textTex.createView(),
            loadOp: "clear",
            storeOp: "store",
            clearValue: {r: 0, g: 0, b: 0, a: 0},
          },
        ],
      })
      pass.setPipeline(dp.pipeline)
      pass.setBindGroup(0, dp.bind)
      pass.draw(3)
      pass.end()
      device.queue.submit([enc.finish()])
    },

    // Call after the canvas backing size changes.
    resize: configure,

    destroy() {
      textTex.destroy()
      ubuf.destroy()
      // Null unless a drawing built the SDF pass — guard so teardown of a
      // smoke-only surface can't throw.
      drawPass?.shapeBuf.destroy()
      drawPass?.ubuf.destroy()
      device.destroy()
    },
  }
}
