# The Clinch — one place for credentials, reachable from anywhere

**Scoped 08-08-26 · Status: SCOPED, not started.**

**Supersedes `SSH_REMOTE_ACCESS_ROADMAP.md`** (researched 08-08, archived the
same day without ever starting). Its research is carried forward here in full —
the OTP 28 trap, the moving-port problem, the rejected alternatives, the sources.
Nothing was lost; it became phases 5–7 of this document.

---

## Why these were ever one project

The SSH roadmap was honest about the ground it stood on:

> Browser pages have no account-login gate because loopback plus the desktop
> shell is currently the gate. Anyone who can reach the loopback listener can
> operate the UI.

That sentence is fine while "loopback" means "sitting at the Mac." The moment a
tunnel exists it reads: **anyone holding the SSH key holds every credential in
the app.** And a key lives on a laptop, which is the thing that gets stolen.

Today that is survivable only because the credential surface is thin enough that
there is little to steal through the UI. Build a real vault with a real screen
and the tunnel becomes the way it gets emptied. So the Clinch is not a feature
remote access would be nice to have — it is the precondition for shipping remote
access at all.

The merge runs the other way too. A credential store with no remote story is a
credential store whose authorization model is never tested: everything is
"local," so "local" means nothing. Remote access is what makes the Clinch's tiers
load-bearing instead of decorative.

**The Clinch does not need SSH to ship.** Phases 0–4 are worth doing on their own
and unblock BusterPhone. Remote inherits them.

---

## What the Clinch is

One store, one screen, one name. Every credential the app holds — service API
keys, OAuth tokens, integration secrets, `$secret` sign-in values, the loopback
token family, and eventually paired device keys — lives behind one module that
every read and write passes through.

A clinch is how you hold something so close nothing can swing at it. That is the
whole design goal, and it is worth being precise about what "close" can actually
mean, because in-VM isolation is not real. A GenServer holding plaintext does not
stop anything else in the same BEAM from reaching `Repo` or `Vault` directly.
The Clinch is a **chokepoint**, not a sandbox: one door, so audit, policy and
redaction are unavoidable rather than remembered.

The real walls come from facing three different adversaries and giving each the
kind of wall that actually holds against it.

| Adversary | The wall that holds | Status today |
|---|---|---|
| **The agent** — prompt-injectable, runs in-VM with real command authority | No command ever returns a value. A model emits a reference; resolution happens in the executor at the moment of use. | Proven by `Egress.SecretRef` + `Secrets.resolver/0`. But the **write** path leaks — see Phase 0. |
| **The remote operator** — holds an SSH key, may be a stolen laptop | Management is unreachable, not merely denied: it requires the full loopback API token, which lives only in the Keychain and the shell process env. | Does not exist. |
| **Someone with the disk** — a backup, a stolen Mac, a copied `.db` | AES-256-GCM at rest via `Vault`, keyed from `secret_key_base`, which lives in the Keychain and never on disk. | Mostly true. Two holes, both in Phase 0. |

Three adversaries, three walls. A design that answers only one of them is not a
vault, it is a table with a nice name.

---

## The boundary: **use** is not **manage**

This is the decision the whole document hangs on, taken 08-08.

Credentials have two verbs, and they deserve different authority:

| Verb | Examples | Local (Tauri) | Remote (tunnel) |
|---|---|---|---|
| **Use** | agent fills a login form, an integration polls, Twilio sends, Google refreshes a token | yes | **yes** |
| **Manage** | add, replace, reveal, export, delete | yes | **no** |

Remote should *work*. You are away from home; Chat, Notes, Calendar, agent runs
and integrations should all function, and all of them consume credentials. What
a remote session must never do is change which credentials exist or read one
back. A stolen key then buys a working Buster Claw — not the operator's Twilio
account, and not the ability to repoint it at an attacker's.

### Why the desktop shell is load-bearing and not decorative

The management path deliberately does **not** go through LiveView:

