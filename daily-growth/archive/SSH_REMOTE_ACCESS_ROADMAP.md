# Remote Buster Claw over SSH

**Scoped 08-08-26 · Status: SUPERSEDED + ARCHIVED 08-08-26, never started.**

> **Read `daily-growth/roadmaps/CLINCH_ROADMAP.md` instead.** This map was
> absorbed whole on the day it was scoped, because reading it against the
> credential findings made one thing obvious: its own foundation — *"anyone who
> can reach the loopback listener can operate the UI"* — is a statement that a
> tunnel turns into *"anyone holding the SSH key holds every credential in the
> app."* Remote access could not ship ahead of a credential authorization model,
> so the two became one project rather than two documents with a dependency
> between them.
>
> Nothing here was lost. Phases 0–1 became **Clinch Phase 5**, phase 2 became
> **Phase 6**, phase 3 became **Phase 7**, and phases 4–5 are carried as
> explicitly deferred with their reasons intact. The OTP 28 trap, the
> moving-port decision table, the rejected-alternatives table, the capability
> matrix and every research source travelled with them. This file is kept only
> as the record of the research as it originally stood.

This map answers one product question: **how can the operator safely reach the
Buster Claw running on their own Mac while they are away from it?**

The recommendation is deliberately narrow:

> Keep Phoenix on loopback. Use SSH as the authenticated, encrypted path to it.
> Do not expose Phoenix directly, and do not expose an Erlang or IEx shell.

The first useful product is a tunnel into the existing LiveView, backed by the
Mac's OpenSSH server and optionally reachable only over a private network such
as Tailscale. Erlang/OTP's built-in `:ssh` is capable enough to support later
Buster Claw-native commands, but it is not the safe first listener for this app.

---

## What the remote user gets

From another laptop, a user should be able to:

1. establish one SSH connection to the Mac running Buster Claw;
2. open a local browser address such as `http://127.0.0.1:44115`;
3. use the server-backed parts of Home: Chat, Calendar, Activity, Notes, Phone,
   Studio library, Explore, settings, notifications, and the audit feed;
4. close the SSH connection and leave no public Buster Claw listener behind.

SSH also gives power users a second, already-understood surface: a normal remote
shell from which they can run the `buster-claw` CLI. That is useful, but it is a
property of their Mac account—not a reason for Buster Claw to mint a second
general-purpose shell inside the BEAM.

### What a remote browser cannot pretend to be

Buster Claw is a Phoenix app *and* a Tauri desktop shell. A tunneled browser has
LiveView but no `window.__TAURI__`, so the roadmap must ship an honest capability
matrix rather than a window that looks complete and fails on click.

| Surface | Remote-browser posture |
|---|---|
| Home Chat, Activity, Notes, Calendar | Works through Phoenix/LiveView |
| Workspace browsing and normal HTML upload | Works; native Finder path-drop does not |
| Security, Settings, Integrations, Notify | Works where the feature is server-backed |
| Terminal | Unavailable in the browser; use the SSH session itself |
| Embedded Browser | Unavailable; its visible webviews and commands are Tauri-owned |
| Native speech, screenshot bridge, app-window controls | Unavailable |

Every unavailable surface gets an explicit remote-mode notice and a useful next
step. No empty xterm, invisible native browser, or dead Voice toggle ships.

---

## The system as it exists today

- Production Phoenix binds only to `127.0.0.1`; this is a core local-trust
  boundary, not an inconvenience to remove.
- The packaged Tauri shell chooses a free private port at each launch with
  `portpicker`; development uses `4000`.
- `BUSTER_CLAW_URL` and the trusted API token are injected into the Tauri child
  and its in-app terminal. A normal macOS SSH login does not inherit them.
- Browser pages have no account-login gate because loopback plus the desktop
  shell is currently the gate. Anyone who can reach the loopback listener can
  operate the UI.
- The project pins Erlang/OTP **28.4.2** and Elixir **1.19.5-otp-28**.
- `mix.exs` does not start `:ssh` as an extra application and there is no SSH
  listener, host-key store, paired-key model, or remote-access settings page.

These facts make “bind Phoenix to `0.0.0.0`” the wrong shortcut. It would erase
the trust boundary before replacing it with identity, revocation, rate limits,
or an accurate remote-mode UI.

---

## Research findings: what Elixir/OTP already provides

Elixir can call Erlang's built-in `:ssh` application directly; a wrapper is not
required for the protocol itself.

