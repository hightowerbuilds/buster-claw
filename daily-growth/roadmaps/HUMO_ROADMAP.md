# Humo — Shader-Driven Chat Roadmap

*2026-07-03. **Humo** ("smoke" in Spanish) is a new BusterClaw tab: a second,
independent headless Claude whose answers are **written in smoke** — a live
WebGL fragment shader through which streamed text condenses out of fog, settles
legible, and — as the conversation recedes — drifts back into smoke.*

*Governing principle: **the smoke is not a wallpaper behind the words — the
words are made of the smoke.** The shader is taught the shape of a conversation
(thinking, streaming, settling, ageing) and renders each state in a legible
smoke-language. But because the medium can be intentionally illegible, a real,
selectable, screen-reader-available DOM transcript is the source of truth
underneath, always — and one toggle collapses the whole effect to plain text.*

Effort tags: **S** = a sitting, **M** = a day-ish, **L** = multi-day / has unknowns.

---

## The decisions already made (Luke, 07-03)

1. **Rendering model: text condenses from smoke.** Not a backdrop. Streamed
   tokens materialize out of a noise field, settle into clarity, and old text can
   dissolve back. The text is a *texture the fragment shader displaces and
   reveals* — the hardest of the three options, chosen deliberately.
2. **Illegibility is expressive.** Thinking is unreadable turbulence; clarity
   *arrives* as a response settles; receding messages return to smoke. The
   unreadable moments are the point — **guarded by a real DOM transcript and a
   hard legibility toggle** (see Cross-cutting §A). Not negotiable.
3. **Humo is a separate showcase surface.** Its own tab, its own headless-Claude
   session, distinct from the homepage `StatusLive` chat. It lives *alongside*
   what exists; it does not replace it (a non-goal, below).

## Where this sits vs. what we already have

**Two truths, and the gap between them is the whole design problem.**

*Truth 1 — BusterClaw has no shader surface today.* What reads as "shaders" in
this app is CSS — `.ic-scanlines`, the cursor-tracked chromatic aberration
(`crt.js`), the `--noise` variable — and the terminal "background" is a
user-uploaded **image** shown through transparented xterm layers
(`/appearance/terminal-background/:slot`). None of it is a generative GPU shader.

*Truth 2 — Luke already has a real shader library, just in a different runtime.*
Outside this repo (`~/Desktop/websites/`):

