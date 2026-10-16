# Reaching Buster Claw from a phone

*Scoped 08-13, **reshaped the same day** by an operator call that changed which
half of the problem we are solving. Companion to [`CLINCH`](CLINCH_ROADMAP.md)
Phases 5–7, which own the Mac side.*

> ## PARKED — the desktop app ships first
>
> **Operator call, 08-13: the phone comes after the desktop app is complete.**
> Nothing in this map starts until Release 1 is out the door
> ([`DISTRIBUTION`](../distribution/DISTRIBUTION_ROADMAP.md)). It is written now
> so the research is not re-derived later, and so nobody wires a phone path into
> Clinch Phase 7's onboarding copy on the assumption that SSH is the answer.
>
> **It isn't.** Read *The shape we chose* before touching this.

---

## The question, stated honestly

"Can I SSH into my laptop from my phone?" is two questions wearing one coat:

| | |
|---|---|
| **A shell on the Mac, from the phone** | Yes. Solved, unglamorous, works today with an off-the-shelf app |
| **The Buster Claw UI on the phone** | Much harder — and **SSH turns out to be the wrong tool** |

---

## The shape we chose

The operator's requirement, in their words: *the ability to converse with Buster
Claw in a way that the model is only ever looking at my computer, and there isn't
a VPN with all of my info out there. The phone is more of a control device than
another iteration of Buster Claw on the phone.*

That is a different target from remote access, and a much better one. Three
consequences follow immediately:

1. **This is not sync, and must never drift into it.** There is one instance, on
   the Mac. The phone holds no copy, works offline never, and has nothing to
   reconcile. Sync would mean a second copy converging over time — a distributed
   system, and one that collides head-on with the loopback premise.
2. **The phone does not need the UI**, which is what made everything hard: iOS
   backgrounding, tunnels, and the 18 of 29 LiveViews that have never been laid
   out narrow.
3. **The transport question mostly evaporates.** What remains is message passing,
   and we already own a message-passing path where **the Mac never listens.**

> **A control device needs a channel, not a window.** Every hard problem in
> Track B below comes from trying to put a window on a phone.

---

## The fundamentals

These are why SSH is not the answer, kept because the reasoning has to survive
the next person who suggests it.

### F1 — iOS suspends a backgrounded app within seconds, and its sockets die

Not a bug, a setting, or a thing a better client fixes — it is the platform's
execution model. A forwarded port lives only while its owning app is alive, so
"open SSH app, start tunnel, switch to Safari" is the exact motion that kills the
tunnel.

**On iPad this is softer**: split-screen keeps both apps foregrounded. An iPad is
a materially easier target than an iPhone, and the two should never be averaged
into one claim.

### F2 — Every iOS SSH client that survives backgrounding borrows an entitlement that has nothing to do with SSH

Persistent background execution is granted to a short list: location, audio,
VoIP/CallKit, Network Extension. SSH qualifies for none, so clients that persist
claim one anyway. Blink's documented mechanism is `geo track`, which **turns on
location tracking** purely to keep the connection alive.

**That is a workaround, not a capability.** It costs a location permission
granted under false pretences, costs battery, and persists at Apple's discretion.

### F3 — mosh fixes the terminal and can never fix the UI

Mosh is the right answer for a *shell* — UDP, survives sleep, roaming and IP
changes. It also **has no port forwarding**, by design. It cleanly solves the
easy question and is structurally incapable of solving the other one.

### F4 — NAT and persistence are different problems

From cell data the Mac has no reachable address. A mesh VPN fixes that. **It does
nothing for F1.** Conflating the two is the most likely way this wastes a month:
reachability improves, the tunnel still dies on lock, and the diagnosis lands on
the wrong layer.

---

# Track A — the control channel *(chosen)*

## The relay is already the rendezvous

`Telephony.Drain` polls **outward** every 30 seconds (`@default_interval_ms
30_000`) against the Supabase relay. Persist-then-ack, with a transcript grace
period. **The Mac never listens.** There is no port to reach, nothing to forward,
nothing exposed — the entire "how does the phone reach my Mac" problem does not
arise, and it has been deployed since 07-12.