| Capability | OTP support | Buster Claw implication |
|---|---|---|
| SSH client | `:ssh.connect`, channels, exec, shell, SFTP | Later outbound host automation is possible, but is a separate trust project |
| SSH daemon | `:ssh.daemon/2,3` | A supervised Buster Claw-native listener is technically possible |
| Authentication | OpenSSH files by default; custom `:ssh_server_key_api` callback | Paired device keys can live behind an app-owned callback |
| Custom command execution | daemon `exec: {:direct, fun}` and custom CLI/subsystems | A restricted `ssh host bc status` surface can delegate to the command catalog |
| TCP forwarding | daemon tunnel options and client tunnel functions | Can carry LiveView, but OTP 28's server-side outgoing-forward option is only a boolean—not a destination allowlist |
| SFTP | `:ssh_sftpd` with a configured root and resource limits | Useful for Markdown later, but not safe to enable casually |
| Hardening | session/channel caps, login serialization, timeouts, callbacks, algorithm controls | All must be explicit and tested if an embedded daemon is ever enabled |

### The OTP 28 trap is release-blocking

OTP 29 changed shell, exec, and SFTP to disabled by default. **Buster Claw is on
OTP 28**, whose documented behavior is different: omitting shell/exec options can
open the Erlang evaluator, and omitting `subsystems` enables SFTP. Therefore any
embedded-daemon spike must explicitly set all of these, even if a future OTP
upgrade makes the defaults safer:

```elixir
[
  shell: :disabled,
  exec: :disabled,
  ssh_cli: :no_cli,
  subsystems: [],
  tcpip_tunnel_in: false,
  tcpip_tunnel_out: false
]
```

The embedded-daemon phase must add a test for that complete deny-by-default
option set. A refactor that drops one option must fail before it can expose a
service.

### Authentication is not OS authorization

OTP SSH authenticates a username/key, but it does not switch the BEAM process to
that Unix user. A shell, SFTP handler, or subsystem runs with the rights of the
OS process running Buster Claw. For this app that includes the workspace,
database, and whatever the desktop process can reach.

That is the decisive reason not to enable the built-in Erlang shell, a general
OS shell, raw SFTP, or unrestricted TCP forwarding. Each would turn “paired key”
into authority much broader than the product UI communicates.

### Library landscape

- `SSHKit` is a convenient *client* DSL over OTP SSH for running commands and
  SCP. Its current Hex release is old and it does not solve Buster Claw's inbound
  remote-access problem, so it should not be added for this roadmap.
- `NervesSSH` is current and useful precedent for supervised key management and
  daemon configuration, but its default purpose is remote IEx/exec on embedded
  devices. Buster Claw should learn from its lifecycle and tests, not import an
  IEx-oriented policy into a desktop app.

No new Hex dependency is needed for the first release.

---

## Architecture decision

### R1: OpenSSH tunnel to the existing loopback UI

```text
remote browser
  127.0.0.1:44115
        |
        | local forward (-L), encrypted inside SSH
        v
operator's Mac / OpenSSH
  127.0.0.1:<BusterClaw runtime port>
        |
        v
Phoenix LiveView + WebSocket
```

OpenSSH local forwarding is exactly this primitive: a listener on the remote
user's machine forwards through the encrypted connection to a host/port reached
from the Mac. `-N` requests forwarding without running a remote command.

Illustrative development command:

```bash
ssh -N \
  -L 127.0.0.1:44115:127.0.0.1:4000 \
  operator@buster-claw-host
```

The local bind is explicitly `127.0.0.1`; the user's laptop must not re-export
the tunnel on Wi-Fi.

### Network reachability: private network first

The product documentation recommends one of:

1. **Tailscale plus normal OpenSSH** — private addressing and tailnet ACLs limit
   who can even reach port 22, while standard SSH keys remain the login gate.
2. **Tailscale SSH** — useful for a single-user Mac if the operator wants
   Tailscale-managed identity and optional re-authentication/check mode.
3. **Existing private LAN/VPN plus OpenSSH** — valid for users who already own
   that network.

Direct router port-forwarding of SSH is not the guided path. It can be supported
as an expert-owned deployment, but Buster Claw should not automate public port
exposure or UPnP.

### Why not the alternatives

| Alternative | Decision |
|---|---|
| Bind Phoenix to LAN/public IP | Reject: bypasses the current loopback trust boundary |
| Cloudflare/public HTTP tunnel | Not this roadmap: creates a web-auth and session-security project, not SSH support |
| Embedded OTP Erlang/IEx shell | Reject permanently for product use |
| Embedded OTP SFTP | Defer: OS authority and symlink/root risks need a separate containment design |
| Embedded OTP unrestricted forwarding | Reject: it can make the Mac a network pivot |
| Buster Claw as outbound SSH client | Separate future map; keys, host verification, approvals, and command policy differ |

---

## The hard packaging problem: the private port moves