```text
LOCAL (Tauri webview)
  a plain <input> — no phx-change, no phx-submit, no LiveView assign
        |
        | a JS hook reads the value from the DOM node it owns
        v
  window.__TAURI__.core.invoke("clinch_put", {kind, name, value})
        |
        v
  Rust — the only browser-reachable holder of BUSTER_CLAW_API_TOKEN
        |   (Keychain-sourced, injected into the shell process env at launch)
        |
        | POST 127.0.0.1:<port>/api/clinch   Authorization: Bearer <api_token>
        v
  BEAM — Clinch.put/3 → Vault-encrypted row
        |
        v
  LiveView re-renders NAMES ONLY, over the clinch PubSub topic
```

The value never enters a LiveView event, a LiveView diff, a `phx-change` payload,
or a Sentinel arg capture. That is a stronger property than "we remembered to use
`type="password"`," and it fixes an entire class of leak by construction rather
than by vigilance.

Over a tunnel, the same screen fails for **two independent reasons**:

1. A plain browser has no `window.__TAURI__` — the runtime injects it into Tauri
   webviews; it is not something the loopback origin serves. So the hook finds no
   `invoke` and renders "manage this at the Mac." *This is the honest UX
   boundary.*
2. Even a hand-rolled `fetch` to `/api/clinch` from that browser gets a 401: it
   has no API token, and the token is not reachable from a forwarding-only SSH
   key (no shell → no Keychain). *This is the enforcement.*

Neither alone. The first is an absence a refactor could accidentally paper over;
the second is a credential check that holds regardless. Phase 5 must prove both.

### One existing property this depends on

**LiveViews do not call `BusterClaw.Commands.call/3`.** Only
`BusterClawWeb.ApiController` does, behind `Plugs.ApiAuth`. That is why a browser
— local or remote — cannot invoke `browser_secret_put` to route around the gate.
It is currently true by habit rather than by test. Phase 5 makes it a test,
because remote access is what turns a habit into a vulnerability.

---

## Invariants — the things that must never become true

Every phase below is checked against these. A change that violates one is wrong
even if it passes.

1. **No command, API route, or LiveView assign ever returns a credential value.**
   `names/0`-shaped listings only: name, kind, note, last-used, never the secret.
   The one exception is the recovery key, which Phase 2 moves *out* of the BEAM
   entirely.
2. **Phoenix binds only to loopback**, in every phase, including the remote ones.
3. **No plaintext credential on disk**, ever — not in the data dir, not in the
   `security_events` table, not in a log line.
4. **The three-place Tauri ACL lockstep holds** (`main.rs` `generate_handler!`,
   `build.rs` `AppManifest::commands`, a `capabilities/*.json` allow entry).
   `tests/acl_lockstep.rs` already enforces this and will catch new commands for
   free — it is the reason the co-presence bug (07-17) and the unregistered
   `speak`/`stop_speaking` (07-21) cannot recur silently.
5. **A rotated key never silently unconfigures anything.** `Encrypted` fails
   closed by design; that is correct, but it must surface as a visible,
   actionable state, not as an integration that quietly reads as absent.

---

## Where credentials live today — five stores, five patterns

| Store | Contents | Mechanism |
|---|---|---|
| macOS Keychain | `secret_key_base`, `api_token`, `mcp_token` | `main.rs:532-539`, injected as env at BEAM spawn |
| Plaintext file | `agent_token` | `api_token.ex:85-102`, mode 0600 |
| SQLite via `Vault` | integration tokens + webhook secrets, `$secret` store | `Encrypted` Ecto type |
| SQLite via `Google.Vault` | Google client secret / refresh / access tokens | hand-rolled `*_enc :binary` fields, second AAD and key derivation |
| Environment variables | Twilio, Supabase service-role, Finnhub, bundled Google client | `runtime.exs:98-139`, read once at boot, **no UI** |

The cryptography is sound: AES-256-GCM, per-value IV, AAD-bound, and `Encrypted`
fails closed rather than handing back ciphertext (`encrypted.ex:56-66`). Google's
path fails closed correctly too, through `with` tuples. **Every problem below is
management, not crypto.**

### The findings this roadmap closes

