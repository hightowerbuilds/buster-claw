# Reaching Buster Claw from a phone

*Scoped 08-13. Companion to [`CLINCH`](CLINCH_ROADMAP.md) Phases 5–7, which own
the Mac side. This map owns the phone side and nothing else.*

**Nothing here is built. This is a research map, and its first phase is
measurement rather than construction** — because the central question is about
how iOS behaves, and that is not answerable by reading our own source.

---

## The question, stated honestly

"Can I SSH into my laptop from my phone?" is two questions wearing one coat, and
the answer differs for each:

| | |
|---|---|
| **A shell on the Mac, from the phone** | Yes. Solved, unglamorous, works today with an off-the-shelf app |
| **The Buster Claw UI on the phone** | Much harder, and **SSH may be the wrong tool for it** |

The second is the one worth a roadmap. Buster Claw's UI is a Phoenix app bound
to `127.0.0.1`; reaching it means a forwarded port, and a forwarded port means a
process on the phone holding a TCP socket open **while you are looking at a
different app** — which is precisely what iOS is designed to prevent.

---

## The fundamentals

Four facts decide everything downstream. Three are structural and will not
change; the fourth is the one that reframes the project.

### F1 — iOS suspends a backgrounded app within seconds, and its sockets die

This is not a bug, a setting, or a thing a better SSH client fixes. It is the
platform's execution model. A forwarded port survives only while its owning app
is alive, so the naive flow — open SSH app, start tunnel, switch to Safari — is
the exact motion that kills the tunnel.

**On iPad this is softer:** split-screen keeps both apps foregrounded, which is
why iPad users report tunnels that "just work" and iPhone users do not. **An
iPad is a materially easier first target than an iPhone**, and we should not
average the two into one claim.

### F2 — Every iOS SSH client that survives backgrounding borrows an entitlement that has nothing to do with SSH

Persistent background execution on iOS is granted to a short list of categories
— location, audio, VoIP/CallKit, and Network Extension. An SSH client qualifies
for none of them, so the ones that persist claim one anyway. Blink's documented
mechanism is explicit about it: `geo track` **turns on location tracking** for
the sole purpose of keeping the SSH connection alive. Termius advertises
multi-hour background sessions; NaviTerm markets background port forwarding as a
feature.

Read that plainly: **the stability is a workaround, not a capability.** It costs
a location permission granted under false pretences, it costs battery, and it
persists at Apple's discretion rather than the vendor's. Building our
recommended remote path on top of someone else's entitlement workaround is a
dependency we would not accept anywhere else in this codebase.

### F3 — mosh fixes the terminal and can never fix the UI

Mosh is the right answer to F1 for a *shell*: it is UDP-based, survives IP
changes, sleep and roaming, and reconnects without ceremony. It also **has no
port forwarding**, by design and long-standing.

So mosh cleanly solves question one and is structurally incapable of solving
question two. Any plan that says "use mosh for stability" has quietly answered
the easy question.

### F4 — NAT and persistence are different problems, and Tailscale only solves one

From cell data the Mac has no reachable address; it sits behind home NAT. A VPN
mesh (Tailscale or equivalent) fixes that and gives the phone a stable address
for the Mac.

**It does not fix F1.** Tailscale-plus-SSH still needs an SSH app holding a
socket. Conflating the two is the most likely way this project wastes a month:
you install Tailscale, reachability improves, the tunnel still dies on lock, and
the diagnosis lands on the wrong layer.

### What follows

> **"Stable SSH on a phone" decomposes into reachability and persistence. SSH
> owns neither. It is the thing that runs *through* a solution to both.**

Which raises the question the rest of this map turns on: if the phone needs a
persistent, reachable transport anyway, **does it need SSH at all?**

---

## The finding that reframes it

`tailscale serve` proxies a **loopback** service to the tailnet over HTTPS. The
Mac's own `tailscaled` connects to `127.0.0.1:4000` locally and publishes it to
your other devices. On the phone, the Tailscale app is a Network Extension VPN —
**a category iOS legitimately allows to persist**, which is exactly the
entitlement F2 says SSH clients have to fake.

The consequence for us is the interesting part:

- **Phoenix stays bound to `127.0.0.1`.** Our hardest invariant survives
  untouched. Tailscale's own documentation independently arrives at the same
  rule: *"when you use the identity headers to authenticate to a backend
  service, it's best practice to only have the service listen on localhost."*
  That is our existing architecture, described by someone else, for their
  reasons.
- **The phone needs no SSH client, no port forward, and no background hack.**
  Safari and the Tailscale app.
- **Serve supplies identity headers** (`Tailscale-User-Login` and friends). The
  Clinch roadmap rejects binding to a LAN address because it *"erases the
  loopback trust boundary without replacing it with identity."* Serve does not
  erase the boundary **and** offers the identity — the first path that gets both.

This is not free, and the costs are real and specific:

- **`check_origin` breaks.** Production is `["//127.0.0.1", "//localhost"]`; the
  origin becomes `https://<machine>.<tailnet>.ts.net` and the LiveView WebSocket
  is refused. Fixable and one line, but it is a **per-user** value, so it has to
  come from config the Remote Access panel writes — not a constant.
