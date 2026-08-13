# The Clinch — one place for credentials, reachable from anywhere

**Scoped 08-08-26 · Status: ACTIVE — Phases 0–4 COMPLETE. Phase 5 (remote mode) is
next, and its prerequisite is met: credentials can now be rotated and revoked, and
an agent with a shell cannot manage them.**

| Phase | State |
|---|---|
| 0 — Stop the bleeding | **DONE** (`35d7a55`, `df1d097`) |
| 1 — The Clinch contract | **DONE** (`6ee19d1`) |
| 2 — The management gate | **DONE** (`8aff7f9`) |
| 3 — The screen, and evicting the env vars | **DONE 08-10** (`6415825`, `121f954`, `43f61e2`, `1a705a2`, `7ec5f52`). BusterPhone is configurable in a packaged build; closes #5 |
| 4 — Rotation, revocation, the second vault | **DONE** (`2f157d1`, `6b36f42`, `3efe94e`, `c683f00`, `0e289de`, `b8721aa`) |
| 5–7 — Remote mode, pairing, private network | **NEXT.** Not started (absorbed from the SSH map); Phase 4 was the gate and it is open |

**One thing no test can close.** Everything below is verified by automated gates,
but nobody has clicked these controls in a **packaged build**. Phase 2's own
acceptance criterion — *"a packaged build stores and deletes a credential from
the UI"* — needs a person, a signed build and an afternoon. It belongs with
LAUNCH **G-40**, which is already the bucket for exactly this class of item, and
it should travel there rather than sit here looking done.

> **A notarized DMG now exists (08-10), so that walk is finally possible.** It was
> blocked on an artifact until the Apple path completed; it is now blocked only on
> someone sitting down with it.

> ### Rotation is operable — `0e289de`
>
> **`./buster-claw clinch rotate --confirm`.** A CLI verb, not a catalog command:
> the Clinch's split is *use, never manage*, and rotation is management, so no
> agent can reach it because there is nothing to reach. A test asserts no catalog
> entry matches `rotate`, so adding one later trips a guard rather than quietly
> widening the surface. The endpoint sits on `:api_trusted` — and a *valid* token
> is not a *trusted* one; the MCP and agent-untrusted tokens are tested refusals.
>
> **The new key is generated on the operator's machine and printed before anything
> is re-encrypted.** That ordering is the safety property, not the presentation:
> a failed rotation leaves them holding a key that opens nothing, which is
> harmless, while a successful one whose key they never saw leaves a database
> nobody can open. The endpoint refuses to generate a key for the same reason —
> the only copy of a master key should exist somewhere the operator chose *before*
> anything depends on it.
>
> **What is still manual, by decision (operator, 08-10): the Keychain write.** The
> app switches to the new key immediately (`System.put_env`, which
> `RuntimeConfig` reads first) so nothing restarts, but persisting it is the
> operator's step and the CLI says so plainly. Without it the next boot reads the
> old key and every credential looks absent.
>
> **The one-click version is a real design problem, not laziness.** "Data moved"
> and "Keychain updated" are two systems, and a failure between them leaves a key
> that opens nothing — a two-phase commit across BEAM and Rust. Worth doing
> properly as its own scope rather than improvised.
>
> ### If someone builds the one-click flow, the ordering is the whole job
>
> Neither naive order is safe. Re-key then write the Keychain: a failed write
> leaves data under the new key and the Keychain holding the old, so the next boot
> opens nothing. Write then re-key: a failed re-key leaves the reverse.
>
> The shape that works is **write the new key as a SECOND Keychain entry first,
> re-key, then promote it** — so at every instant at least one stored key opens the
> data, and boot can try the pending entry when the primary fails. That is what
> makes it a phase rather than a button, and it is why the CLI leaves custody with
> the operator: a human who has written the key down is a recovery path that needs
> no protocol.

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
| **The agent** — prompt-injectable, runs in-VM with real command authority | No command ever returns a value. A model emits a reference; resolution happens in the executor at the moment of use. | **Holds.** `Egress.SecretRef` + `Clinch.resolver/2` always did the read side; Phase 0 closed the write side, where the value reached `security_events` in the clear. |
| **The remote operator** — holds an SSH key, may be a stolen laptop | Management is unreachable, not merely denied: it requires the full loopback API token, which lives only in the Keychain and the shell process env. | **Built (Phase 2)** — `RequireTrusted` + Tauri IPC. Unproven over an actual tunnel until Phase 5, which is the point of that phase's exit criteria. |
| **Someone with the disk** — a backup, a stolen Mac, a copied `.db` | AES-256-GCM at rest via `Clinch.Vault`, keyed from `secret_key_base`, which lives in the Keychain and never on disk. | **Holds.** Both Phase 0 holes closed; the master key stopped being a LiveView assign in Phase 2. |

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