| # | Finding | Phase |
|---|---|---|
| 1 | **Env-var credentials are unreachable in a packaged build.** A double-clicked `.app` inherits launchd's environment, not a shell's; the shell forwards only eight vars (`main.rs:65-72`). Twilio/Supabase/Finnhub therefore cannot be configured by any user of a shipped build — and `phone_component.ex:178` tells them to "set TWILIO_ACCOUNT_SID," an instruction with nowhere to be carried out. | 3 |
| 2 | **`browser_secret_put` writes the plaintext secret into the audit log.** It is `:mutate`, so `audit_invoke` captures its args (`commands.ex:294-308`). `scrub_audit_args` covers `browser_flow` steps and note bodies, not this (`commands.ex:318-328`). The arg key is `"value"`, which `@sensitive_fragments` does not match (`sentinel.ex:43`), and the value-shape masks only catch prefixed tokens, 40+ char alnum runs and Luhn cards — an ordinary site password matches none. `secret.ex` promises the value "never appears in a dump of the database"; true of `browser_secrets`, false of `security_events`. | 0 |
| 3 | **No GUI for the `$secret` store.** The only writer is `commands/web.ex:708`, so the operator's only way to store a password is to type it to a model or into a terminal — where the model reads it going in, the transcript keeps it, and shell history keeps it. Defeats the stated design in `secrets.ex:26-34`. | 2 |
| 4 | **`agent_token` is the one loopback token with no Keychain path.** The shell provisions three secrets; `runtime.exs:199` reads `BUSTER_CLAW_AGENT_API_TOKEN`, which nothing sets. So `ApiToken.agent_value/0` writes cleartext to the data dir — and it is the token authorizing untrusted-provenance agent runs. | 0 |
| 5 | **Integration tokens round-trip to the browser in cleartext on edit.** `integrations_live.ex:75` builds the changeset from the loaded (decrypted) struct; `normalize_value/2` has no password case, so `core_components.ex:292` renders `value="ghp_…"` into the DOM and the LiveView diff. Loopback-only today — but this is exactly the class of leak a tunnel promotes. | 2 |
| 6 | **Two vaults doing one job, and no rotation story.** `Vault` and `Google.Vault` differ only in AAD and key prefix; `Google.Account` hand-rolls what `Encrypted` already does. Everything derives from `secret_key_base`, `Recovery` is read-only, and there is no re-key path. | 4 |
| 7 | **The in-app terminal gets the full-access token.** `main.rs:575` puts `BUSTER_CLAW_API_TOKEN` into the shell process env and `terminal.rs:95` forwards it to every PTY. Deliberate and documented — but the scoped `mcp`/`agent` tokens exist for exactly this shape of problem, and the terminal gets the unscoped one. | 4 |

---

## Phase 0 — Stop the bleeding

Two live leaks. Neither needs a design, neither depends on anything else here,
and both should land before the Clinch has a name in code.

- **Scrub `browser_secret_put`.** Add a `scrub_audit_args/2` clause reducing
  `"value"` to a byte count, the way note bodies already are. Prefer the
  narrow, command-specific clause over widening `@sensitive_fragments` to
  `"value"` — that fragment is generic enough to over-redact real audit data
  across the whole catalog.
- **Give `agent_token` the Keychain.** `ensure_secret(&data_dir, "agent_token",
  &["agent_token"], 43)` alongside its two siblings, forwarded as
  `BUSTER_CLAW_AGENT_API_TOKEN`, which `runtime.exs:199` already reads. The
  legacy-file migration adopts and deletes any existing cleartext file, exactly
  as it does for the other two.

**Exit:** a test asserts the stored value never appears in `security_events` for
a password-shaped input (short, no credential prefix, not Luhn-valid) — the case
today's masks all miss. A test asserts all three loopback tokens resolve from
env in a release, and that no token file is created when they do.

---

## Phase 1 — The Clinch contract — **DONE 08-08**

A types-only module first, then the context. This follows the standing lesson
from Scene3D: pin the stage boundaries as a real module before any work fans out.

**Shipped:** `Clinch.Types` (kinds, ref grammar, entry shape, no logic),
`Clinch.Vault` (the crypto chokepoint over both vaults), `Clinch.Secret` (the
schema, moved out of `BrowserControl` so the Clinch owns its own storage), and
`Clinch` itself — `resolve/2` + `resolver/2` as the audited use verb, `put/3` /
`delete/1` / `list/0` / `known?/1` as the manage verb. `BrowserControl.Secrets`
is now a thin adapter. `credential_use` is a new Sentinel category at `:info`.