- **Funnel is a one-word typo away.** `tailscale funnel` on the same port makes
  the service **public**, and Funnel traffic carries **no identity headers**.
  Serve and Funnel cannot share a port; whichever ran last wins. This deserves a
  guard, not a warning in setup copy.
- **Phoenix would sit behind a TLS-terminating proxy for the first time** —
  forwarded scheme/host handling, secure cookies, URL generation.
- **Vendor dependency.** Phase 7 of the Clinch map commits to keeping the
  private-network guide *"optional and vendor-neutral."* Serve cannot be the
  only path.

---

## Invariants

Inherited from the Clinch, and non-negotiable here:

1. **Phoenix binds only to loopback.** Every option below either preserves this
   or is rejected.
2. **A phone is never a credential-management surface.** Not the mobile web UI,
   not a future native app. Management requires `window.__TAURI__` *and* an API
   token, and no phone has either. **A native iOS app must not become a second
   shell that quietly re-opens the door Phase 2 closed** — this is the single
   most likely way an app would damage the security model, and it must be a
   structural refusal rather than a policy check, exactly as on the desktop.
3. **No public exposure.** Not Funnel, not router port-forwarding, not a
   third-party HTTP tunnel. Unchanged from the Clinch's rejected list.
4. **Nothing here becomes the only way in.** SSH-over-OpenSSH stays a supported
   path for people who will not install a mesh VPN.

---

## Phase 0 — Measure, do not design

**The whole map is provisional until these numbers exist.** Every claim above
about iOS is either structural (F1, F3) or sourced from vendor documentation
(F2) — none of it is measured on *your* device with *our* app, and the Clinch's
own rule is *prove the tunnel first*.

Run each transport against the same script and record what actually happens:

| Step | What it proves |
|---|---|
| Load the UI, sign nothing, navigate three tabs | Initial HTML + routing |
| Send a long Chat message, watch it stream | LiveView WebSocket under sustained load |
| **Lock the screen for 60s, unlock** | The F1 test. The one that matters |
| **Switch to another app for 5 min, return** | The real usage pattern |
| Leave it idle 30 min on cellular | Keepalive and NAT rebinding |
| Sleep the Mac, wake it | Reconnect, not just survival |
| Upload a file from the phone's photo library | Multipart through the transport |
| Visit Terminal, Browser, Voice tabs | That the remote-mode notices render (guarded 08-13, `d26c4ad`) |

Across three transports: **SSH `-L` from an iOS client**, **the same over
Tailscale**, and **Tailscale Serve**. On both iPhone and iPad if one is
available, because F1 differs between them.

Record battery drain and whether the SSH client demanded a location permission.

**Exit:** a filled table. Not a decision — the table *is* the deliverable, and
Phase 1 is not allowed to start without it.

---

## Phase 1 — Choose the transport

| Option | Strength | Cost / risk |
|---|---|---|
| **A. SSH `-L` from an iOS SSH app** | Preserves every invariant untouched; no new vendor; works on any network we can already reach | **Persistence depends on a third-party background-mode workaround (F2).** Battery cost, a location prompt, and Apple's discretion |
| **B. Tailscale + SSH `-L` over the tailnet** | Fixes NAT (F4); keeps the SSH gate; pairs with the Clinch's forwarding-only key | Still has A's persistence problem. Strictly better than A on reachability, no better on the thing that breaks |
| **C. Tailscale Serve** | **No SSH app on the phone.** Persistence via an entitlement iOS actually grants. Loopback bind preserved. Gains identity headers | `check_origin` must become config-driven; Funnel footgun; first proxy in front of Phoenix; vendor dependency |
| D. Bind Phoenix to the tailnet/LAN address | — | **Already rejected** in the Clinch map, and Serve makes it unnecessary |
| E. Public HTTP tunnel / Funnel | — | **Already rejected.** A web-auth and session-security project wearing a networking hat |

**Proposed: C for the UI, A retained for the shell.** They are complements, not
rivals — Serve gives you the app on your phone, and an SSH client (with mosh,
per F3) gives you a terminal when you want one. Neither needs the other.

**B is the fallback** if Serve fails the Phase 0 table or the proxy proves
fragile, on the same logic the Clinch applies to its gateway: *if the proxy adds
fragility, take the simpler thing.*

**A stays supported regardless**, for invariant 4.

---

## Phase 2 — Make origin and identity honest

Only if Phase 1 selects C.

- `check_origin` becomes a list assembled at runtime: the two loopback entries
  always, plus the tailnet hostname **only when remote mode is on**. The
  existing guard (`remote_mode_test.exs`) already refuses `false` and `true` and
  must keep passing — a list that grows is fine, a list that becomes a boolean
  is the failure it was written for.
- Decide, explicitly, whether identity headers are *used* or merely *present*.
  Trusting them is only sound while nothing but `tailscaled` can reach the port,
  which is true precisely because of invariant 1 — so **the day someone widens
  the bind, header trust silently becomes forgeable.** If we consume them, that
  coupling needs a test that fails on the bind change, not a comment.