Three of the seven are closed. **Finding #2 turned out to be wider than written**
— see Phase 0.

| # | Finding | Phase | State |
|---|---|---|---|
| 1 | **Env-var credentials are unreachable in a packaged build.** A double-clicked `.app` inherits launchd's environment, not a shell's; the shell forwards only eight vars (`main.rs:65-72`). Twilio/Supabase/Finnhub therefore cannot be configured by any user of a shipped build — and `phone_component.ex:178` tells them to "set TWILIO_ACCOUNT_SID," an instruction with nowhere to be carried out. | 3 | open |
| 2 | **`browser_secret_put` writes the plaintext secret into the audit log.** It is `:mutate`, so `audit_invoke` captures its args (`commands.ex:294-308`). `scrub_audit_args` covers `browser_flow` steps and note bodies, not this (`commands.ex:318-328`). The arg key is `"value"`, which `@sensitive_fragments` does not match (`sentinel.ex:43`), and the value-shape masks only catch prefixed tokens, 40+ char alnum runs and Luhn cards — an ordinary site password matches none. `secret.ex` promises the value "never appears in a dump of the database"; true of `browser_secrets`, false of `security_events`. | 0 | **closed** |
| 3 | **No GUI for the `$secret` store.** The only writer is `commands/web.ex:708`, so the operator's only way to store a password is to type it to a model or into a terminal — where the model reads it going in, the transcript keeps it, and shell history keeps it. Defeats the stated design in `secrets.ex:26-34`. | 2 | **closed** — the Clinch panel is that GUI |
| 4 | **`agent_token` is the one loopback token with no Keychain path.** The shell provisions three secrets; `runtime.exs:199` reads `BUSTER_CLAW_AGENT_API_TOKEN`, which nothing sets. So `ApiToken.agent_value/0` writes cleartext to the data dir — and it is the token authorizing untrusted-provenance agent runs. | 0 | **closed** |
| 5 | **Integration tokens round-trip to the browser in cleartext on edit.** `integrations_live.ex:75` builds the changeset from the loaded (decrypted) struct; `normalize_value/2` has no password case, so `core_components.ex:292` renders `value="ghp_…"` into the DOM and the LiveView diff. Loopback-only today — but this is exactly the class of leak a tunnel promotes. | ~~2~~ 3 | **open** — the new path exists, integrations have not moved onto it |
| 6 | **Two vaults doing one job, and no rotation story.** `Vault` and `Google.Vault` differ only in AAD and key prefix; `Google.Account` hand-rolls what `Encrypted` already does. Everything derives from `secret_key_base`, `Recovery` is read-only, and there is no re-key path. | 4 | open |
| 7 | **The in-app terminal gets the full-access token.** `main.rs:575` puts `BUSTER_CLAW_API_TOKEN` into the shell process env and `terminal.rs:95` forwards it to every PTY. Deliberate and documented — but the scoped `mcp`/`agent` tokens exist for exactly this shape of problem, and the terminal gets the unscoped one. | 4 | open |

---

## Phase 0 — Stop the bleeding — **DONE 08-08**

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

### What it turned out to be — **the leak was wider than written above**

Raw args reached **four** Sentinel sinks and `scrub_audit_args` guarded exactly
one: the invoke audit. The rate-limit block, both refusal paths, and
`Sentinel.Pending` all carried them untouched. So a credential **refused** for an
untrusted caller leaked where the same credential **accepted** for a trusted one
did not — the audit was strictest exactly where the least happened.

Fixing four call sites would have left a fifth to forget, so the scrub moved into
`record/3`, the one function every Sentinel sink in `Commands` already passes
through. `Pending` gets it explicitly, being the one sink that does not.

That is the roadmap's own argument applied to its first fix, and it is worth
generalising: **a finding written from reading is a lower bound.** The write-up
named the sink that was easiest to see.