Development has a known port; the packaged app deliberately chooses a free port
at launch. A user away from home cannot copy a tunnel command from the desktop,
and a tightly restricted OpenSSH key cannot use `permitopen` against an unknown
future port.

Phase 0 must choose one of these—not bury the issue in setup copy:

| Option | Strength | Cost / risk |
|---|---|---|
| Stable packaged Phoenix port when Remote Access is enabled | Simple tunnel and `permitopen` | Collision handling and launch UX |
| Stable loopback TCP proxy to the current private port | Preserves dynamic Phoenix port | New supervised bidirectional proxy; WebSocket and back-pressure tests required |
| Runtime port locator + two-step tunnel command | Smallest code change | Full SSH account is required; restricted forwarding key is difficult |

**Proposed choice:** a stable, opt-in loopback gateway owned by the Elixir
supervision tree. It proxies only to `RuntimeConfig.local_port`, starts only when
Remote Access is enabled, and fails closed with a visible port-conflict error.
This keeps the primary Phoenix listener private/dynamic while giving OpenSSH one
stable `permitopen="127.0.0.1:<gateway-port>"` destination.

This remains a spike decision until a real LiveView WebSocket survives a proxy
restart, large upload, and reconnect test. If the proxy adds fragility, prefer a
stable Phoenix port while remote mode is enabled.

---

## Phase 0 — Prove the tunnel and define the boundary

No settings UI before this passes.

- Tunnel the dev server through normal macOS OpenSSH.
- Verify initial HTML, LiveView WebSocket upgrade, navigation, file upload, a
  long-running Chat response, reconnect after laptop sleep, and logout/close.
- Build the remote capability matrix by visiting every dock and Home tab in a
  plain browser with no Tauri object.
- Verify `check_origin` with the actual tunneled Host/Origin values in production
  configuration; do not loosen it to `false` in production.
- Decide and prototype the stable loopback gateway versus stable Phoenix port.
- Threat-model the SSH account: full Unix account, forwarding-only key, and
  Tailscale SSH each communicate different authority.

**Exit:** one written test protocol plus a demonstrated packaged-app tunnel. No
listener binds beyond loopback and no Tauri-only control fails silently.

---

## Phase 1 — Remote mode is explicit and observable

Add a **Settings → Remote Access** panel. It does not turn on macOS Remote Login
behind the user's back.

The panel shows:

- Remote Access on/off for Buster Claw's stable loopback gateway;
- gateway health and selected port;
- whether `sshd` appears reachable locally, labelled as a diagnostic rather
  than proof that the network is configured;
- the exact tunnel command with local bind, remote host placeholder, keepalive,
  and `ExitOnForwardFailure=yes`;
- the remote capability matrix and the instruction to leave the Mac awake;
- a one-click “Copy command,” not a shell command run without consent.

Remote mode also becomes a server-known assign or root data attribute. Tauri-only
hooks already detect missing `window.__TAURI__`; now the templates render the
right explanatory state before a hook fails.

**Files likely involved:** a focused `BusterClaw.RemoteAccess` context and
supervised gateway; Settings tab module; `RuntimeConfig`; root/layout capability
marker; plain-browser tests for Browser, Terminal, Voice, and Workspace drop.

**Acceptance:** enable/disable is reversible; restart preserves the preference;
port conflict fails closed; the copied command tunnels a packaged build.

---

## Phase 2 — Pair a forwarding-only device

The safe product experience is a key that can reach Buster Claw's one loopback
gateway without getting a shell.

OpenSSH supports per-key restrictions including `restrict`, `port-forwarding`,
and `permitopen="host:port"`. The implementation should generate a proposed
`authorized_keys` line and explain it before installation. Whether Buster Claw
writes that line itself is a separate, explicit confirmation because it mutates
the user's SSH login configuration.

Required pairing model:

- accept only a public key; Buster Claw never generates or receives the remote
  device's private key;
- display SHA-256 fingerprint, device label, added time, last-seen information
  where OpenSSH logs make that reliable, and a Revoke action;
- install a uniquely marked line so removal never touches unrelated keys;
- restrict forwarding to the fixed Buster Claw gateway, with no PTY, agent, X11,
  user rc, or arbitrary command;
- refuse duplicate keys and malformed/legacy key types;
- make installation/removal auditable in Sentinel with key fingerprints only.

If macOS/OpenSSH cannot express the exact forwarding-only policy consistently on
supported OS versions, stop at guided setup. Do not compensate by granting a
shell silently.

**Acceptance:** the paired key can open the UI tunnel and cannot obtain a PTY,
run `id`, forward to another port, use agent/X11 forwarding, or reconnect after
revocation.

---

## Phase 3 — Private-network onboarding and away-from-home reliability

