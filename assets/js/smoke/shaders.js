// Registry of homepage background shader designs, keyed by the name stored in
// the "home_background_mode" setting. Add a design here + an option in the
// appearance settings and it's selectable.
import {SMOKE_WGSL} from "./smoke.wgsl.js"
import {AURORA_WGSL} from "./aurora.wgsl.js"
import {WAVES_WGSL} from "./waves.wgsl.js"

export const SHADERS = {
  smoke: SMOKE_WGSL,
  aurora: AURORA_WGSL,
  waves: WAVES_WGSL,
}

export const DEFAULT_SHADER = "smoke"
