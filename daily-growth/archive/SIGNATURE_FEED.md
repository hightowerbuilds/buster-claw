# The Signature Feed — the asset seam as a product

> ## ⛔️ RETIRED — 2026-07-14, operator decision. Not the direction.
>
> Nothing was ever built (this was a pure design doc — Phases 0–3 all
> unstarted). The consequence that matters: the paid tier now rests on
> **BusterPhone alone** — "the phone acquires, the feed retains" loses its
> second half, so retention has to come from the phone being genuinely good.
> The shaders and Industrial Claw CSS stay MIT and bundled exactly as they
> are today; the only thing cut is the subscription-feed idea on top.
>
> Preserved below as the historical design record.

*2026-07-12. Governing idea: **the only thing a fork can never copy is work that
doesn't exist yet.** Code is forkable. Taste, delivered continuously, is not.*

---

## The reframe

The instinct was to hold the signature assets back — keep the shaders and the
Industrial Claw look out of the open build, so the paid DMG has a feel nobody can
strip. That instinct is right about *what* is valuable and wrong about *how* to
protect it.

Withholding a file protects it once. **Publishing a stream protects it forever.**

So the assets are not a vault, they're a **feed**: an ongoing drop of new shaders,
palettes, phone faces, and greeting voices, shipped to subscribers on a cadence.
That inverts every property we cared about:

| | Vault (hold assets back) | **Feed (ship assets continuously)** |
|---|---|---|
| What a fork can take | Everything you've made, once they strip it | **Nothing you haven't made yet** |
| What piracy costs you | The asset | **Nothing — you're selling novelty, not files** |
| What the open build looks like | Deliberately worse | **Beautiful — it's the advertisement** |
| Why someone keeps paying | They don't; it's a one-time feel | **New work keeps arriving** |
| What you must do forever | Guard | **Publish** |

You are selling a **subscription to novelty**, not a set of files. A magazine
doesn't die because back issues leak.

## The three consequences (read these before building)

**1. The open build must be gorgeous.** This is the part that feels backwards and
isn't. The five current shaders (smoke, waves, weather, mandel, face) and the
Industrial Claw CSS stay **MIT and bundled** — they are the ambassadors. A stripped,
neutral open version would protect assets nobody was going to steal, at the cost of
the single best reason anyone screenshots this project. **The feed is additive: it
is what comes *next*, not what we took away.**

**2. This is a treadmill, and that's the honest cost.** The moment the feed is the
reason people pay, you have committed to publishing new work on a cadence — forever,
or until the subscription's value decays. That is a real, recurring labor
obligation, and it is not a build task you can finish. Decide you want that life
before you sell it.

**3. It retains, it doesn't acquire.** Nobody buys a desktop agent because it has
nice shaders. They buy it because **it answers their phone**
(`GO_TO_MARKET_ROADMAP.md` V.1). So: **BusterPhone acquires; the Signature Feed
retains.** One subscription, two reasons to keep paying. Don't market the feed as
the headline — market it as what keeps arriving after you're in.

## Why the seam is nearly free

The runtime already does the hard part. `BusterClaw.Shaders` loads a `.wgsl` file
from `<workspace>/shaders/<name>.wgsl`, validates it, and `GET /shaders/:name` hands
it to the `SmokeBackground` hook, which compiles it live via WebGPU — **no recompile,
no rebuild**. Validation already exists: a 64KB cap, a name regex, an `fs_main`
requirement, and a browser-side compile check that falls back on error
(`lib/buster_claw/shaders.ex:30,60-77`).

And `BusterClaw.Google.BundledClient` is already the pattern for the delivery half:
fetch JSON from a URL we control, cache it in `:persistent_term`, refresh in the
background, degrade gracefully when it's unreachable
(`lib/buster_claw/google/bundled_client.ex:8-13`).

**A feed is those two things wired together.** The rendering path doesn't change.

## Phases

### Phase 0 — Unify the loader (S)
Built-in shaders live in the JS bundle; custom ones load from the workspace. Two
paths, one behavior. Collapse them so "bundled" and "installed" differ only in where
the bytes came from. Everything below depends on this seam existing.

### Phase 1 — The pack format (M)
A **pack** is a manifest plus assets:

```
manifest.json   { name, version, author, assets: [...] }
shaders/*.wgsl
palettes/*.json
```

`Packs.install/1` validates and installs into the workspace; the Appearance tab
lists installed packs and lets you switch. **Local install works with no server at
all** — a pack is a file you can hand someone. This keeps Channel A whole: a
self-hoster can author and install their own packs forever, free.

### Phase 2 — The feed (M)
A manifest at `buster.mom`, entitlement-gated, fetched and cached exactly like
`BundledClient`. New drops appear in Appearance with a "new" badge. Server-side
enforcement — **the client only ever asks "what am I entitled to?"**, never holds a
key or checks a license (`GO_TO_MARKET` Part V.2: no client DRM, ever).

**Offline is mandatory.** Installed packs live in the workspace and keep working
with no network. Appearance must never depend on reachability — an unreachable
buster.mom means "no new drops," not "no shaders."

### Phase 3 — Beyond shaders (M)
The seam generalizes, and the most valuable extension points at the money leg:

- **Phone shaderfaces** — the per-contact visual identities in `/phone`
- **Greeting voices / audio** — the answering-machine greeting is the most personal
  surface in the app, and it's the paid feature. A pack that changes how *your phone*
  sounds is worth more than one that changes a wallpaper.
- **Palettes and terminal backgrounds**

## Hard security boundary

**A pack carries WGSL and data. Never JavaScript. Not ever.**

This line is non-negotiable and must be enforced at install, not at render. WGSL
compiled in WebGPU is genuinely sandboxed — it cannot reach the DOM, the filesystem,
`window.__TAURI__`, or the terminal-spawn handlers. **JavaScript from a remote feed
would be arbitrary code execution inside the Tauri webview**, which is precisely what
the CSP (`plugs/content_security_policy.ex`) exists to prevent. A feed that can ship
JS is a supply-chain backdoor with a subscription attached.

Also required:

- **Integrity on the wire.** HTTPS is necessary and not sufficient — sign the manifest
  and verify, so a compromised host can't push assets to every install.
- **GPU denial-of-service is the real residual risk.** A hostile or merely bad shader
  can hang the GPU. The existing 64KB cap and compile-check help; add a render-time
  watchdog that falls back to a built-in on hang, so a bad drop can't brick the
  homepage.
- **Sentinel-visible.** Pack installs are a mutation from an outside source; they
  belong on the audit feed like any other untrusted ingest.

## Open questions

- **Cadence.** Monthly drop? Whatever-you-feel-like? The subscription's perceived
  value is set by the *rhythm*, not the volume. Pick one you can actually sustain
  in a bad month.
- **Do packs bundle with the phone subscription, or price separately?** Instinct:
  **bundle.** A second SKU doubles the billing surface to defend a feature whose job
  is retention, not acquisition.
- **Community packs?** The format makes third-party packs trivial — which is great
  for the ecosystem and directly cannibalizes the thing you're selling. Probably
  yes anyway (it's MIT; someone will do it regardless), but go in knowing.