- Add a Tailscale-aware guide, but keep it optional and vendor-neutral.
- Detect presence/version read-only; never enroll a tailnet or edit ACLs without
  the operator leaving Buster Claw for the provider's authenticated flow.
- Document normal OpenSSH-over-Tailscale and Tailscale SSH as distinct choices.
- Recommend check/re-authentication mode for high-risk access where supported.
- Add Wake/sleep truth: Buster Claw cannot be reached if the Mac or app is off.
  Reuse the existing shift-scoped uptime posture only after the user explicitly
  chooses an always-available remote mode.
- Add connection status, last successful remote LiveView heartbeat, and a
  “Disconnect remote sessions” control that stops the gateway and existing proxy
  connections.

**Acceptance:** switching Wi-Fi/cellular and laptop sleep causes a recoverable
LiveView reconnect; disabling remote mode tears down the stable gateway.

---

## Phase 4 — Optional Buster Claw-native SSH exec (not a shell)

Only pursue this if users need `ssh bc-host bc status` without a Unix account.

An OTP daemon would expose one custom `exec: {:direct, fun}` parser that accepts
an allowlisted Buster Claw command grammar and delegates into
`BusterClaw.Commands` under an explicit remote caller tier. It would not invoke
`sh -c`, `System.cmd` from raw input, Erlang eval, IEx, or a terminal.

Non-negotiable controls:

- public-key only through an app-owned `:ssh_server_key_api` callback;
- bind only to an explicit tailnet/LAN address selected by the operator;
- the complete OTP-28 deny list for shell, CLI, subsystems, and both tunnels;
- `max_sessions`, `max_channels`, hello/auth/initial-idle/idle timeouts;
- serialized login or tightly capped parallel login;
- `connectfun`, `failfun`, and disconnect auditing with redacted peer data;
- a dedicated `remote` command-policy tier—never reuse the trusted local API
  token merely because the key authenticated;
- property tests for parser rejection and integration tests with a real OpenSSH
  client.

**Exit:** a remote key can perform only the catalogued safe operations assigned
to it. A test proves arbitrary Erlang, shell, SFTP, forwarding, and unknown
commands are refused.

---

## Phase 5 — Markdown transfer, only if Notes needs it

Do not enable OTP's stock SFTP server against the whole workspace. Its root is
per daemon rather than per user, it operates with the BEAM OS user's rights, and
the OTP hardening guide warns that existing symlinks can lead outside an SFTP
root unless OS permissions/isolation also hold.

If remote Markdown transfer becomes important, choose one:

1. normal OpenSSH SFTP under the user's already-understood Unix permissions;
2. a Buster Claw custom subsystem backed by `FileManager` containment and a
   Notes-only virtual root;
3. Notes commands/API over the existing authenticated tunnel.

The third is the likely product fit. It keeps note conflict detection, atomic
writes, audit, and authorization in one path instead of introducing a second
writer with different semantics.

---

## Security and test gate

Before any remote feature can be called done:

- Phoenix still binds only to loopback.
- The remote gateway also binds only to loopback.
- A non-SSH host cannot reach either listener from LAN/Wi-Fi.
- The client-side forwarded port binds only to the remote device's loopback.
- Public-key authentication is the default; passwords are not stored by Buster
  Claw.
- Host-key verification is documented and never silently disabled.
- Pair/revoke/enable/disable/connect/fail events reach Sentinel without key body,
  API token, or private network secrets.
- Remote browser routes cannot reach Tauri IPC because there is no Tauri object,
  and their fallback states are covered by JS and LiveView tests.
- The full `mix precommit` gate passes; packaged smoke includes a real SSH tunnel
  because endpoint tests cannot prove WebSocket forwarding.

---

## Research sources

- [Erlang/OTP 28 SSH reference](https://www.erlang.org/docs/28/apps/ssh/ssh.html)
- [Erlang/OTP SSH terminology: authentication vs OS authority](https://www.erlang.org/doc/apps/ssh/terminology.html)
- [Erlang/OTP SSH hardening guide](https://www.erlang.org/doc/apps/ssh/hardening.html)
- [OTP 29 SSH release notes: secure-default changes and SFTP fixes](https://www.erlang.org/doc/apps/ssh/notes.html)
- [OpenSSH client manual: local and remote forwarding](https://man.openbsd.org/ssh.1)
- [OpenSSH authorized-key restrictions](https://man.openbsd.org/OpenBSD-current/man8/sshd.8)
- [Tailscale SSH](https://tailscale.com/docs/features/tailscale-ssh)
- [Protect normal SSH with Tailscale](https://tailscale.com/docs/reference/ssh-over-tailscale)
- [SSHKit on Hex](https://hex.pm/packages/sshkit)
- [NervesSSH on Hex](https://hex.pm/packages/nerves_ssh)