- **`foreshadow`** (`hightowerbuilds/foreshadow`, MIT) — a backend-agnostic
  **Rust/wgpu** scene library: Water, Forest canopy, Space orbit, Contouring
  lines; API is builder + `render_to_texture(device, queue, target)`. Targets
  wgpu / GPUI (Zed's native GPU stack).
- **`gemma-construct/shaders/smoke.wgsl`** — a strong **smoke** shader (6-octave
  fbm + curl-style domain warp + vignette + vertical lift; grayscale tone driven
  by `time` + `intensity`). **This is the direct seed for Humo's look.**
- Both are **WGSL** (WebGPU Shading Language), written for **native Rust GPU**
  (the llnzy terminal's shader background is the "terminal background" Luke was
  remembering).

**The gap:** Humo lives in **Phoenix LiveView inside Tauri's wry/WKWebView** — a
*browser* GPU context — while the library is **native-wgpu/WGSL**. So the shaders
are proven *source and look*, but the load-bearing decision is **which browser GPU
API Humo targets**, because that decides how much of the library ports vs. reruns:

| Path | What it is | Reuse of Luke's shaders | Risk |
|---|---|---|---|
| **A — WebGPU in WKWebView** | Run WGSL nearly as-is via the browser WebGPU API | **Max** — one shader language shared with `foreshadow`; `smoke.wgsl` needs only bind-group/uniform rewiring | WKWebView/wry WebGPU support is **unproven** — the spike must confirm |
| **B — Port WGSL→GLSL, WebGL2** | Rewrite shaders in GLSL, universal WebGL2 | Medium — the fbm/noise math ports cleanly, but every shader forks into a second dialect | Low technical risk; ongoing two-dialect maintenance tax |
| C — Native wgpu, composite with webview | Use `foreshadow` unmodified in Rust, underlay the webview | Total (no port) | Native-webview compositing pain (per `BROWSER_ROADMAP.md`); **DOM-text-as-texture across the native/web boundary is a non-starter** for text-condenses-from-smoke |

**Recommendation: spike Path A first** (only path that keeps one shader language
across `foreshadow` and Humo); **Path B is the guaranteed fallback** if WKWebView
can't do WebGPU. Path C is a non-goal (below). This is exactly what Phase 0.1
resolves — empirically, in the real shell, before anything is built on it.

The *other* half — the headless Claude — is **not** greenfield. The homepage chat
harness is directly reusable:

- `BusterClaw.Agent.Chat` (GenServer) spawns a fresh `claude -p … --resume
  <session_id>` **subprocess per turn**; there is no stdin into a live turn (the
  constraint documented in `docs/chat-roadmap.md`).
- Streaming lands as `stream_event.ex` events (`:assistant_text` deltas,
  `:thinking`, `:tool_use`, `:meta`) broadcast over PubSub to the LiveView.
- `AgentRunner.kill_port` already backs interrupt/stop.

So Humo is **~90% novel shader / ~10% new chat wiring**: a distinct session on the
same proven harness, presented through a new render pipeline.

## To de-risk before building (the spike)

The library exists but not in this runtime, so the render path is still unproven.
Phase 0.1 must answer, against the **real Tauri wry/WKWebView shell** (not just a
desktop browser), **the Path-A-vs-Path-B fork first**:

- **WebGPU availability in WKWebView/wry (Path A).** Does `navigator.gpu` exist and
  actually render in the packaged shell? If yes, port `smoke.wgsl` with only
  bind-group/uniform rewiring and confirm it draws. **This is the pivotal result** —
  it decides whether Luke's WGSL library is reusable in-browser or must be ported.
- **WebGL2 baseline (Path B fallback).** In parallel, a WebGL2/GLSL translation of
  the same `smoke.wgsl` fbm, to prove the guaranteed path works and looks right.
- **Performance/thermals** for an always-animating fullscreen shader on either API;
  behaviour on **GPU context loss** (must degrade, not crash).
- **Text → texture cadence:** rendering DOM/canvas text to an offscreen 2D canvas
  and uploading it as a texture on every token delta — is that upload rate
  affordable while streaming? (Same question under WebGPU or WebGL2.)
- **Compositing:** Humo's canvas is *in-DOM inside the Phoenix page* (not a native
  webview), so it sidesteps the native-webview compositing fights from
  `BROWSER_ROADMAP.md` — confirm it layers cleanly with LiveView patches.

Fallback ladder: **Path A (WebGPU/WGSL) → Path B (WebGL2/GLSL) → plain accessible
transcript** (which we build first anyway). No path ships a broken GPU surface as
the only surface.

---

## Phase 0 — Spike & shader backbone (de-risk; no product surface yet)

*Prove the medium exists before wiring a conversation to it.*