That is the same rendezvous pattern a rented cloud box would implement. We built
it already, for telephony, and it generalises.

### What exists, and the one thing that doesn't

Checked rather than assumed, 08-13:

| | |
|---|---|
| Relay + outbound-polling drain | **Built** |
| Outbound replies — `Twilio.send_sms/3` | **Built** |
| Inbound persists, broadcasts to `PhoneLive`, reaches Sentinel | **Built** |
| **An inbound message reaching the agent** | **Missing entirely** — there is not one reference to the agent anywhere in `lib/buster_claw/telephony/` |

So today an inbound message lands in a list in the UI. **It is a mailbox, not a
conversation**, and the gap between those two is most of this track.

## A1 — Carry a message to the model and back

The smallest honest version: a message arriving at the relay reaches the agent,
the agent answers on the Mac against Mac-local context, and the reply returns by
the same path.

- Runs under a caller tier, like every other command path. **Not `:trusted`** —
  a message from a phone is not a person at the keyboard, and the tier system
  only means anything when the surface with the least proof gets the least trust.
- Reuses the existing conversation machinery rather than growing a second chat
  implementation with different semantics — the same reasoning that keeps Notes
  writes on one path.
- Rate-limited and bounded. A loop that answers its own messages is a bill.

## A2 — Authentication, which is the actual work

The phone posts to the relay over HTTPS. **That is a web endpoint, and it needs
real auth — this is the piece that does not exist and must not be hand-waved.**
It is precisely the "web-auth and session-security project" the Clinch map
declined to take on accidentally; taking it on deliberately, scoped to one
endpoint, is a different proposition.

**The natural home is the Clinch, and the machinery already shipped.** A paired
phone is a credential row with the lifecycle Phase 4 built: created, listed,
audited, **revoked**, and re-keyed. Clinch Phase 6 pairs a *forwarding-only*
device; this pairs a *control-only* device — same lifecycle, different
capability, one implementation.

**Invariant, non-negotiable:** a paired phone can converse. It can **never**
manage credentials, and the refusal must be structural — no `__TAURI__`, no
management token — not a policy check one refactor from being wrong.

## A3 — The surface on the phone

A minimal page, added to the home screen. Not the app. Send a message, read the
reply, see whether the Mac is awake.

**"The Mac is asleep" must be a first-class state**, not a spinner that never
resolves. The drain's last successful tick already knows.

**Exit for Track A:** a message sent from a phone on cellular reaches the model,
is answered against Mac-local context, and returns — with the Mac never
accepting an inbound connection, the phone unable to reach `/api/clinch`, and a
revoked phone refused on its next attempt.

---

## What this costs, in money

The reason this track leads: **it adds nothing to the bill.** Telephony becomes
an *option* on top rather than the only way in.

### If we do add SMS or voice

Personal use is cheap. The compliance regime is the real cost.

| | |
|---|---|
| Toll-free number (the trial 844) | ~$2.15/mo |
| Messages, all-in with carrier pass-through | ~$0.012–0.013 each |
| ~300 messages/month, personal use | **~$5–7/mo** |

**Registration is the part that matters, and it does not belong to Twilio.**
Brand and campaign fees are The Campaign Registry's and the carriers' — *every*
US provider passes them through. **Switching to AWS End User Messaging or anyone
else swaps the vendor and keeps the fees.**

Two specifics worth carrying forward:

- The trial number is **toll-free**, which uses **Toll-Free Verification, not
  A2P 10DLC** — a cheaper path with its own approval process that can be
  rejected. Confirm which regime applies before building on SMS.
- **The GTM went voice-first specifically to avoid A2P.** Wiring SMS
  conversation walks back into what that decision routed around. That is a
  reason to keep telephony optional here, not a reason to abandon it.

### The $5 cloud box, evaluated

*Considered 08-13: could a $5 AWS instance replace Tailscale and Twilio?*

**Replace Twilio: no.** A real phone number needs a carrier, and the
registration follows you to whichever one you pick.

