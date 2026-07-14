# 07-13-2026 Summary

The app learned to look out the window, and the browser learned where the
agent keeps its work. Two feature legs today — **the homepage weather shader
now renders the user's real sky**, and **the browser grew a hardcoded Pages
button** over a real index of the agent's HTML — plus one honesty cut: the
bundled Financial Informant page is retired.

## Contacts: one person, both channels (`ed048c1`)

The day opened on the operator's contacts unification: `BusterClaw.Contacts`
replaces the telephony-only contact store, email and phone trust now hang off
one person record, and the decoy trust column is gone. (That commit also
carried the StatusLive wiring for the weather sky below, which landed in the
same file.)

## The weather background becomes the real sky

The homepage `weather` shader had been running a fake ~2-minute demo loop —
sunny → windy → rain → snow on a clock, noon forever. Now, when the homepage
background is in weather mode and a location is set (the Time & Place
widget's city), the shader renders **that place's actual sky**:

- `Weather` (Open-Meteo, same single keyless call) now also returns cloud
  cover, sunrise/sunset as day-fractions, and the location's UTC offset.
- `StatusLive` pushes a `bc:sky` event to the shader hook at mount, on a
  10-minute refresh tick, on background-mode change, and on location change.
- The `SmokeBackground` hook packs the real conditions into uniform slots the
  background never used (lens = local-time/sunrise/sunset/cloud; mood =
  rain/thunder/snow; style = wind), easing everything so demo→live and
  condition changes drift like weather instead of popping.
- The WGSL gained a live mode: daylight follows the real sun window with a
  twilight shoulder, the sun arcs sunrise→sunset, the moon takes the night
  leg, stars come out under clear night skies, dawn/dusk warm the horizon,
  and precipitation dims after dark. The demo loop survives untouched as the
  no-location fallback.
- New pure `sky.js` module (WMO code → condition amounts; local day-fraction
  math) with bun tests; sunrise/sunset shaping covered in `weather_test.exs`.

Follow-up noted, not built: the Time & Place daycycle panel still runs off
the machine clock, not the selected region.

## Browser: the Pages button

The agent has been saving self-contained HTML into `<workspace>/pages/` by
convention (nine pages in the dev workspace) with no way for a human to find
them. Now:

- A hardcoded **Pages** text button sits in the chrome toolbar next to Home
  and navigates to `/browser/pages`.
- The new index (`BrowserPagesController` + `Pages.list/0`) lists every
  `.html` in `pages/` — agent pages newest-first with parsed `<title>`,
  filename, and date; bundled pages after in catalog order. Entries open via
  `/ws/file` and record into browser history; the empty state tells users to
  ask the agent for a page.
- The agent's introduction now documents `pages/` in the workspace layout —
  single self-contained `.html` with a real `<title>` — so the button's
  promise is a stated convention, not folklore.

## Financial Informant: retired

The second hardcoded bundled page is gone by operator call: module deleted,
unbundled from `Pages`, and `install!` now removes the stale
`financial-informant.html` from existing workspaces so it can't masquerade as
an agent-made page in the new index. The `/finance/api` loopback stays — it's
generically useful for finance pages the agent builds — with docs updated to
say so.

## State of play

Weather sky: shipped, tests green (32 bun + full weather/StatusLive suites).
Pages: shipped, tests green (pages, new controller, chrome, finance API).
Next attention: arm64 build remains the shipping prerequisite (distribution
roadmap); BusterPhone next step is still the operator's Twilio upgrade +
Voice webhook wiring.
