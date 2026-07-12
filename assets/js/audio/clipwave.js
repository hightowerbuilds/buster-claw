// DAW-clip waveform renderer — one WGSL pipeline drawing a decoded audio
// envelope inside a Phone-tab clip, Pro Tools region style: filled symmetric
// waveform with a hot core, soft glow past the envelope edge, faint ruler
// ticks, and a slow shimmer sweeping the clip.
//
// WKWebView note (learned the hard way by the smoke pipeline): stick to ONE
// pipeline fed by a uniform buffer + a sampled texture — no storage buffers.
// The peaks therefore travel as a 256×1 rgba8 texture (R channel), which the
// fragment shader samples with free linear interpolation.
//
// Unlike the homepage smoke (one device per mount), every clip in the rack
// shares a single GPUDevice — a list of voicemails must not request a device
// per row. Per clip: its own canvas context, uniform buffer, peaks texture,
// bind group.

const PEAK_BUCKETS = 256

const CLIP_WGSL = /* wgsl */ `
struct U {
  res: vec2<f32>,
  time: f32,
  _pad: f32,
  colA: vec4<f32>,
  colB: vec4<f32>,
}
@group(0) @binding(0) var<uniform> u: U;
@group(0) @binding(1) var samp: sampler;
@group(0) @binding(2) var peaks: texture_2d<f32>;

@vertex
fn vs_main(@builtin(vertex_index) i: u32) -> @builtin(position) vec4<f32> {
  var p = array<vec2<f32>, 3>(
    vec2<f32>(-1.0, -3.0), vec2<f32>(3.0, 1.0), vec2<f32>(-1.0, 1.0)
  );
  return vec4<f32>(p[i], 0.0, 1.0);
}

@fragment
fn fs_main(@builtin(position) pos: vec4<f32>) -> @location(0) vec4<f32> {
  let uv = pos.xy / u.res;
  let pk = textureSample(peaks, samp, vec2<f32>(uv.x, 0.5)).r;
  let env = max(pk, 0.035);
  let d = abs(uv.y - 0.5) * 2.08;

  var acc = vec3<f32>(0.0);
  var a = 0.0;

  // Faint DAW ruler ticks.
  let tick = step(0.988, fract(uv.x * 24.0)) * 0.07;
  acc += vec3<f32>(0.95) * tick;
  a = max(a, tick);

  if (d < env) {
    // Waveform body: hot core fading outward, shimmer sweeping along x.
    let core = pow(1.0 - d / env, 2.0);
    let shimmer = 0.82 + 0.18 * sin(uv.x * 34.0 - u.time * 1.7);
    acc = mix(u.colB.rgb, u.colA.rgb, core) * shimmer;
    a = 0.92;
  } else {
    // Soft glow just past the envelope edge.
    let glow = (1.0 - smoothstep(env, env + 0.16, d)) * 0.35;
    acc += u.colA.rgb * glow;
    a = max(a, glow);
  }

  // Center zero-line.
  let center = (1.0 - smoothstep(0.0, 0.035, abs(uv.y - 0.5))) * 0.3;
  acc += u.colA.rgb * center;
  a = clamp(max(a, center), 0.0, 1.0);

  // CRT scanlines — same formula and 4-device-pixel period as the homepage
  // prelude's bg_post, stronger here because clips are small and bright.
  let scan = 0.5 + 0.5 * sin(pos.y * 1.57079633);
  acc = acc * (1.0 - 0.16 * (1.0 - scan));

  return vec4<f32>(acc * a, a);
}
`

let devicePromise = null
let deviceDead = false
const pipelineCache = new WeakMap()

function getDevice() {
  if (!devicePromise) {
    devicePromise = (async () => {
      if (!navigator.gpu) return null
      const adapter = await navigator.gpu.requestAdapter().catch(() => null)
      if (!adapter) return null
      const device = await adapter.requestDevice().catch(() => null)
      if (device) {
        device.lost.then(() => {
          deviceDead = true
          devicePromise = null
        })
      }
      return device
    })()
  }
  return devicePromise
}

async function getPipeline(device, format) {
  let entry = pipelineCache.get(device)
  if (entry) return entry
  const module = device.createShaderModule({code: CLIP_WGSL})
  const info = await module.getCompilationInfo()
  if (info.messages.some((m) => m.type === "error")) return null
  entry = {
    pipeline: device.createRenderPipeline({
      layout: "auto",
      vertex: {module, entryPoint: "vs_main"},
      fragment: {module, entryPoint: "fs_main", targets: [{format}]},
      primitive: {topology: "triangle-list"},
    }),
    sampler: device.createSampler({magFilter: "linear", minFilter: "linear"}),
  }
  pipelineCache.set(device, entry)
  return entry
}