- **A guard that Funnel is not enabled**, checked from the app and surfaced in
  the Remote Access panel. One command turns private into public and strips
  identity; that is too sharp an edge to leave to documentation.
- Proxy hygiene: forwarded scheme/host, secure cookie behaviour, generated URLs.

---

## Phase 3 — The UI has to survive a 390pt screen

Transport is only half of "usable from a phone." **11 of 29 LiveViews contain
any responsive breakpoint classes**, which means the majority were laid out for
a desktop window and have never been looked at narrow.

This is not a rewrite. It is a triage pass over the surfaces a phone would
actually use — Chat, Activity, Notes, Calendar, Settings — with the rest allowed
to be honestly cramped. The dock, the split view and any fixed-width panel are
the likely casualties.

**This phase blocks the app question below**, because a native shell around an
unusable layout is an expensive way to ship the same problem.

---

## Phase 4 — The companion app question

Deliberately last. Four shapes, and only one survives contact with F1–F4:

| Shape | Verdict |
|---|---|
| **A `WKWebView` wrapper pointed at the tunnel** | **Near-zero value.** With transport C, Safari plus Add to Home Screen already gives an icon and a chromeless window. Without C, the wrapper cannot hold the tunnel either — it faces the same F1 wall |
| **We ship our own Network Extension VPN** | **Reject.** It is the honest way to get persistence, and it makes us a network vendor: an entitlement request, WireGuard-class engineering, and a permanent security surface. We would be rebuilding Tailscale to avoid depending on Tailscale |
| **A full native client over an authenticated public API** | **Reject.** This is the "web-auth and session-security project" the Clinch map already declined, plus a second complete UI to maintain forever |
| **A narrow companion — notifications, approvals, Activity, BusterPhone** | **The only one worth scoping.** It does what the web UI *cannot*: push notifications, an approve/deny surface for agent actions, share-sheet capture into Notes, and a natural home for the call and SMS surface the money leg is building |

The narrow companion is also the only shape where invariant 2 is comfortable
rather than strained — it never needs to look like a shell, so it is never
tempted to act like one.

**Not scoped further here.** It should not start until Phases 0–3 answer whether
a phone is a place people actually want this, and it inherits an unresolved
question of its own: what an App Store reviewer makes of an app that is inert
without a Mac on the same tailnet.

---

## Rejected, and why

| Alternative | Decision |
|---|---|
| Recommend an SSH client's background hack as the supported path | **Reject as *the* path.** Fine as a documented option with its costs named (F2); not something we build a product promise on |
| mosh for the UI | **Impossible**, not merely unwise — no port forwarding (F3) |
| Tailscale Funnel | **Reject.** Public exposure, and it strips the identity headers that made Serve attractive |
| Router port-forwarding / dynamic DNS | **Reject**, unchanged from the Clinch map |
| Tauri's iOS target for a native app | **Reject.** Tauri v2 builds for iOS, but our shell is PTY, Keychain, `WKUIDelegate` and native-webview code that shares almost nothing with it. It would be a new app wearing a familiar name |
| Averaging iPhone and iPad behaviour into one claim | **Reject.** Split-screen changes F1 materially; measure them separately |

---

## Exit criteria for the map as a whole

- The Phase 0 table is filled from a real device, and the chosen transport
  survives a screen lock and a five-minute app switch.
- Phoenix still binds only to loopback, proven by the existing gate.
- A phone cannot reach `/api/clinch`, and the Clinch panels render their
  unavailable notice — both already guarded, and both must still pass over the
  new transport rather than only over `-L`.
- Funnel is off and something other than a human checks that.
- The five phone-relevant surfaces are usable at 390pt.

---

## Open questions only a device can answer

1. Does a LiveView WebSocket survive an iOS screen lock over Serve, or does the
   VPN persist while Safari's socket does not? **The Network Extension staying
   alive does not entail the browser's connection staying alive**, and this is
   the single assumption most likely to be wrong.
2. Does Serve proxy WebSockets without additional configuration?
3. How long does an idle tunnel survive on cellular before NAT rebinding kills
   it, and does LiveView's reconnect cover it?
4. iPhone versus iPad: how much of the difference is split-screen, and does that
   change the recommendation?

---

## Research sources

- [Tailscale Serve](https://tailscale.com/docs/features/tailscale-serve) —
  loopback proxying, identity headers, the localhost-binding recommendation
- [Tailscale Funnel](https://tailscale.com/docs/features/tailscale-funnel) —
  public exposure, and why it and Serve cannot share a port
- [`tailscale serve` reference](https://tailscale.com/docs/reference/tailscale-cli/serve)
- [Blink Shell — advanced SSH, tunnels and `geo track`](https://docs.blink.sh/advanced/advanced-ssh)
- [Termius — port forwarding and tunneling](https://docs.termius.com/organize-and-connect-to-hosts/port-forwarding-and-tunneling)
- Carried from [`CLINCH`](CLINCH_ROADMAP.md): OpenSSH forwarding and
  authorized-key restrictions, Tailscale SSH, SSH-over-Tailscale