1. **WKWebView GPU-API spike (Path A vs B).** (M — the load-bearing unknown) A
   throwaway page in the real Tauri shell running the **`smoke.wgsl` fbm field** on
   a fullscreen tri — once via WebGPU (WGSL, minimally rewired) and once via a
   WebGL2/GLSL translation. Measure FPS/thermals, context-loss recovery, and the
   text-canvas→texture upload path. *Done when:* we have numbers and a go/no-go on
   **which browser GPU API Humo targets**, recorded in this file.
   **SHIPPED 07-03 — VERDICT: PATH A (WebGPU).** Live run in the shell's
   WKWebView: `navigator.gpu` present, adapter + device OK, **`smoke.wgsl` ran
   near-verbatim** with the text-condense mechanism live on top. Numbers:
   50 fps avg / 22 ms worst frame at 1059×1180; text-texture upload (1024×512)
   4.37 ms avg / 7 ms worst enqueue over 73 uploads; 0 context-loss events.
   Caveats recorded: (a) the run reported **dpr 1.00** — WKWebView geometry
   quirk suspected (cf. the browser roadmap's `outerHeight 0` finding); re-measure
   at true Retina scale, and plan the standard mitigation regardless: render the
   smoke field at half-res and upscale (smoke is low-frequency; free headroom).
   (b) Upload enqueue cost says Phase 2 should upload per-token/dirty, never
   per-frame. WebGL2/GLSL twin exists in the spike as the proven Path-B fallback;
   no GLSL fork needed. Spike lives at `/humo/spike` (HumoSpikeController,
   pipeline-less route) hosted in the `HumoLive` tab; Open Q1 is resolved.
2. **Renderer scaffold.** (M) `assets/js/humo/`: a lean renderer (single fullscreen
   tri, no heavy framework — see Open Q1) for the chosen API, the smoke shader
   **seeded from `smoke.wgsl`** (its fbm/curl warp is the proven base), and a `Humo`
   render-loop hook registered in `hooks/index.js`. Draws animated smoke
   full-canvas, **no text yet**. Pure param math (noise scaling, palette mixing)
   factored out and **bun-tested**. If Path A wins, keep the WGSL a near-copy of
   `foreshadow`'s so the two can converge later.
   **SHIPPED 07-03** (and further: the text-condense path came along from the
   spike rather than waiting for Phase 2). `assets/js/humo/` — `smoke_wgsl.js`
   (WGSL source of truth, near-copy of gemma-construct's), `renderer.js` (bare
   WebGPU behind a small handle; fail-soft `HumoGpuError`, `device.lost` →
   status line, never a dead canvas), `params.js` (**mapChatState — the
   uniform-mapping layer v0**: idle/thinking/streaming/settled → intensity +
   reveal; plus packUniforms/revealProgress), `text_layout.js` (pure wrap).
   `HumoSurface` hook owns DOM/rAF/visibility-pause/ResizeObserver at true
   devicePixelRatio (status chip surfaces dpr to chase the 0.1 caveat) and runs
   a demo conversation loop until Phase 1 wires the real Claude. `HumoLive`
   dropped the spike iframe for the native canvas; spike page archived to
   `daily-growth/archive/humo-spike-0.1.html`, controller + route deleted.
   13 new bun tests (params + layout); mix 776, bun 30, esbuild green.
3. **Smoke design tokens.** (S) Palette uniforms from the Industrial Claw identity
   (#121212 base, #F4F1EA ash, #FF4D1C hazard as the *energy* accent). The smoke
   must read as *this* app — brutalist and controlled, not a lava lamp.
   *Status 07-03: palette is correct but **baked into the WGSL constants**;
   promoting the colors to uniforms is deferred to the Phase 5 tuning panel,
   which is what actually needs them variable.*

**Exit criteria:** animated smoke renders at an acceptable frame rate inside the
packaged shell; `bun test` green; zero conversation wiring, zero agent surface.

## Phase 1 — The Humo tab + its own headless Claude (plain text first)

*Stand up the second Claude and prove it end-to-end as ordinary text — the
shader comes after the plumbing is trustworthy.*

1. **`HumoLive` route + nav.** (S) `live "/humo", HumoLive, :index` in the
   `:default` live_session; a nav entry. Distinct styling (hazard accent) marking
   it as the flagship surface.
   **SHIPPED 07-03** (landed with the 0.1 spike: route, dock item, tab label).
2. **`BusterClaw.Humo.Session`.** (M) A GenServer modeled on `Agent.Chat` with its
   **own conversation/session id**, reusing `AgentRunner`, `stream_event.ex`,
   PubSub, and Sentinel auditing unchanged. A Humo turn is audited like any agent
   turn — no new bypass.
   **SHIPPED 07-03 — and it collapsed to a facade, not a GenServer.** Discovery:
   `Agent.Chat` is *already* a per-conversation engine (DynamicSupervisor +
   Registry + per-conv topics/transcripts), so `BusterClaw.Humo` is a thin
   context pinning the reserved conv_id `"humo"` — queue, interrupt, thinking,
   persistence, and Sentinel audit all inherited, zero forked code. No
   `Conversations` row is created (`Message.conv_id` has no FK), which is what
   keeps Humo out of the homepage chat tabs.
3. **Accessible transcript (source of truth).** (M) Render the conversation as a
   plain, selectable, screen-reader-friendly DOM transcript with an input box,
   Enter-to-send, and the reused `ThinkingTimer`. **This is the layer the shader
   will later present** — it is never removed, only visually superseded.
   **SHIPPED 07-03.** `HumoLive`: DOM transcript (per-role legible styling,
   `aria-live`, autoscroll via `HumoTranscript` hook), single-line input
   (native Enter submit), Stop button + queued badge, reused `ThinkingTimer`,
   transcript seeded from persistence on mount. **Bonus beyond scope:** the
   smoke is already live-wired to the real conversation (server `push_event`s
   `humo:phase`/`humo:text` → `mapChatState`) — thinking churns the fog and
   real replies condense out of it; the 0.2 demo loop is deleted. Tests:
   3 context tests (incl. a scripted-spawner end-to-end through the facade)
   + 3 LiveView tests (mount, persistence seed, send round-trip).

**Exit criteria:** you can hold a full conversation with a second, independent
Claude on `/humo` as normal legible text; interrupt/stop works.
**MET 07-03** (mix 782, bun 30, esbuild green). Field check remaining: send a
real message in the shell and watch it condense.

## Phase 2 — Text becomes texture (the core: condense from smoke)

*The load-bearing shader work. This is where "written in a shader" becomes real.*

1. **Text → texture pipeline.** (M) Render the active/settling message to an
   offscreen 2D canvas at device-pixel-ratio; upload as a `sampler2D`; redraw on
   each `:assistant_text` delta so the texture tracks the stream. (Start
   **raster**; SDF glyphs are an Open-Q upgrade if dissolve edges look mushy.)
2. **Condense/dissolve shader.** (L) Extend `smoke.wgsl`'s existing fbm/curl field
   (already proven) so it drives per-pixel UV displacement into the text texture,
   plus a **dissolve threshold**: `alpha = smoothstep(noise - edge, noise, textAlpha
   * reveal)`. `uReveal` sweeps 0→1 to condense text *in* as it streams; glowing
   hazard-orange wisps live in the transition band (the edge glow is what sells
   "smoke"). Reverse the sweep to dissolve *out*. `smoke.wgsl` is grayscale today;
   Humo tints it to the Industrial Claw palette (Cross-cutting §C).
3. **The uniform-mapping layer — "teaching the shader."** (M — the keystone Luke
   asked for) A **declarative map from chat lifecycle → uniforms**, as data, not
   GLSL: `uThinking`, `uStreamProgress` (per message), `uSettle`, `uAge`, `uWind`,
   `uDensity`, `uAccent`. This is the seam that lets the smoke be *tuned* (Phase 5)
   and, later, *driven by the model itself* — without anyone touching shader code.

**Exit criteria:** a streamed answer visibly condenses out of the smoke, character
by character, and settles into legibility — with the real transcript intact beneath.
*07-03 addition beyond the original spec: the smoke **reads out** — words appear
at a cadence (~90 ms/word, 22 px type), fill a page (`layoutPage`), and when the
next word wouldn't fit the page dissolves (`pageReveal` clock, 700 ms) to make
room for the next; the final page settles and holds. Long replies are now fully
speakable in smoke instead of overflowing the texture.*

## Phase 3 — State-woven smoke (the whole conversation breathes)

*Give every chat state its own legible smoke-language.*

1. **Thinking = turbulence.** (S) Pre-first-token / `:thinking`: violent churn,
   `uThinking→1`, no legible text — the "no words yet" state.
2. **Settle & age.** (M) A finished message ramps `uSettle→1` (crisp); as newer
   turns arrive, older messages climb `uAge` and slowly return toward dissolve —
   the transcript literally becoming smoke as it recedes up the log.
3. **Tool-use & meta as distinct plumes.** (S–M, flavor) Tool calls render as a
   different, faster plume; the `:meta` line ("thought 3.1s · $0.01") drifts as ash.
4. **Idle drift.** (S) Ambient slow smoke when nothing is happening — alive but calm.
5. **The still lens.** *(unplanned; SHIPPED 07-03 by operator request.)* Hovering
   holds a soft circle of the fog perfectly still — the shader blends its clock
   per pixel toward a freeze timestamp captured at hover-start (cheap because
   every motion term flows through one `drift`) — with chromatic aberration on
   the letters strongest at the rim and a warm/cool-fringed ash ring: a loupe
   that magnifies nothing. Known gap: the readout clock is CPU-side, so a page
   mid-condense keeps condensing under the glass.

**Exit criteria:** thinking, streaming, settling, ageing, and idle each have a
distinct, intentional look; the surface feels alive and is readable on demand.

## Phase 4 — Legibility, accessibility & the toggle (make "expressive illegibility" safe)

*The safety story that earns the right to be illegible.*

1. **Hard legibility toggle + `prefers-reduced-motion`.** (M) One control collapses
   the shader to the plain transcript; reduced-motion defaults to it. A per-message
   **"hold to read"** momentarily settles the smoke on demand.
   *Partially shipped 07-03 (operator call): the DOM transcript is now **closed by
   default** — the smoke is the primary reading surface — with a "show text"
   disclosure (header button + the whole fog area is clickable) as the toggle.
   Still open: `prefers-reduced-motion` defaulting to text, and hold-to-read.*
2. **Performance governor.** (M) FPS cap; **pause rendering when the tab is hidden
   or occluded** (heeding the browser roadmap's compositing lessons); on WebGL
   context loss, fall back to the plain transcript rather than a dead canvas.
3. **A11y parity verified.** (S) Screen-reader reads the transcript; selection and
   copy work regardless of shader state.

**Exit criteria:** the effect can never trap a user from reading, and any GPU
failure degrades to plain text — verified, not asserted.

## Phase 5 — "Teach the shader" as a real authoring loop (the ambition)

*Turn the uniform-mapping layer into something Luke — and eventually the agent —
can compose with.*

1. **Tuning panel.** (M) Expose the mapping layer as presets + sliders ("dense
   fog", "wispy", "furnace"), persisted in Settings like terminal backgrounds.
2. **Preset library + per-conversation mood.** (M) Named looks a conversation can
   adopt.
3. **Agent-driven mood (stretch, opportunistic).** (L) Let Claude emit a small JSON
   "mood" spec that maps onto the uniforms, so the model **dresses its own answer**
   — a calm explanation renders as slow cool smoke, an urgent one as a furnace.
   This is literally *teaching the shader* through the remote intelligence, exactly
   on-brand for BusterClaw. Gate behind a decision (Open Q4) — powerful or gimmick.

**Exit criteria:** the smoke is a controllable, presettable medium; (stretch) the
agent can choose how its words are made of smoke.

---

## Cross-cutting concerns (apply to every phase)

- **A. Accessibility is an invariant, not a phase.** The real DOM transcript
  (selectable, screen-reader-available) exists from Phase 1 and is never removed —
  the shader only *presents* it. A hard toggle and `prefers-reduced-motion` always
  reach plain text. This is what makes "illegibility is expressive" defensible.
- **B. Performance & battery.** An always-animating GPU surface is a thermal cost.
  FPS caps, pause-when-hidden, and graceful context-loss fallback are required, not
  optional. No shipping a surface that cooks the laptop.
- **C. Design identity.** Industrial Claw palette; hazard-orange as the *energy*
  accent (thinking/edges), ash/#121212 as the body. Restraint is the aesthetic —
  it should feel like industrial smoke, not a screensaver.
- **D. Reuse, don't fork.** Same `AgentRunner` / `stream_event` / PubSub / Sentinel
  spine as the homepage chat. A Humo turn is audited like any other agent turn.
- **E. Testing honesty.** Pure param math and the uniform-mapping layer are
  bun-tested; **GLSL output itself is not unit-testable** — Phase 0's spike + a
  manual/`/verify` pass in the real shell is the proof for the GPU path. Say so, do
  not fake coverage.
- **F. Local-first / lean bundle.** Prefer hand-rolled bare WebGL2 (one fullscreen
  quad) over pulling three.js/regl — no heavy 3D engine unless the spike forces it.
  No new external network dependency; the shader ships with the app.

## Open questions (need Luke)

1. **Browser GPU API (Phase 0.1):** ~~WebGPU vs WebGL2~~ **RESOLVED 07-03: WebGPU
   (Path A).** Live spike in the shell confirmed adapter + device + `smoke.wgsl`
   near-verbatim at 50 fps. WebGL2 twin retained in the spike as the fallback.
2. **Shader parity with `foreshadow` (strategic, persists past the spike):** do we
   want Humo's shaders to stay a shared WGSL source of truth with `foreshadow`
   (argues for Path A even at some risk) — or is Humo allowed to be its own dialect?
   A maintenance-vs-reuse call only Luke makes.
3. **Engine (Phase 0.2):** hand-rolled bare renderer (lean, recommended) vs.
   three.js/regl/a WebGPU helper (faster to author, +bundle). Recommend hand-rolled
   for a single fullscreen tri.
2. **Text source (Phase 2.1):** raster text-texture (simple, start here) vs. SDF
   glyph atlas (crisper dissolve edges, more work). Revisit after we see edges.
3. **Receding messages (Phase 3.2):** when old text dissolves, is it *gone*
   visually (still in the transcript) — or is there a "settle everything" gesture to
   pull the whole log back to legible? A UX call on how aggressive ageing gets.
4. **Agent-driven mood (Phase 5.3):** genuinely desirable, or a gimmick to cut?
   Decides whether the mapping layer needs a model-facing spec.
5. **Humo's Claude config (Phase 1.2):** same default model/flags as the homepage
   chat, or a distinct configuration (different system prompt / model)?

## Non-goals (on purpose)

- **Replacing the homepage chat.** Luke chose a separate showcase surface; the
  `StatusLive` chat stands.
- **A general shader framework / effect plugin system.** Build Humo's smoke, not a
  shader IDE. The uniform-mapping layer is for *this* effect, not arbitrary ones.
- **True 3D volumetrics / raymarched smoke.** 2D fbm layers sell the look at a
  fraction of the cost; no volumetric rendering.
- **Putting the shader on the xterm terminal.** The terminal keeps its
  image-background feature; Humo is a chat surface, a different thing.
- **Rendering Humo as a native GPUI/wgpu surface** (Path C) to reuse `foreshadow`
  unmodified. It abandons LiveView/PubSub streaming and makes DOM-text-as-texture a
  cross-boundary nightmare — the wrong architecture for a text-in-smoke chat. Humo
  stays an in-DOM canvas in the Phoenix page.
- **A second heavy dependency (three.js et al.)** unless the Phase 0 spike proves
  bare WebGL2 insufficient.

## Sequencing notes

- **Phase 0 gates everything** — no conversation is wired to a medium we haven't
  proven renders in the real shell.
- **Phase 1 before Phase 2:** the plain accessible transcript is both the fastest
  proof the second Claude works *and* the a11y source of truth the shader presents.
  Build it first; it is also the ultimate fallback.
- **Phase 2 before Phase 3:** condense-from-smoke must work for one message before
  we teach it every conversation state.
- **Phase 4 travels with 2–3, not after:** the toggle and the perf governor are
  built as the effect grows, never bolted on at the end.
- Each phase ends with a dated dev summary and its items marked **SHIPPED** inline,
  same convention as `BROWSER_ROADMAP.md` / `BROWSERBASE_ROADMAP.md`.