**Replace Tailscale: yes, genuinely** — a rented rendezvous box is a sound,
classic architecture, and $3–5/mo is the right price. It is rejected for a
different reason:

> **A box you rent sees more of your data than the VPN it replaces.** Tailscale
> is WireGuard — encrypted end to end, device to device, unreadable by them. A
> relay terminating TLS holds your Chat messages **in plaintext, in RAM, on
> hardware in someone else's datacenter.** Avoiding it with end-to-end SSH drags
> back every problem in F1–F4.

And you would then be running a public internet-facing server: patching, cert
renewal, auth, rate limits, abuse. **The $5 is the cheapest part of it.**

Since the relay already implements the same pattern with no listener on the Mac,
the box buys nothing we do not have. If Supabase ever needs replacing, that is a
component swap — not a new architecture, and not a reason to start one now.

---

# Track B — the full UI on a phone *(deferred, possibly never)*

Only if Track A proves that a conversation is not enough. Kept because the
research is done and re-deriving it is waste.

## B1 — Measure, do not design

Every claim in F1–F4 is structural or vendor-documented; **none is measured on a
real device with our app**, and the Clinch's rule is *prove the tunnel first*.

| Step | What it proves |
|---|---|
| Load the UI, navigate three tabs | Initial HTML + routing |
| Stream a long Chat response | LiveView WebSocket under load |
| **Lock the screen 60s, unlock** | The F1 test. The one that matters |
| **Switch apps 5 min, return** | The real usage pattern |
| Idle 30 min on cellular | Keepalive and NAT rebinding |
| Sleep the Mac, wake it | Reconnect, not just survival |
| Upload from the photo library | Multipart through the transport |
| Visit Terminal, Browser, Voice | That the remote-mode notices render (guarded 08-13, `d26c4ad`) |

Across **SSH `-L` from an iOS client**, **the same over Tailscale**, and
**Tailscale Serve** — on iPhone *and* iPad, because F1 differs. Record battery
drain and whether the client demanded a location permission.

## B2 — Choose a transport

| Option | Strength | Cost / risk |
|---|---|---|
| SSH `-L` from an iOS app | Preserves every invariant; no new vendor | **Persistence depends on a third-party background hack (F2)** |
| Tailscale + SSH `-L` | Fixes NAT (F4); pairs with Clinch Phase 6's restricted key | No better on the thing that actually breaks |
| **Tailscale Serve** | **No SSH app on the phone.** Persistence via an entitlement iOS actually grants. **Loopback bind preserved.** Supplies identity headers | `check_origin` becomes per-user config; Funnel footgun; first proxy in front of Phoenix; vendor dependency the operator has declined |
| Bind Phoenix to tailnet/LAN | — | **Already rejected**, and Serve makes it unnecessary |
| Public HTTP tunnel / Funnel | — | **Already rejected** |

