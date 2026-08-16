# Trust claims and support — making the pitch true before strangers arrive

**Carved out of the launch roadmap 2026-08-09 · Status: ACTIVE, mostly R2.**

> ### The one-sentence version
>
> **The product is sold on auditability, and the audit story is currently partly
> unbacked — shipping it to strangers unbacked is the one reputational risk that
> compounds.**

**Three of these are not R2, and that distinction is the point.** The
presentation items — an unbuilt approval gate, a buried Security tab, an
undisclosed `bypassPermissions` — are about what a stranger can *infer* without
being told, and a Release 1 audience can simply be told. **G-34 and G-35 are
different: they are safety, not presentation, and a bug does not care whether it
was briefed.**

> ### G-30 was promoted to R1 on 08-16, and the argument is not a preference
>
> **The release plan's own first-run test already requires it.** `IX.3` in
> [`DISTRIBUTION`](../distribution/DISTRIBUTION_ROADMAP.md) lists *"stop the
> agent immediately"* as one of its six tasks and says outright: **"Tasks 4 and 5
> are the ones that matter — they are the product's claim,"** with a pass bar of
> 4 of 5 users completing them unaided.
>
> Until 08-16 that task could not be completed inside the app at all. So the
> release gate contained a test nobody could pass, and its fix was scheduled for
> the release *after* the one it gates. **That is an internal contradiction, not
> a judgement call about polish** — either `IX.3` drops the task or `G-30` moves,
> and dropping it would mean dropping the product's claim from the product's own
> test.
>
> The 08-16 [novice review](../../archive/NOVICE_AI_APP_REVIEW.md) reached the
> same place from outside, with a sentence worth keeping: **"A new user should
> never need a command to regain control."**

**What is actually unbacked today**, confirmed at HEAD:

| Claim | Reality |
|---|---|
| Refusals are actionable | `sentinel/pending.ex` — its own moduledoc says *"Approve/deny actions are Phase 2."* It is an in-memory stub |
| ~~There is an emergency brake~~ | **CLOSED 08-16 (`G-30`).** Was: zero occurrences of `STOP` or `kill_switch` anywhere in `lib/buster_claw_web/` — the brake was a file on disk you learned about from a markdown doc. `DutyLive` now shows the shift and stops it |
| Security is visible | `settings_tabs.ex` — last of seven |
| We can see failures | No telemetry, no crash reporting, and as of 08-14 no Sentry code at all — the integration that read the user's own project was removed |
| We can support a stranger | The only diagnostic path is a stderr log in Application Support |

The subsystem behind the first three is `Sentinel`, whose audit spine shipped
(Phases 0–1 + CSP). **The gap is not the spine — it is that the spine has no
approve/deny and no visible brake**, while the README implies both.

---

## The gate

*Numbers are stable and cited from commit messages — re-tagged and re-ordered,
never renumbered. `G-25`–`G-35` were carved out of the launch map and keep their
labels.*

### G-25 — Survivable in the wild **[R2]**

You cannot support what you cannot see, and a public download means strangers.

- [ ] **G-25.** **Crash reporting / minimal telemetry** — consent-gated, anonymous,
      default-off. An install ID and a handful of events: app opened, feature touched,
      crash. A retention thermometer, not analytics. Without it the release is unmeasurable.
- [ ] **G-26.** **A user-facing error surface** — "something went wrong, here's what to do."
      Today the only path is a stderr log in Application Support.
- [ ] **G-27.** A documented clean uninstall: app, Application Support, Keychain items,
      WebKit cache.
- [ ] **G-28.** A one-command diagnostic bundle for support (versions, log tail, no secrets).

### G-29 — Trust claims must be true **[R2, except G-30/G-34/G-35]**

The product is sold on auditability. Shipping to strangers with the claim unbacked is the
one reputational risk that compounds.

> **Why most of this is R2 but three items are not.** The presentation items — an unbuilt
> approval gate, a buried Security tab, an undisclosed `bypassPermissions` — are about what a
> stranger can *infer* without being told, and an R1 audience can simply be told. **G-34 and
> G-35 are different: they are safety, not presentation, and a bug does not care whether it
> was briefed.** An agent that walks through a real payment page does that to a friend just
> as readily. Both are cheap; do them for R1.
>
> **G-30 joined them 08-16** for a different reason: it is not that a briefing would fail,
> it is that `IX.3` already tests it and the test was unpassable. See the banner at the top.

- [ ] **G-29.** **Build the approval gate or stop implying it exists.** `Sentinel.Pending` is
      an in-memory stub whose own moduledoc says approve/deny is Phase 2, while the README
      implies refusals are actionable. *1 day to be honest; more to build.*
- [x] **G-30.** **A visible kill switch. [R1 — DONE 08-16.]** ~~Zero `STOP`/`kill_switch`
      references exist in the web layer; the emergency brake is a file on disk the user
      learns about from a markdown doc.~~ `BusterClawWeb.DutyLive` is a fourth sticky dock
      LiveView: invisible when no shift is running, and a hazard-striped **Stand down** button
      whenever one is. See "The visible brake, in full" below for what it stops, what it
      cannot, and why it does not ask twice.
- [ ] **G-31.** **Disclose `bypassPermissions`** on the first on-duty or chat run. A one-line
      disclosure converts a hidden risk into a visible feature.
- [ ] **G-32.** Move **Security** out of last place in Settings and add a refusal badge to
      the dock.