Test discipline that came out of it and should hold for the rest: the test value
is *password-shaped* on purpose — short, unprefixed, not Luhn-valid — because a
`ghp_`-style value is caught by Sentinel's existing generic masks and would prove
nothing about the scrub under test. Every guard in this roadmap was then verified
by **breaking the fix and watching the test fail**, not by watching it pass.

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

## Phase 2 — The management gate — **DONE 08-08**

Three new Tauri commands, and the plaintext leaves the web layer.

**Shipped:** `clinch_put` / `clinch_delete` / `clinch_reveal_recovery_key` in
`src/clinch.rs`, registered in all three lockstep places. `POST|DELETE
/api/clinch` behind a new `:api_trusted` pipeline (`ApiAuth` then
`RequireTrusted`) — **no GET, ever**. `assets/js/lib/clinch.js` (pure, 12 bun
tests) with `hooks/clinch.js` as the DOM shell, and both panels extracted to
`BusterClawWeb.ClinchPanels`.

**`RequireTrusted` is a floor, not a tier.** `ApiAuth` alone would admit the MCP
token and the agent-untrusted token — both are *valid* tokens, one handed to
external agents and one to a headless run working open-internet content.
`Commands.call/3` never sees these routes, so there is no per-command tier to
fall back on. Anything that is not `:trusted` gets 403.

**The recovery key is no longer a server assign.** It used to be assigned at
mount and rendered into a readonly input — so the value that decrypts every other
credential was in the socket's assigns and the rendered diff on *every* visit to
Settings, revealed or not. Rust now reads the Keychain directly and hands it to a
node the hook owns.

**Two things worth carrying forward.** The kind arrives as a string and is matched
against the declared enum rather than `String.to_atom/1`d — request input must not
be able to grow the atom table, and the test asserts the string never became an
atom at all. And `settings_live` blew its frozen size cap, so the panels were
**extracted** rather than the cap raised: Phase 3 grows this surface further, and
raising a cap twice for the same screen is how the last two decompositions were
undone.

**Verified by breaking each guard.** Deleting one capability entry fails
`acl_lockstep` naming the command. Restoring the `@recovery_key` assign fails
`SettingsRecoveryKeyTest` with "settings_live still assigns the recovery key".

**Not yet done from this phase's own text:** integrations have not moved onto this
path, so finding #5 (the `type="password"` round-trip in `integrations_live`) is
still open. It closes in Phase 3 when `:service_key` gets a writable home.

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

## Phase 3 — The Clinch screen, and evicting the env vars — **DONE 08-10**

The phase that unblocks the money leg. **BusterPhone is configurable in a packaged
build for the first time.**

> ### What the build taught, beyond the checklist
>
> **3c turned out to be a deletion, not a mechanism.** The phase asked for
> key-gated children that "start and stop when a credential appears or
> disappears, without an app restart", which reads like a DynamicSupervisor.
> `Drain.drain/1` had always opened with `Relay.configured?()`, so the *work* was
> already gated; gating the *child* at boot was a second answer to the same
> question — and the one that could go stale, since a credential stored after boot
> could never flip it. Removing the boot gate was the whole change.
>
> **A second writable kind, not a writable `:service_key`.** The first attempt put
> app credentials in the existing kind and made `managed?` per-entry. `Clinch`'s
> own invariant test refused it: that forces `list/1` to restate `managed?` as a
> literal, which is the coincidence-not-derivation bug it exists to prevent. Its
> failure message read *"the write boundary has two answers again"*. `Types`
> already says a kind decides **where it lives and who may manage it** — two
> stores with two managers is two kinds. Hence `:app_key`.
>
> **A cost worth knowing before the next credential moves:** making config
> resolution storage-backed means pure unit tests of those modules now need a
> database. `TwilioTest` and `FinanceFinnhubTest` moved to `DataCase`. The third
> module to read a credential will pay the same tax.

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

## Phase 4 — Rotation, revocation, and the second vault — **COMPLETE 08-10**

Cheap once the Clinch owns the values, and it must precede remote access: a
credential you cannot rotate is one you cannot respond to a compromise with.

