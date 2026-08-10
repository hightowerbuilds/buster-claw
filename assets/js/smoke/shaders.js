// Registry of homepage background shader designs, keyed by the name stored in
// the "home_background_mode" setting. Add a design here + an option in the
// appearance settings and it's selectable.
import {SMOKE_WGSL} from "./smoke.wgsl.js"
import {WAVES_WGSL} from "./waves.wgsl.js"
import {MANDEL_WGSL} from "./mandel.wgsl.js"
import {WEATHER_WGSL} from "./weather.wgsl.js"
import {FACE_WGSL} from "./face.wgsl.js"
import {DAYCYCLE_WGSL} from "./daycycle.wgsl.js"
import {SEVENSEG_WGSL} from "./sevenseg.wgsl.js"
import {KEYPAD_WGSL} from "./keypad.wgsl.js"
import {VEIL_WGSL} from "./veil.wgsl.js"

export const SHADERS = {
  smoke: SMOKE_WGSL,
  waves: WAVES_WGSL,
  mandel: MANDEL_WGSL,
  weather: WEATHER_WGSL,
  face: FACE_WGSL,
  daycycle: DAYCYCLE_WGSL,
  sevenseg: SEVENSEG_WGSL,
  keypad: KEYPAD_WGSL,
  // Image-reactive; bundled and testable from here, but deliberately NOT yet in
  // Appearance's `@builtin_shaders`, so it cannot be picked until the surfaces
  // can actually feed it an image (IMAGE_SHADER_ROADMAP Phase 3). Being in this
  // registry is not the same as being offered — `face`/`sevenseg`/`keypad` are
  // here for other surfaces and have never been background options either.
  veil: VEIL_WGSL,
}

export const DEFAULT_SHADER = "smoke"

// Bundled shaders that react to the user's selected background image, and the
// single source of truth for it — `BusterClaw.Appearance.@builtin_image_shaders`
// is the Elixir half of the pair and `appearance_test.exs` reads THIS list.
//
// It is an explicit list rather than a scan, and `smoke` is why. A WORKSPACE
// shader is an fs_main body alone, so "does its source call the image API" is an
// exact question with an exact answer (`BusterClaw.Shaders.samples_image?/1`).
// A built-in is a whole shader with history: `smoke` carries a live
// `contentTex` sampling path left over from when it was Humo's reading surface,
// gated on `reveal` — which every background holds at 0. A scan reports it as
// image-reactive; selecting "image + smoke" would draw the image nowhere.
//
// Text can tell you a shader CAN sample. Only a person can tell you it would
// mean anything.
export const IMAGE_REACTIVE_BUILTINS = ["veil"]