**Serve is technically the strongest and is currently declined on preference** —
the operator does not want a mesh VPN in the path. Recorded rather than
argued: if Track B ever revives, this is where it starts, and the technical case
is [Tailscale's own recommendation](https://tailscale.com/docs/features/tailscale-serve)
that identity-header backends **listen only on localhost**, which is what we
already do.

## B3 — Origin and identity

Only if B2 selects Serve. `check_origin` becomes a runtime list — loopback
always, tailnet host only when remote mode is on. The existing guard
(`remote_mode_test.exs`) refuses `false` and `true` and must keep passing: a list
that grows is fine, a list that becomes a boolean is the failure it was written
for. Plus a guard that **Funnel is off** — one command makes the service public
and strips the identity headers, which is too sharp an edge for setup copy.

## B4 — The UI has to survive a 390pt screen

**11 of 29 LiveViews contain any responsive breakpoint classes.** Triage over
Chat, Activity, Notes, Calendar and Settings; the rest may be honestly cramped.

---

# Track C — the companion app *(after the desktop app is complete)*

Explicitly last, by operator call. Four shapes, one survives:

| Shape | Verdict |
|---|---|
| `WKWebView` wrapper around the tunnel | **Near-zero value.** Add to Home Screen already gives an icon and a chromeless window, and the wrapper hits the same F1 wall |
| Ship our own Network Extension VPN | **Reject.** The honest way to get persistence, and it makes us a network vendor — entitlement request, WireGuard-class engineering, permanent security surface. Rebuilding Tailscale to avoid depending on Tailscale |
| Full native client over a public authenticated API | **Reject.** The web-auth project already declined, plus a second complete UI forever |
| **Narrow companion — notifications, approvals, Activity, BusterPhone** | **The only one worth scoping.** It does what a web page cannot: push, an approve/deny surface for agent actions, share-sheet capture into Notes |

The narrow companion is also the only shape where the management invariant is
comfortable rather than strained: it never looks like a shell, so it is never
tempted to act like one.

---

## Invariants

1. **Phoenix binds only to loopback.** Inherited, non-negotiable.
2. **A phone is never a credential-management surface.** Not the control page,
   not a native app. **The most likely way a phone app damages this codebase is
   by becoming a second shell that re-opens the door Clinch Phase 2 closed.**
   Structural refusal, not a policy check.
3. **No public exposure.** No Funnel, no router forwarding, no third-party HTTP
   tunnel, no rented public listener.
4. **No sync.** One instance, on the Mac. A phone that holds state is a
   different product.
5. **Nothing here becomes the only way in.**

---

## Rejected, and why

| Alternative | Decision |
|---|---|
| **Buster Claw provisions its own cloud instance** | **Reject.** It means handing the agent credentials with instance-creation rights — the most abusable class there is, where the failure mode is a five-figure bill from a loop. It contradicts the standing rule that *Buster Claw never automates public exposure or UPnP*, at larger scale. And it points the agent at credentials that **spend money**, when the Clinch exists to keep it from credentials that merely unlock things |
| A rented relay box instead of the Supabase relay | **Reject for now.** Same pattern, no listener gained, and TLS terminating on rented hardware is a worse privacy posture than the VPN it was meant to avoid |
| Switching SMS providers to escape A2P fees | **Impossible.** The fees are the carriers' and The Campaign Registry's; every US provider passes them through |
| An SSH client's background hack as *the* supported path | **Reject as the path.** Fine as a documented option with its costs named |
| mosh for the UI | **Impossible**, not merely unwise (F3) |
| Tauri's iOS target | **Reject.** Tauri v2 builds for iOS, but our shell is PTY, Keychain, `WKUIDelegate` and native-webview code that shares almost nothing. A new app wearing a familiar name |
| Averaging iPhone and iPad behaviour | **Reject.** Split-screen changes F1 materially |

---

## Open questions

**Track A** — what tier a phone message runs under; whether the relay's erase
window is right for conversation rather than telephony; what "the Mac is asleep"
looks like on the phone.

**Track B**, if it ever revives — whether a LiveView WebSocket survives an iOS
screen lock over Serve. **The Network Extension staying alive does not entail
the browser's connection staying alive**, and that is the assumption most likely
to be wrong.

---

## Research sources

- [Twilio US SMS pricing](https://www.twilio.com/en-us/sms/pricing/us)
- [A2P 10DLC brands, campaigns and costs](https://www.piyushgambhir.com/blogs/twilio-a2p-brands-campaigns-costs-throughput-compliance)
- [Twilio 10DLC registration explained](https://www.sociocs.com/post/twilio-10dlc-explained/)
- [Tailscale Serve](https://tailscale.com/docs/features/tailscale-serve) — loopback proxying, identity headers, the localhost-binding recommendation
- [Tailscale Funnel](https://tailscale.com/docs/features/tailscale-funnel) — public exposure, and why it and Serve cannot share a port
- [Blink Shell — advanced SSH, tunnels and `geo track`](https://docs.blink.sh/advanced/advanced-ssh)
- [Termius — port forwarding and tunneling](https://docs.termius.com/organize-and-connect-to-hosts/port-forwarding-and-tunneling)
- Carried from [`CLINCH`](CLINCH_ROADMAP.md): OpenSSH forwarding and authorized-key restrictions, Tailscale SSH
