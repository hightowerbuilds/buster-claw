# Trust claims and support — making the pitch true before strangers arrive

**Carved out of the launch roadmap 2026-08-09 · Status: ACTIVE, mostly R2.**

> ### The one-sentence version
>
> **The product is sold on auditability, and the audit story is currently partly
> unbacked — shipping it to strangers unbacked is the one reputational risk that
> compounds.**

**Two of these are not R2, and that distinction is the point.** The presentation
items — an unbuilt approval gate, a buried Security tab, an undisclosed
`bypassPermissions` — are about what a stranger can *infer* without being told,
and a Release 1 audience can simply be told. **G-34 and G-35 are different: they
are safety, not presentation, and a bug does not care whether it was briefed.**

**What is actually unbacked today**, confirmed at HEAD:

| Claim | Reality |
|---|---|
| Refusals are actionable | `sentinel/pending.ex` — its own moduledoc says *"Approve/deny actions are Phase 2."* It is an in-memory stub |
| There is an emergency brake | **Zero** occurrences of `STOP` or `kill_switch` anywhere in `lib/buster_claw_web/`. The brake is a file on disk you learn about from a markdown doc |
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

### G-29 — Trust claims must be true **[R2, except G-34/G-35]**

The product is sold on auditability. Shipping to strangers with the claim unbacked is the
one reputational risk that compounds.

> **Why most of this is R2 but two items are not.** The presentation items — an unbuilt
> approval gate, a buried Security tab, an undisclosed `bypassPermissions` — are about what a
> stranger can *infer* without being told, and an R1 audience can simply be told. **G-34 and
> G-35 are different: they are safety, not presentation, and a bug does not care whether it
> was briefed.** An agent that walks through a real payment page does that to a friend just
> as readily. Both are cheap; do them for R1.

- [ ] **G-29.** **Build the approval gate or stop implying it exists.** `Sentinel.Pending` is
      an in-memory stub whose own moduledoc says approve/deny is Phase 2, while the README
      implies refusals are actionable. *1 day to be honest; more to build.*
- [ ] **G-30.** **A visible kill switch.** Zero `STOP`/`kill_switch` references exist in the
      web layer; the emergency brake is a file on disk the user learns about from a markdown
      doc.
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