// Decode an audio file into PEAK_BUCKETS normalized envelope peaks. The shared
// AudioContext is created suspended-safe (decode works without a user gesture).
let audioCtx = null

export async function decodePeaks(arrayBuffer) {
  if (!audioCtx) {
    const Ctx = window.AudioContext || window.webkitAudioContext
    if (!Ctx) return null
    audioCtx = new Ctx()
  }
  const audio = await new Promise((resolve, reject) =>
    audioCtx.decodeAudioData(arrayBuffer, resolve, reject)
  )
  const data = audio.getChannelData(0)
  const peaks = new Float32Array(PEAK_BUCKETS)
  const bucket = Math.max(1, Math.floor(data.length / PEAK_BUCKETS))
  let overall = 0
  for (let i = 0; i < PEAK_BUCKETS; i++) {
    let max = 0
    const start = i * bucket
    const end = Math.min(start + bucket, data.length)
    for (let j = start; j < end; j++) {
      const v = Math.abs(data[j])
      if (v > max) max = v
    }
    peaks[i] = max
    if (max > overall) overall = max
  }
  if (overall > 0) {
    // Normalize + perceptual lift so quiet passages still read as material.
    for (let i = 0; i < PEAK_BUCKETS; i++) peaks[i] = Math.pow(peaks[i] / overall, 0.7)
  }
  return peaks
}

export function hexToVec4(hex) {
  const n = parseInt((hex || "#ffffff").replace("#", ""), 16)
  return [((n >> 16) & 255) / 255, ((n >> 8) & 255) / 255, (n & 255) / 255, 1]
}

export async function createClipWave(canvas, {peaks, colorA, colorB}) {
  const device = await getDevice()
  if (!device || deviceDead) return null
  const format = navigator.gpu.getPreferredCanvasFormat()
  const entry = await getPipeline(device, format)
  if (!entry) return null
  const {pipeline, sampler} = entry

  const ctx = canvas.getContext("webgpu")
  if (!ctx) return null
  const configure = () => ctx.configure({device, format, alphaMode: "premultiplied"})
  configure()

  const ubuf = device.createBuffer({
    size: 48,
    usage: GPUBufferUsage.UNIFORM | GPUBufferUsage.COPY_DST,
  })

  const tex = device.createTexture({
    size: [PEAK_BUCKETS, 1],
    format: "rgba8unorm",
    usage: GPUTextureUsage.TEXTURE_BINDING | GPUTextureUsage.COPY_DST,
  })
  const texData = new Uint8Array(PEAK_BUCKETS * 4)
  for (let i = 0; i < PEAK_BUCKETS; i++) {
    texData[i * 4] = Math.round(Math.min(1, peaks[i]) * 255)
    texData[i * 4 + 3] = 255
  }
  device.queue.writeTexture({texture: tex}, texData, {bytesPerRow: PEAK_BUCKETS * 4}, [
    PEAK_BUCKETS,
    1,
  ])

  const bind = device.createBindGroup({
    layout: pipeline.getBindGroupLayout(0),
    entries: [
      {binding: 0, resource: {buffer: ubuf}},
      {binding: 1, resource: sampler},
      {binding: 2, resource: tex.createView()},
    ],
  })

  const uniforms = new Float32Array(12)
  uniforms.set(hexToVec4(colorA), 4)
  uniforms.set(hexToVec4(colorB), 8)

  return {
    lost: device.lost,

    render(timeSec) {
      if (deviceDead) return
      try {
        uniforms[0] = canvas.width
        uniforms[1] = canvas.height
        uniforms[2] = timeSec
        device.queue.writeBuffer(ubuf, 0, uniforms)
        const enc = device.createCommandEncoder()
        const pass = enc.beginRenderPass({
          colorAttachments: [
            {
              view: ctx.getCurrentTexture().createView(),
              loadOp: "clear",
              storeOp: "store",
              clearValue: {r: 0, g: 0, b: 0, a: 0},
            },
          ],
        })
        pass.setPipeline(pipeline)
        pass.setBindGroup(0, bind)
        pass.draw(3)
        pass.end()
        device.queue.submit([enc.finish()])
      } catch (_e) {
        deviceDead = true
      }
    },

    resize: configure,

    destroy() {
      tex.destroy()
      ubuf.destroy()
      // The device is shared — never destroy it here.
    },
  }
}
