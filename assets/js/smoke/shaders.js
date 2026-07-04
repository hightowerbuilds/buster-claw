// Registry of homepage background shader designs, keyed by the name stored in
// the "home_background_mode" setting. Add a design here + an option in the
// appearance settings and it's selectable.
import {SMOKE_WGSL} from "./smoke.wgsl.js"
import {WAVES_WGSL} from "./waves.wgsl.js"
import {ZIGZAG_WGSL} from "./zigzag.wgsl.js"
import {MANDEL_WGSL} from "./mandel.wgsl.js"
import {WEATHER_WGSL} from "./weather.wgsl.js"

export const SHADERS = {
  smoke: SMOKE_WGSL,
  waves: WAVES_WGSL,
  zigzag: ZIGZAG_WGSL,
  mandel: MANDEL_WGSL,
  weather: WEATHER_WGSL,
}

export const DEFAULT_SHADER = "smoke"