> ### The chokepoint paid for itself
>
> Phase 1's facade moduledoc predicted that routing both vaults through one place
> would make retiring the second *"a change to this file plus a migration, rather
> than a change to every caller"*. That is exactly what it cost: one facade, one
> schema, one migration (`20260810220000`), verified on live data — 3 values up,
> 3 back, 3 up again, zero skipped.
>
> **A documentation error nearly wrote unreadable ciphertext.** The facade's table
> gave the Google AAD as `google:v1` — that is the *key derivation prefix*; the AAD
> was `buster_claw.google.vault.v1`. The two vaults' frames were byte-identical, so
> a migration written from that table would have produced values that fail GCM
> authentication forever, with no error until use. Caught before writing it, fixed
> in `48026f5`. **When two things differ only in constants, naming one wrongly is
> invisible.**
>
> ### The bug that outranks the features
>
> `Sentinel.Event` validates `category` against a whitelist and `observe/4` is
> best-effort by design — so **both new revocation categories were silently
> dropped**. Invalid changeset, warning logged, caller told nothing. The full suite
> passed; the new tests passed. A security feature this roadmap says exists was
> recording nothing, and the only evidence was one `Logger` line in green output.
>
> `SentinelCategoryTest` now scans every `observe/4` call site against
> `Event.categories/0`. **Any best-effort write is a place a feature can be absent
> and green** — worth checking wherever else that pattern appears.

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

**Where each item landed:**

| Item | State |
|---|---|
| Re-key | **DONE** `6b36f42` — one transaction; unreadable values counted and left byte-for-byte, because that is what a previous bad key change leaves behind and aborting would refuse to run when most needed |
| Invocable | **DONE** `0e289de` — `clinch rotate --confirm`, trusted-token floor, key printed first |
| Retire `Google.Vault` (#6) | **DONE** `2f157d1` |
| Invariant 5's visibility half | **DONE** `3efe94e` — "nothing configured" and "everything unreadable" rendered identically; now they do not |
| Revocation as a first-class event | **DONE** `c683f00` — no separate `revoke/1`, because a second verb leaves a path that removes a credential *without* the event |
| Scope the terminal's token (#7) | **DONE** `b8721aa` — a fourth token, trusted-equivalent for commands and refused for management |

**The acceptance is met**, and operably: `./buster-claw clinch rotate --confirm`
rotates the key, preserves every integration, `$secret`, `:app_key` and Google
account, and a revoked credential's next use is recorded with what to do about it.

> ### #7 was sharper than its one-line description — 08-10
>
> The line above says "the PTY gets a terminal-tier token", which reads like
> tidiness. What it actually fixed: **`RequireTrusted`'s own justification for the
> full token is that an attacker "gets no shell and therefore no Keychain" — and
> the in-app terminal is a shell that had the full token in its environment.** An
> agent running there could store, delete and (after `0e289de`) rotate
> credentials. The founding rule — *use, never manage* — was untrue wherever an
> agent had a prompt, and Phase 5 would have made it untrue *remotely*.
>
> **The tier is trusted-equivalent for commands, and that is the load-bearing
> half.** The terminal runs the operator's own agent: it must keep doing dispatch
> work, sends and deletes. Scoping it further would close the hole by breaking the
> loop this product is built on — so a test asserts `gmail_send` and
> `document_save` still pass for `:terminal`, and says why in its failure message.
> **That is the regression a future "tighten this up" change would cause**, and it
> is the direction nobody thinks to guard.
>
> **A Rust trap, recorded because the next person will hit it.** `clinch.rs` reads
> `BUSTER_CLAW_API_TOKEN` from the Tauri *process* env to reach the management
> routes on the operator's behalf. Downgrading that variable would have broken the
> credential panel itself. The process keeps the full token; `terminal.rs` injects
> the terminal one into the PTY *under the same name*, so the in-app CLI needed no
> change.
>
> **`secret_provisioning.rs` refused the new secret until it was declared** — the
> named-inventory guard written after `agent_token` was provisioned nowhere and
> quietly wrote itself to disk in cleartext on every packaged install. It worked.

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

> **A phone is not a small laptop, and Phases 5–7 assume a laptop.** iOS
> suspends a backgrounded app within seconds, so the forwarded port dies the
> moment you leave the SSH client to look at the UI — which is the entire point.
> `tailscale serve` reaches the loopback listener without any of this, keeps the
> loopback bind intact, and may make the phone path need no SSH at all. Scoped
> separately in [`PHONE_ACCESS`](PHONE_ACCESS_ROADMAP.md); **read it before
> writing phone instructions into this phase's onboarding copy.**

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
