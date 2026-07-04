// Registry of homepage background shader designs, keyed by the name stored in
// the "home_background_mode" setting. Add a design here + an option in the
// appearance settings and it's selectable.
import {SMOKE_WGSL} from "./smoke.wgsl.js"
import {WAVES_WGSL} from "./waves.wgsl.js"
import {LAVA_WGSL} from "./lava.wgsl.js"
import {ZIGZAG_WGSL} from "./zigzag.wgsl.js"
import {MANDEL_WGSL} from "./mandel.wgsl.js"

export const SHADERS = {
  smoke: SMOKE_WGSL,
  waves: WAVES_WGSL,
  lava: LAVA_WGSL,
  zigzag: ZIGZAG_WGSL,
  mandel: MANDEL_WGSL,
}

export const DEFAULT_SHADER = "smoke"