**One thing deliberately not done, and why.** `Integrations` and `Google.Account`
do **not** call `resolve/2` per field. Their secrets are typed
`BusterClaw.Encrypted`, so decryption happens transparently at *Ecto load* —
there is no resolve moment to hook until those rows move, and manufacturing one
would mean un-typing the columns and rewriting every caller for no security gain
today. Their crypto does pass through `Clinch.Vault`, which is the property the
exit criterion actually names. Revisit in Phase 3, when `:service_key` gets a
writable home.

**Two guards worth knowing about.** `ChokepointTest` scans `lib/` (heredocs and
comments stripped) and fails if anything outside `Clinch.Vault` touches either
vault — verified by pointing `Encrypted` back at the raw vault and watching it
name the file. And a **wire-format** test asserts the `google_accounts` columns
are readable by the Google vault and *not* by the app vault: a round-trip test
cannot catch a refactor that drops `:google` from both sides, because
encrypt→decrypt would still agree while every column on a real user's disk became
unreadable. Verified the same way — every Google round-trip test stayed green
while that one failed.

- `BusterClaw.Clinch.Types` — the credential `kind` enum (`:service_key`,
  `:oauth`, `:sign_in`, `:loopback_token`, `:device_key`), the reference grammar,
  and the shape of a listing entry. No logic.
- `BusterClaw.Clinch` — the one door. Two public verbs, mirroring the boundary:
  - **use**: `resolve/1` and `resolver/0`, returning plaintext to an in-VM
    caller at the point of use. Never reachable from a command, a controller, or
    a LiveView.
  - **manage**: `put/3`, `delete/1`, `list/0`. `list/0` returns names and
    metadata only.
- Existing stores **route through** the Clinch rather than migrating into it.
  `BrowserControl.Secrets` becomes a thin adapter; `Integrations` and
  `Google.Account` resolve their secret fields through `Clinch.resolve/1` while
  keeping their own rows and schemas. Moving Google's account structure into a
  generic credential table is a lot of churn for no security gain — the
  chokepoint is the point, not the table.
- Every resolve emits a Sentinel `credential_use` event: kind, name, caller,
  never the value. This is new observability the app has never had.

**Exit:** a test proves no module outside `Clinch` reads `Vault`/`Google.Vault`
directly (a `mix xref`-shaped assertion in the spirit of the existing purity
guards). `mix precommit` green. Zero behavior change visible to a user.

---

## Phase 2 — The management gate

Three new Tauri commands, and the plaintext leaves the web layer.

- `clinch_put`, `clinch_delete`, `clinch_reveal_recovery_key`. Registered in all
  three lockstep places; `tests/acl_lockstep.rs` covers the drift for free.
- `POST /api/clinch` behind `Plugs.ApiAuth` at the **full** token tier — not
  `:mcp`, not `:agent_untrusted`. It is the only write path.
- A JS hook owning a plain input, invoking through Tauri, and rendering the
  no-`__TAURI__` fallback. Values never become LiveView events (**#5** dies by
  construction — and the `type="password"` round-trip in `integrations_live`
  goes with it when integrations move onto this path).
- **Recovery-key reveal leaves the BEAM entirely.** Today `settings_live.ex`
  assigns `@recovery_key` and renders it. Rust already owns the Keychain, so
  reveal becomes a direct read there, returned to a DOM node the hook owns. The
  master key stops being a server assign at all — which is what makes it safe to
  keep the feature once a tunnel exists.

**Acceptance:** a packaged build stores and deletes a credential from the UI. The
recovery key never appears in a LiveView payload. Removing any one of the three
ACL registrations fails `acl_lockstep` before packaging can hide it.

---

## Phase 3 — The Clinch screen, and evicting the env vars

The phase that unblocks the money leg.

- A **Settings → Clinch** panel: every credential by kind, with name, note,
  last-used, and where it came from. Add / replace / delete through Phase 2's
  gate. No value is ever displayed, including immediately after being typed.
- **Twilio, Supabase service-role and Finnhub move from `runtime.exs` to Clinch
  rows.** Env vars survive as a fallback for dev and CI, but stop being the only
  path. BusterPhone becomes configurable in a packaged build for the first time
  — and those keys become rotatable and revocable, which an env var never was.
