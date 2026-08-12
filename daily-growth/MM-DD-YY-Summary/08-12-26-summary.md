# 08-12-26 — Phase 5 starts by proving what must already be true

**Clinch Phase 5 is remote access: reaching your own Mac over SSH.** Its first
instruction is *prove the tunnel first, no settings UI until it works* — and that
needs a person, two machines, and a laptop that goes to sleep. So today's work was
the part that can be done before a tunnel exists, and it is not filler: it is the
set of properties that make a tunnel safe to build at all.

| Shipped | Commit |
|---|---|
| Phase 5's preconditions, pinned as regression tests | `18af12e` |

## The sentence the whole phase turns on

The SSH roadmap was honest about its own footing:

> Browser pages have no account-login gate because loopback plus the desktop shell
> is currently the gate. Anyone who can reach the loopback listener can operate
> the UI.

That is fine while "loopback" means *sitting at the Mac*. **The moment a tunnel
exists it reads: anyone who reaches the tunnel operates the UI** — and what the UI
can reach becomes the security boundary rather than an implementation detail.

Three properties follow, all lifted from Phase 5's own exit criteria, all now
tests.

## No LiveView may reach the command surface

The sharpest of the three, and the least obvious.

`Commands.call/3` defaults to `caller: :trusted`. A LiveView carries **no API
token** — it has a session, and the tier system does not read sessions. So a
command call from a LiveView runs as **fully trusted**, and a remote browser
driving that LiveView inherits it.

**The tiers only mean anything while the command surface is reached with a token.**
Today exactly one file calls it — `ApiController`, which has authenticated a caller
to pass — and that is now enforced rather than true by luck.

The test carries a positive control asserting the scan still *sees* that one
allowed call, because a stripper bug would otherwise read as a clean codebase. That
vacuously-green shape has bitten this repo repeatedly.

## The thing that needed a guard rather than a fix

`check_origin` in production is `["//127.0.0.1", "//localhost"]`, and **it already
works for tunneling**: a tunneled client binds locally, so its `Origin` is one of
those two, and Phoenix's `//host` form ignores the port. Nothing to change.

Which is exactly why it needed a guard. The risk was never that it is wrong — it is
that someone sets it `false` at 2am when a tunneled WebSocket refuses to upgrade.
The roadmap capitalises the warning; now the suite enforces it, and refuses `true`
as well, which derives the origin from the endpoint's `:url` host that a tunneled
client never sends.

**A correct value with no guard is one commit from being an incorrect value.**

## What was deliberately not built

No gateway, no Settings → Remote Access panel, no tunnel command generator. The
roadmap forbids them until a real tunnel survives a WebSocket upgrade, a file
upload, a long Chat response and a laptop sleep — and the moving-port decision (a
stable loopback gateway versus a fixed Phoenix port) is explicitly held as a
**spike decision**: *"if the proxy adds fragility, take the stable Phoenix port
instead."*

Building the gateway now would mean choosing between those on reasoning alone,
which is the thing that sentence exists to prevent. **The spike is the operator's
to run**, and it answers two questions nothing here can: whether the moving port is
a problem in practice, and whether `check_origin` holds against real tunneled
headers rather than my model of them.

## Why yesterday's terminal token mattered more than it looked

Phase 5's capability matrix contains one line the entire Clinch was built for:

| | |
|---|---|
| **Clinch — use** | Works. Agent runs, polls and sends all resolve credentials |
| **Clinch — manage** | **Unavailable.** No `__TAURI__`, and no API token |

That second row was **false until yesterday**. An SSH session gives you a shell,
the in-app terminal had the full token, and so "manage is unavailable" would have
shipped as a claim the product did not keep. Finding #7 read like tidiness —
*"the PTY gets a terminal-tier token"* — and was actually the difference between
that row being true and being a lie.
