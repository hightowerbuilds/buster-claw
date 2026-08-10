// The prelude is a CONTRACT, not just a string: `struct U` has to agree with
// packUniforms' float count, and `smoke.wgsl.js` carries its own hand-rolled copy
// of that struct which has to stay in step. Nothing asserted any of that before
// the image slots were added — and the layout was described in three places, all
// three of which disagreed with the code.
import {describe, expect, test} from "bun:test"
import {WGSL_PRELUDE} from "./prelude.wgsl.js"
import {SMOKE_WGSL} from "./smoke.wgsl.js"
import {SHADERS, IMAGE_REACTIVE_BUILTINS} from "./shaders.js"
import {UNIFORM_FLOATS} from "./params.js"

// Field names of `struct U`, in declaration order.
function structFields(wgsl) {
  const body = wgsl.match(/struct U \{([^}]*)\}/)
  if (!body) throw new Error("no `struct U` found")
  return [...body[1].matchAll(/^\s*(\w+)\s*:/gm)].map((m) => m[1])
}

// A built-in is `WGSL_PRELUDE + <its own body>`; a WORKSPACE shader is only the
// body. Comparing bodies is what makes the built-in check mean the same thing as
// the workspace one — the prelude defines `img`/`has_img` itself, so a whole-file
// search would report every built-in as image-reactive.
function bodyOf(wgsl) {
  return wgsl.startsWith(WGSL_PRELUDE) ? wgsl.slice(WGSL_PRELUDE.length) : wgsl
}

// Mirrors BusterClaw.Shaders' marker. Word-boundaried so a shader with its own
// `myimg(...)` is not mistaken for one that samples.
const IMAGE_API = /\b(?:img|img_uv|img_lum|has_img)\s*\(|contentTex/

describe("struct U", () => {
  test("its field count is exactly the float count packUniforms writes", () => {
    // Every field is a vec4<f32>. Add one to the struct without bumping
    // UNIFORM_FLOATS and the uniform buffer is allocated too small — a GPU
    // validation failure at runtime, on whichever surface is unlucky.
    expect(structFields(WGSL_PRELUDE).length * 4).toBe(UNIFORM_FLOATS)
  })

  test("the image slots are the LAST two fields", () => {
    // Append-only. A field inserted before these shifts every offset after it
    // and silently feeds every shader wrong numbers.
    expect(structFields(WGSL_PRELUDE).slice(-2)).toEqual(["imgSize", "imgRect"])
  })

  test("smoke's private copy is a prefix of the prelude's", () => {
    // Smoke predates the prelude and declares its own struct. It is allowed to
    // be SHORTER (it does not sample images, so it stops before imgSize) but not
    // to differ in the fields it does declare.
    const prelude = structFields(WGSL_PRELUDE)
    const smoke = structFields(SMOKE_WGSL)
    expect(smoke.length).toBeLessThanOrEqual(prelude.length)
    expect(prelude.slice(0, smoke.length)).toEqual(smoke)
  })
})

describe("the image API", () => {
  test("the prelude defines all four helpers", () => {
    for (const fn of ["fn has_img(", "fn img_uv(", "fn img(", "fn img_lum("]) {
      expect(WGSL_PRELUDE).toContain(fn)
    }
  })

  test("img_uv guards against a zero-sized image instead of dividing by it", () => {
    // 0/0 is NaN, and a NaN uv samples black across the entire frame — so the
    // "no image" case would look like a catastrophic failure rather than a
    // graceful degrade. The guard is load-bearing, not defensive.
    const fn = WGSL_PRELUDE.match(/fn img_uv[\s\S]*?\n\}/)[0]
    expect(fn).toMatch(/u\.imgSize\.x <= 0\.0/)
    expect(fn).toMatch(/return vp;/)
  })

  test("img_uv flips Y — the prelude's uv origin is bottom-left, images are top-left", () => {
    expect(WGSL_PRELUDE.match(/fn img_uv[\s\S]*?\n\}/)[0]).toMatch(/1\.0 - uv_in\.y/)
  })

  test("img samples by LEVEL, so it is safe to call inside a branch", () => {
    // textureSample needs implicit derivatives and is illegal in non-uniform
    // control flow; a shader calling img() inside an `if` would fail to compile
    // for a reason that reads as nothing to do with branching.
    expect(WGSL_PRELUDE.match(/fn img\(uv[\s\S]*?\n\}/)[0]).toContain("textureSampleLevel")
  })
})

describe("which built-ins are image-reactive", () => {
  // IMAGE_REACTIVE_BUILTINS is declared, not derived — see the reasoning beside
  // it in shaders.js. These tests hold the two halves of that claim: that
  // everything ON the list really does use the image API, and that nothing OFF
  // it has quietly started to.
  const preludeBased = Object.keys(SHADERS).filter((k) => SHADERS[k].startsWith(WGSL_PRELUDE))

  test("everything on the list uses the image API", () => {
    for (const name of IMAGE_REACTIVE_BUILTINS) {
      expect(SHADERS[name]).toBeDefined()
      expect(IMAGE_API.test(bodyOf(SHADERS[name]))).toBe(true)
    }
  })

  test("no prelude-based built-in uses it without being on the list", () => {
    for (const name of preludeBased) {
      if (IMAGE_REACTIVE_BUILTINS.includes(name)) continue
      expect(IMAGE_API.test(bodyOf(SHADERS[name]))).toBe(false)
    }
  })

  test("smoke's Humo-era content path is still dormant", () => {
    // Smoke is the one built-in that predates the prelude and samples contentTex
    // on its own — the leftover reading surface, gated on `reveal`. Backgrounds
    // hold reveal at 0, which is the ONLY reason it is not image-reactive today.
    // If that gate ever goes, "image + smoke" becomes a real option and this
    // test is where the decision gets made rather than discovered.
    expect(SMOKE_WGSL).toContain("contentTex")
    expect(SMOKE_WGSL).toMatch(/reveal|params\.z/)
    expect(IMAGE_REACTIVE_BUILTINS).not.toContain("smoke")
  })

  test("veil folds its image terms through has_img so it degrades without one", () => {
    const veil = bodyOf(SHADERS.veil)
    expect(veil).toContain("has_img()")
    // ...and composites opaque: the canvas is opaque, so a shader returning a
    // fractional alpha is asking for a blend it will never get.
    expect(veil).toMatch(/return vec4<f32>\(col, 1\.0\)/)
  })

  test("touch() is what keeps a NON-sampling shader's bindings alive", () => {
    // If this ever stops being true for a plain background, its bindings drop out
    // of the auto layout and the pipeline fails to build.
    for (const name of preludeBased) {
      if (IMAGE_REACTIVE_BUILTINS.includes(name)) continue
      expect(bodyOf(SHADERS[name])).toContain("touch()")
    }
  })
})