- The subtlety that will bite: `Application.get_env` reads are resolved at boot.
  Clinch-backed credentials must be read **live** at use, and the key-gated
  children (the telephony `Drain`, per `application.ex:178`) must start and stop
  when a credential appears or disappears, without an app restart.
- `phone_component.ex:178` stops telling users to set an environment variable and
  starts linking to the panel.

**Acceptance:** a packaged build with an empty environment configures BusterPhone
end to end from the UI, the Drain starts without a restart, and deleting the
credential stops it.

---

## Phase 4 — Rotation, revocation, and the second vault

Cheap once the Clinch owns the values, and it must precede remote access: a
credential you cannot rotate is one you cannot respond to a compromise with.

- **Re-key.** Re-encrypt every stored value under a new `secret_key_base` in one
  transaction, with the old key still available. Today a key change silently
  loads every integration as `nil` (invariant 5) — the correct fail-closed
  behavior with no recovery path attached to it.
- **Retire `Google.Vault`.** Move Google's `*_enc` fields onto the `Encrypted`
  type and the single `Vault`, with a backfill migration. One vault, one AAD,
  one place to reason about. (**#6**)
- **Scope the terminal's token.** The PTY gets a terminal-tier token, not the
  full-access one. This is a behavior change for anything scripted against the
  in-app terminal and needs its own walk. (**#7**)
- Revocation is a first-class action with a Sentinel event, not a delete that
  looks like a typo in the audit feed.

**Acceptance:** rotating the recovery key preserves every integration, `$secret`,
and Google account. A revoked credential fails its next use loudly, with a
message naming what to do.

---

## Phase 5 — Remote mode is explicit and observable

*Absorbs SSH_REMOTE_ACCESS phases 0 and 1. No settings UI until the tunnel is
proven.*

### Prove the tunnel first

- Tunnel the dev server through normal macOS OpenSSH. Verify initial HTML, the
  LiveView WebSocket upgrade, navigation, file upload, a long Chat response,
  reconnect after laptop sleep, and clean teardown.
- Verify `check_origin` against the real tunneled Host/Origin values in
  production config. **Do not loosen it to `false`.**
- Build the remote capability matrix by visiting every dock and Home tab in a
  plain browser with no Tauri object.

| Surface | Remote-browser posture |
|---|---|
| Home Chat, Activity, Notes, Calendar | Works through Phoenix/LiveView |
| Workspace browsing, normal HTML upload | Works; native Finder path-drop does not |
| Security, Settings, Integrations, Notify | Works where the feature is server-backed |
| **Clinch — use** | Works. Agent runs, polls and sends all resolve credentials |
| **Clinch — manage** | **Unavailable.** No `__TAURI__`, and no API token |
| Terminal | Unavailable in the browser; use the SSH session |
| Embedded Browser | Unavailable; visible webviews and their commands are Tauri-owned |
| Native speech, screenshot bridge, window controls | Unavailable |

Every unavailable surface gets an explicit remote-mode notice and a useful next
step. No empty xterm, invisible native browser, or dead Voice toggle ships.

### The moving-port problem

Development has a known port; the packaged app picks a free one at launch with
`portpicker`. A user away from home cannot copy a tunnel command off the desktop,
and a restricted OpenSSH key cannot `permitopen` an unknown future port. This
must be decided, not buried in setup copy.

| Option | Strength | Cost / risk |
|---|---|---|
| Stable packaged Phoenix port while Remote Access is on | Simple tunnel and `permitopen` | Collision handling, launch UX |
| **Stable loopback gateway proxying to the private port** | Keeps Phoenix dynamic and private | A new supervised bidirectional proxy; WebSocket and back-pressure tests required |
| Runtime port locator + two-step tunnel command | Smallest code change | Needs a full SSH account; a restricted key becomes impractical |

**Proposed:** the stable, opt-in loopback gateway, owned by the Elixir
supervision tree, proxying only to `RuntimeConfig.local_port`, starting only when
Remote Access is enabled, failing closed with a visible port-conflict error. It
gives OpenSSH one stable `permitopen="127.0.0.1:<gateway-port>"` destination.

This stays a spike decision until a real LiveView WebSocket survives a proxy
restart, a large upload, and a reconnect. **If the proxy adds fragility, take the
stable Phoenix port instead.**

### The panel

Settings → Remote Access, which does not enable macOS Remote Login behind the
user's back. It shows: on/off for the gateway; gateway health and port; whether
`sshd` looks locally reachable (labelled a diagnostic, not proof the network is
configured); the exact tunnel command with local bind, keepalive and
`ExitOnForwardFailure=yes`; the capability matrix; the instruction to leave the
Mac awake; and a one-click **Copy command** — never a shell command run without
consent.

Remote mode becomes a server-known assign so templates render the right
explanatory state *before* a Tauri hook fails.

**Exit / acceptance:** enable/disable is reversible and survives restart; port
conflict fails closed; the copied command tunnels a packaged build. **And the two
Clinch proofs:** a tunneled browser has no `window.__TAURI__`, and a hand-rolled
`fetch` to `/api/clinch` from it returns 401. Plus a regression test that no
LiveView calls `Commands.call/3`.

---

## Phase 6 — Pair a forwarding-only device

*Absorbs SSH_REMOTE_ACCESS phase 2. Device keys become Clinch rows — same
lifecycle, same audit, same revoke, one implementation.*

OpenSSH supports per-key `restrict`, `port-forwarding` and
`permitopen="host:port"`. Buster Claw generates the proposed `authorized_keys`
line and explains it before installation. Whether it writes that line itself is a
separate explicit confirmation, because it mutates the user's SSH login config.

- Accept only a public key. Buster Claw never generates or receives a remote
  device's private key.
- Show SHA-256 fingerprint, device label, added time, last-seen where OpenSSH
  logs make it reliable, and Revoke.
- Install a uniquely marked line so removal never touches unrelated keys.
- Restrict forwarding to the one gateway: no PTY, agent, X11, user rc, or command.
- Refuse duplicates and malformed/legacy key types.
- Pair/revoke reach Sentinel with fingerprints only.

**If macOS/OpenSSH cannot express that policy consistently on supported OS
versions, stop at guided setup. Do not compensate by granting a shell silently.**

**Acceptance:** the paired key opens the UI tunnel and cannot obtain a PTY, run
`id`, forward to another port, use agent/X11 forwarding, or reconnect after
revocation. It also cannot reach `/api/clinch` — no shell means no Keychain means
no API token, which is the second wall from the boundary section, proven.

---

## Phase 7 — Private-network onboarding and away-from-home reliability

*Absorbs SSH_REMOTE_ACCESS phase 3.*

- A Tailscale-aware guide, kept optional and vendor-neutral. Detect
  presence/version read-only; never enroll a tailnet or edit ACLs without the
  operator leaving for the provider's own authenticated flow.
- Document OpenSSH-over-Tailscale and Tailscale SSH as distinct choices.
  Recommend check/re-authentication mode for high-risk access where supported.
- **Direct router port-forwarding is not the guided path.** Supportable as an
  expert-owned deployment; Buster Claw never automates public exposure or UPnP.
- Wake/sleep truth: Buster Claw is unreachable if the Mac or app is off. Reuse
  the shift-scoped uptime posture only after the operator explicitly chooses an
  always-available remote mode.
- Connection status, last successful remote LiveView heartbeat, and a
  **Disconnect remote sessions** control that stops the gateway and its proxied
  connections.

**Acceptance:** switching Wi-Fi/cellular and sleeping the laptop produce a
recoverable LiveView reconnect; disabling remote mode tears the gateway down.

---

## Deferred, with reasons intact

**Buster Claw-native SSH exec** (was SSH phase 4). Only worth pursuing if users
need `ssh bc-host bc status` without a Unix account. It would mean an OTP daemon
with one `exec: {:direct, fun}` parser over an allowlisted command grammar,
delegating into `BusterClaw.Commands` under a dedicated `remote` caller tier —
never `sh -c`, `System.cmd` on raw input, Erlang eval, IEx, or a terminal. The
Clinch supplies the tier that phase always asked for. Non-negotiables if it ever
starts: app-owned `:ssh_server_key_api` callback; bind only to an operator-chosen
tailnet/LAN address; the complete OTP-28 deny list; session/channel caps and
hello/auth/idle timeouts; serialized login; `connectfun`/`failfun`/disconnect
auditing with redacted peer data; property tests for parser rejection.

**Remote Markdown transfer** (was SSH phase 5). Do not enable OTP's stock SFTP
server against the workspace: its root is per daemon rather than per user, it
runs with the BEAM OS user's rights, and OTP's own hardening guide warns
existing symlinks can lead outside an SFTP root. If it becomes important, the
likely fit is **Notes commands over the authenticated tunnel** — it keeps
conflict detection, atomic writes, audit and authorization in one path instead of
introducing a second writer with different semantics.

### The OTP 28 trap, preserved

OTP 29 disabled shell, exec and SFTP by default. **This project pins OTP 28.4.2**,
where omitting shell/exec options can open the Erlang evaluator and omitting
`subsystems` enables SFTP. Any embedded-daemon spike must set all of it
explicitly, even after a future OTP upgrade makes the defaults safer:

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

with a test for the complete set, so a refactor that drops one option fails
before it can expose a service.

**Authentication is not OS authorization.** OTP SSH authenticates a
username/key; it does not switch the BEAM to that Unix user. A shell, SFTP
handler or subsystem runs with the rights of the process running Buster Claw —
the workspace, the database, the Clinch. That is the decisive reason the built-in
Erlang shell, a general OS shell, raw SFTP and unrestricted TCP forwarding are
all refused.

---

## Rejected, and why

| Alternative | Decision |
|---|---|
| Bind Phoenix to LAN/public IP | **Reject.** Erases the loopback trust boundary without replacing it with identity, revocation, rate limits, or an honest remote UI |
| Cloudflare / public HTTP tunnel | **Not this roadmap.** Creates a web-auth and session-security project, not SSH support |
| Embedded OTP Erlang/IEx shell | **Reject permanently** for product use |
| Embedded OTP SFTP | **Defer.** OS authority and symlink/root risk need their own containment design |
| Embedded OTP unrestricted forwarding | **Reject.** It can make the Mac a network pivot |
| Buster Claw as an outbound SSH client | **Separate future map.** Keys, host verification, approvals and command policy are all different |
| `SSHKit` | **Do not add.** A client DSL; the Hex release is old and it does not address inbound access |
| `NervesSSH` | **Learn from, do not import.** Good precedent for supervised key lifecycle, but its purpose is remote IEx on embedded devices |
| All-BEAM Clinch, remote gated by a policy check | **Rejected 08-08.** "Remote cannot manage" becomes one conditional, one refactor from being wrong, with no test that fails loudly |
| All-Tauri Clinch, plaintext never in the BEAM | **Rejected 08-08.** Strongest wall, but every credential *use* becomes an IPC round-trip and it pays the full ACL-lockstep tax on a much larger surface. The split gets the wall where the threat actually is |
| A second Keychain integration for `$secret` | **Still rejected** (the original call in `secrets.ex`). Values stay `Vault`-encrypted; the shell gates management, not storage |

No new Hex dependency is needed for any shipping phase.

---

## Security and test gate

Before any phase here is called done:

- Phoenix binds only to loopback. So does the remote gateway.
- A non-SSH host cannot reach either listener from LAN/Wi-Fi. The client-side
  forwarded port binds only to the remote device's loopback.
- No credential value appears in `security_events`, a log line, a LiveView
  payload, or a file in the data dir.
- No command, route, or assign returns a credential value.
- Public-key authentication is the default; Buster Claw stores no SSH passwords.
  Host-key verification is documented and never silently disabled.
- Pair/revoke/enable/disable/connect/fail and every `credential_use` reach
  Sentinel without key body, API token, or private-network secrets.
- Remote browser routes cannot reach Tauri IPC, and their fallback states are
  covered by JS and LiveView tests.
- The three-place ACL lockstep passes.
- Full `mix precommit` green. **Packaged smoke includes a real SSH tunnel** —
  endpoint tests cannot prove WebSocket forwarding, and dev builds mask ACL
  omissions.

---

## Research sources

Carried forward from `SSH_REMOTE_ACCESS_ROADMAP.md`.

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
