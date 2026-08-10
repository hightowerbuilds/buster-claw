// Veil — the reference IMAGE-REACTIVE background, and the worked example the
// `shader-designer` skill points at.
//
// A drifting field laid over the user's selected background image. It is not a
// flat wash: the veil THINS over the picture's highlights and gathers in its
// shadows, and its drift is nudged along the picture's own structure — so the
// image reads through the pattern rather than sitting under it.
//
// Palette roles: colA = the veil's body (and the ground it falls back to),
// colB = its lit edge, colC = the highlight it carries up out of the image.
//
// Three things here are the contract, not the design, and every image-reactive
// shader owes all three:
//
//   1. Sample through `img()`, never `textureSample(contentTex, smp, in.uv)`.
//      The helper cover-fits, un-flips the Y axis, and keeps split panes
//      continuous. Raw uv gets all three wrong and looks plausible doing it.
//   2. Fold every image-derived term through `has_img()`, so the shader is still
//      a design when it is selected without an image.
//   3. Composite the image yourself and return alpha 1.0. The canvas is opaque;
//      "transparency" here is a look you mix, not a blend mode you request.
//
// Sample ONCE and reuse it — `img()` and `img_lum()` are each a texture fetch,
// so calling both costs two. `img_lum(uv)` is the convenience when luminance is
// genuinely all you need.
import {WGSL_PRELUDE} from "./prelude.wgsl.js"

export const VEIL_WGSL =
  WGSL_PRELUDE +
  /* wgsl */ `
@fragment
fn fs_main(in: VOut) -> @location(0) vec4<f32> {
  let res = u.res.xy;
  let time = u.params.x * u.style.z;
  let uv = in.uv;
  let present = has_img();

  // One fetch, reused for both the colour and the luminance below.
  let src = img(uv);
  // With no image this sits at mid-grey, which keeps the field's full range
  // instead of collapsing it toward one end.
  let lum = mix(0.5, dot(src.rgb, vec3<f32>(0.2126, 0.7152, 0.0722)), present);

  // Aspect-correct so the field's cells stay round in a wide window.
  let p = uv * vec2<f32>(res.x / max(res.y, 1.0), 1.0);
  // Domain-warped by the picture's own luminance: the drift follows what is in
  // the image instead of sliding across it.
  let field = fbm(p * 2.6 + vec2<f32>(lum * 0.35, time * 0.03));

  // How much veil sits on this pixel. Bright picture -> less cover, so highlights
  // punch through and the shadows are where the pattern lives. Held off 1.0 so
  // the image is never fully buried.
  let cover = clamp(0.72 - lum * 0.5 + field * 0.3, 0.0, 0.92);

  var veil = grad3(field, u.colA.xyz, u.colB.xyz, u.colC.xyz);
  // A soft rim where the field steepens — the veil's lit edge.
  let rim = smoothstep(0.55, 0.78, field) * (1.0 - lum);
  veil = veil + u.colC.xyz * rim * 0.25;

  // The picture when there is one; the veil's own body when there is not.
  let under = mix(u.colA.xyz, src.rgb, present);
  var col = mix(under, veil, cover);

  col = bg_post(col, uv, res, time, u.post);
  return vec4<f32>(col, 1.0);
}
`