- [ ] **G-33.** Re-review the unauthenticated loopback scopes (`/browser/*`, `/ws/*`,
      `/finance/api/*`) and the plaintext recovery-key reveal. Either defend them in writing
      in `LOCAL_TRUST.md` or close them. *Documented decisions, but decisions to defend.*
- [ ] **G-34.** **Promoted from leftovers, HIGH #1:** walk a live signed-in checkout and confirm the
      payment gate fires. The failure mode is an agent proceeding through a real payment page.
- [ ] **G-35.** **Promoted from leftovers, HIGH #2:** send `nosniff` on the four pipeline-less media routes.


---

## The two safety items, in full

**G-34 and G-35 are the whole reason this map is not purely R2.** Both are cheap;
do them for Release 1.

- **G-34 — walk a live signed-in checkout and confirm the payment gate fires.**
  The failure mode is an agent proceeding through a real payment page. **A
  cart-only errand proves nothing about this** — the gate has never been observed
  firing. Detail lives with the browser surface.
- **G-35 — send `nosniff` on the four pipeline-less media routes.** Detail lives
  with the media surface.

Both were promoted out of the leftovers file, where they were the only two items
marked HIGH.

---

## The visible brake, in full — G-30, shipped 08-16

**`BusterClawWeb.DutyLive`**, a fourth sticky LiveView in the dock footer beside
`DockNavLive`, `MusicPlayerLive` and `DockLive`. Sticky for the reason they are:
an app layout renders once at mount and is never part of a later diff, so a
status that lives in the layout would sit stale until the next navigation. A
nested view has its own process and its own diff.

**It renders nothing when no shift is active.** An empty brake is worse than no
brake — it trains the eye to skip the place the real one will appear.

### What Stand down actually does, measured rather than assumed

`Orchestration.stand_down/1` does two things **in this order**, and the order is
the whole design:

1. **Engages the kill switch** (the `STOP` file). `Dispatcher.maybe_run/1` checks
   `kill_switch_engaged?/0` on every decision (`dispatcher.ex:140`), so this
   closes the door *before* anything else happens.
2. **Stops the shift**, which flips the row to `stopped` and broadcasts
   `:shift_stopped`.

Doing it the other way round leaves a window: `stop_shift` alone would let a
`shift_start` moments later come straight back up, and the `STOP` latch is what
makes the stop *stick* until the operator chooses to go back on duty.
**`shift_start` already clears the latch** (`commands/orchestration.ex:286`), so
resume needs no new mechanism and no second decision about who may clear it.

### What it cannot stop, stated on the button itself

**A run already in flight finishes.** The Dispatcher serialises — at most one run
at a time — and a running one is monitored, not killed. Nothing in the codebase
cancels a headless run mid-flight; it ends on its own or at
`run_timeout_ms`. The surface says so in the sentence beside the button, because
a brake that overstates itself is worse than one that admits its limit:

> Stops new work immediately. A run already in progress finishes on its own.

That sentence is the honest version of the review's ask — *"say what will stop,
what will finish, and how to resume"* — and it is checkable against
`dispatcher.ex:136–169` rather than aspirational.

### It does not ask twice, on purpose

No `data-claw-confirm`. The house idiom gates destructive actions behind a modal,
and this deliberately opts out: **an emergency brake that asks "are you sure"
adds friction at the exact moment friction is most expensive.** The cost is a
possible mis-click, and the cost of a mis-click is bounded — go back on duty, and
`shift_start` clears the latch. The cost of hesitating in front of a dialog while
an agent does something alarming is not bounded.

The explanatory sentence therefore sits *beside* the button where it is read
before the click, not in a dialog after it.

### The chat's Stop is a different thing and stays separate

`chat_panel.ex` already has `cut_run` — a Stop button for a running chat turn.
That is the attended path and it was never the gap. **G-30 was always about
unattended work**, which had no in-app control of any kind. Two buttons named
Stop in one app would be a problem if they competed; they do not, because they
are on different surfaces and stop different machines. Worth stating so nobody
"unifies" them later.

---

## Related, and deliberately elsewhere

- **The audit spine itself** — `Sentinel`, shipped. This map is about the claims
  made *about* it.
- **The policy engine and trust tiers** — `PolicyEngine`, `AgentToolPolicy`.
  Shipped, and the most load-bearing thing in the app with no map of its own.
- **`G-33`'s loopback scopes** — `/browser/*`, `/ws/*`, `/finance/api/*`, and the
  plaintext recovery-key reveal. Documented decisions, but decisions to defend in
  writing in `LOCAL_TRUST.md` or close.
- **The human walkthrough** that exercises much of this against a real build —
  [`RELEASE_GATE_ROADMAP`](RELEASE_GATE_ROADMAP.md), `G-40`.

---

## The risks this map exists to hold down

- **R3 — Public download means strangers on hardware you've never seen.** Every
  untested first-launch path becomes someone's first impression. *Mitigation:*
  `G-25`'s telemetry and `G-26`'s error surface are what convert an invisible
  failure into a fixable one.
- **R6 — Solo-dev support surface, now unbounded.** Autonomous agent + email +
  someone else's Mac, with no cap on who downloads. *Mitigation:* `G-28`'s
  diagnostic bundle, and teaching users to read the Sentinel feed — it is the
  best support tool we have.
- **R8 — The trust story is the product, and it is currently partly unbacked.**
  *Mitigation:* `G-29` through `G-32` are in the release gate for exactly this
  reason.
