# The Update — how a running install becomes the next one

**Scoped 2026-08-16 · Status: ACTIVE — `G-42` and `G-18` SHIPPED 08-16.
`G-19` is next, and as of 08-22 it BLOCKS EVERY TAGGED RELEASE.**

> ### `G-19` stopped being a feature on 08-22. It is a release blocker.
>
> The first real run of the release pipeline found a cycle. Read it as a chain,
> because no single link is wrong:
>
> 1. A `v*` tag fails closed without `TAURI_SIGNING_PRIVATE_KEY` — the
>    *"A tagged release must be updatable"* gate, `release-desktop.yml:237`.
> 2. Setting that secret flips `build_desktop.sh:146` to
>    `createUpdaterArtifacts: true`.
> 3. That flag requires a `plugins.updater` block in `tauri.conf.json`.
> 4. There is no such block, because `tauri-plugin-updater` is not wired in —
>    which is `G-19`.
>
> Measured, not reasoned: run `32615493428` died with
> `failed to get updater configuration: plugins > updater doesn't exist`.
>
> **So a tagged release requires the key, the key requires the plugin, and the
> plugin is `G-19`.** Until it lands, the only way to produce an artifact is
> `workflow_dispatch` with the secret *absent*, which publishes nothing and
> yields a downloadable CI artifact instead of a release. That is what R1 is
> being cut from today.
>
> **The keypair now exists** (generated 08-22, no passphrase, backed up
> offline). It is deliberately NOT set as a secret; setting it breaks the build
> until step 4 is done. Whoever sets it next should read this box first.
>
> ### And the branch it flips had never run
>
> `build_desktop.sh:146` is secret-gated — *"with no key the path is skipped."*
> That worked, and it is exactly why the failure survived: **the ON branch had
> never executed once in the history of this repository.** Every CI run and
> every local build took the OFF branch.
>
> The generalisation, which is not specific to Tauri: **a conditional whose
> true-branch has no coverage is not gated, it is unwritten.** Secret-gating
> hides that better than a feature flag does, because there is no flag anywhere
> to notice and nothing lists it.
>
> **Fix `G-19` or fix the branch.** The cheap half is making
> `build_desktop.sh` refuse early, with a message naming `G-19`, when the key is
> present and `plugins.updater` is not — turning a confusing bundler error into
> a sentence. That is worth doing even after `G-19` lands, because it is the
> assertion that would have caught this in the first place.

> ### The one-sentence version
>
> **A button in Settings that says "Restart and update", and a swap underneath it
> that the BEAM survives.**

**This map takes ownership of `G-18`, `G-19` and `G-20`.** They were written in
[`APPLE_ROADMAP`](APPLE_ROADMAP.md) §III.I and **moved here intact — not
renumbered, not copied.** §III.I is now a pointer. Three new gates, `G-42`–`G-44`,
are allocated here and nowhere else (`G-41` was the previous maximum).

The move is not bureaucracy. §III.I is a section about *Apple* — signing,
notarization, Gatekeeper. What the operator asked for on 08-16 is a **product
surface**: a button, a notice, a state the app can be in. That spans the shell,
Settings, the release pipeline, the database and the workspace, and only one of
those five is Apple's. A section inside the signing map could not have held it
without the signing map becoming something else.

---

## What it covers

The whole path from `git tag` to a user's app being the new version: the release
feed, the check, the button, the swap, and the things that rot over years if
nobody names them.

## What it does not

- **Signing, notarization, stapling, the macOS floor** — [`APPLE_ROADMAP`](APPLE_ROADMAP.md).
  This map *consumes* a notarized bundle; it never explains how to make one.
- **The download page and the first install** — [`WEBSITE_ROADMAP`](../website/WEBSITE_ROADMAP.md).
- **The release checklist a human walks** — [`RELEASE_GATE_ROADMAP`](RELEASE_GATE_ROADMAP.md).
- **Telemetry** — [`TRUST_AND_SUPPORT_ROADMAP`](TRUST_AND_SUPPORT_ROADMAP.md). Knowing
  *how many* people updated is a different question from letting them.

---

## Five measured facts this map is built on

Everything below rests on these. Four were read out of the code on 08-16; one was
measured on 08-10. **None is a guess, and the two that would have been guesses are
marked where they appear later.**

| # | Fact | Where |
|---|---|---|
| **F1** | **Notarization took ~5½ hours**, green throughout, zero issues. Best explanation is the artifact's shape — 2,876 files, 2,451 `.beam` — which makes it **structural, not a fluke** | [`APPLE`](APPLE_ROADMAP.md) III.H, measured 08-10 |
| **F2** | The launch chain is **all `exec`** — `bin/buster_claw start` → `elixir` → `beam.smp`. The `Child` the shell holds **is the BEAM**, so `SIGTERM` lands on it and `wait()` reaps the real thing | `main.rs:67`, release script line 110, `releases/*/elixir:245` |
| **F3** | `shutdown_release/1` **already** does SIGTERM → 5s grace → SIGKILL → `wait()`. The hard half of `G-19` is written | `main.rs:776` |
| **F4** | `run_release_monitor` **respawns the BEAM on any exit it did not expect**, backing off, up to a crash-loop cap — and stands down only if `shutting_down` is set | `main.rs:139`, `:172`, `:213`, `:242` |
| **F5** | **The app displays its own version nowhere.** One reference exists in the whole codebase and it is sent to Codex, not shown to anyone | `agent/codex_app_server.ex:264` |

**F2 and F3 together are the good news**: the hazard §III.I warned about most
loudly — an orphaned `beam.smp` still holding the SQLite file — **does not apply to
this shell**, because nothing in the chain forks. That was worth ten minutes to
verify and it removes the scariest item from the map.

**F4 is the bad news, and it is new.** It is the same hazard arriving through a
door §III.I did not predict.

> ### The respawn race — the one bug this map exists to prevent
>
> The obvious implementation of "stop the BEAM, swap the bundle, restart" calls
> `shutdown_release()` and proceeds. **The monitor thread sees a child exit it did
> not expect and respawns it** — from the bundle that is at that moment being
> renamed out from under it.
>
> That is mixed-version code loading inside a live VM, plus a second BEAM holding
> the database, plus a respawn loop racing an `rm -rf`. It would present as an
> intermittent, unreproducible failure on someone else's machine.
>
> **`shutting_down` must be set before the release is stopped, and stay set.** It
> is one line, it is invisible in review, and it is the difference between an
> update that works and one that corrupts an install. It is called out here so
> that when Phase 3 is written it is a requirement rather than a discovery.

---

## Locked decisions

Settled 2026-08-16. Restated because each one closes a door that would otherwise
be pushed on again in a year.

| Question | Decision | Why |
|---|---|---|
| Trigger | **A tag, not a push to `main`** | **F1.** A release costs hours of notary queue. Per-push updates are not slow — they are impossible |
| Cadence | **A few times a year, deliberately** | Full-bundle downloads; no delta channel to amortise |
| Transport | **Full `.app` replacement, no deltas** | Tauri has no macOS deltas; the Sparkle bridge is a signing tarpit whose failures surface at notarization (§III.I) |
| Feed | **Static `latest.json` on GitHub Releases**, per-architecture | Free, no server to run, no server to be breached, no server to expire |
| Who may trigger it | **The operator, in the UI. Never a command** | See below — this is the load-bearing one |
| Where the button lives | **Settings → About** | Boring and findable. A dock notice may come later; the button does not move |
| Install during a shift | **Refused while a shift is running** | Swapping the app mid-run destroys the run. Stand down first — the brake shipped 08-16 as `G-30` |
| Rollback | **A pre-swap database copy, and a documented manual path** | Not an in-app downgrade button. See `D1` |
| Key rotation | **There is none. Plan accordingly** | The public key is compiled into every shipped binary |

### The update is not a command, at any tier

**Nothing in this map appears in `BusterClaw.Commands`.** Not `safe`, not
`restricted`, not gated-and-confirmable.

An agent that can replace the application binary can replace the thing that
refuses its requests. Every other boundary in this codebase — the policy engine,
the trust tiers, the Sentinel audit, the `agent_untrusted` gate — is code inside
the bundle being swapped. A command that swaps the bundle sits *underneath* all of
them, and no tier is low enough to make that safe.

This is the same call the Clinch made and for the same reason: **management is
reachable from the shell and the operator, never from the catalog.** The Clinch
enforces it with a Tauri IPC split plus a trusted-token floor at the router; this
enforces it by **absence**, which is stronger and cheaper.

Absence rots silently, so it gets a test. `test/buster_claw/commands/update_test.exs`
asserts no catalog entry matches `update_*` or `*_update_install`, and fails if one
ever appears — the same shape as the guard that keeps a mutating verb out of
Pockets (`POCKETS_ROADMAP` D4) and `TerminalTheme.set_custom/3` out of the agent's
reach (`TERMINAL_PAINT` D3).

> **Both halves of that sentence matter.** The check runs in the shell and the
> install runs in the shell. Phoenix renders a button and receives a verdict; it
> never holds the capability. What crosses the boundary is an operator's click.

---

## The shape

```
  git tag v0.1.1
        │
        ▼
  release-desktop.yml ──► two runners, two arches, two notarizations (~5½h each, F1)
        │
        ▼
  GitHub Release ──► BusterClaw_0.1.1_aarch64.app.tar.gz  + .sig
                     BusterClaw_0.1.1_x64.app.tar.gz      + .sig
                     latest.json   (per-arch, minisign-signed payloads)
        │
        ▼
  the running app ──► tauri-plugin-updater check()  ──► "0.1.1 is available"
        │                                                       │
        │                                         operator clicks Restart and update
        ▼                                                       │
  download() ──► verify minisign ──► set shutting_down ──► back up the DB
        └──► shutdown_release() ──► install() ──► restart()
```

**Two signatures, and they are unrelated** — the most-missed fact about Tauri's
updater, kept from §III.I because it is the thing people get wrong:

| Signature | Protects | Verified by |
|---|---|---|
| Apple Developer ID | Gatekeeper / notarization | macOS, at every exec |
| **Minisign (Ed25519)** | Update *authenticity* | The updater, before it installs |

Apple's certificate does not satisfy the updater. The minisign key does not
satisfy Gatekeeper. Neither verification can be turned off.

---

## Phases

Ordered by what unblocks what. **The gate numbers are not in order, because
nothing is ever renumbered** — `G-18`–`G-20` arrived from §III.I carrying their
identifiers, and `G-42`–`G-44` are new.

### Phase 0 — Say what you are · `G-42` **[R1]**

**F5: the app cannot currently tell you what it is.** A "Restart and update"
button beside an unknown current version is not a feature, it is a dare. This is
also the smallest possible unit of user-visible progress, and it ships before any
updater exists.

- [ ] **`G-42`.** Settings → About shows the running version, read from
      `Application.spec(:buster_claw, :vsn)` — the same `VERSION` file that
      `sync_version.sh` already propagates into `tauri.conf.json` and `Cargo.toml`.
      One source of truth, already built; this only surfaces it.
- [ ] The architecture is shown beside it. Two single-arch builds exist and a
      support conversation that cannot establish which one is running starts twice.

*Cost: an hour. Depends on nothing.*

### Phase 1 — The feed · `G-18` **[R2]** — **PIPELINE BUILT 08-16, unexercised**

Publish something updatable. **No client-side code in this phase** — the artifacts
can be verified by hand long before anything consumes them.

**Built 08-16:**

- [x] `build_desktop.sh` produces the updater tarball + minisign signature,
      **secret-gated on `TAURI_SIGNING_PRIVATE_KEY`** exactly as the codesign pass
      is gated on `APPLE_SIGNING_IDENTITY`. A `--config` override rather than a
      committed `createUpdaterArtifacts: true`, because Tauri *fails* a build that
      sets the flag with no key available — a committed `true` would turn every
      keyless local build and every CI verification run into a hard error.
      *(Key name and bool type verified against `tauri-utils` 2.9.3 at the pinned
      CLI version, not from memory: `BundleConfig` is `deny_unknown_fields` +
      `rename_all = "camelCase"`, so a typo would fail loudly.)*
- [x] `scripts/build_update_feed.sh` assembles `latest.json`. **Fails closed** when
      an architecture is missing or unsigned, and **writes nothing at all** in that
      case — verified by breaking it three ways.
- [x] `release-desktop.yml` gained a **`release` job**: tag-only, `contents: write`
      scoped to itself, joining both arches' artifacts (neither runner can build
      the feed — each holds only its own signature), creating the GitHub Release
      and attaching the DMGs, both tarballs, both `.sig`s, and `latest.json`.
- [x] **A tagged release with no signing key fails before anything is built.** A
      release nobody can update to is not discovered at build time or install
      time, but months later when a fix does not reach anyone.

**`latest.json` is per-architecture via its `platforms` map**, not two files —
`darwin-aarch64` and `darwin-x86_64`, which is the shape Tauri's updater looks
itself up by. The feed script's `ARCHES` table is the thing that stops an arm64
install being handed an Intel bundle.

**What only the operator can do:**

- [ ] **Generate the keypair** — `cargo tauri signer generate -w ~/.buster-claw/updater.key`
- [ ] **Back the private key up offline, before the first signed release.** Anyone
      holding it can push arbitrary code to every install, and **there is no
      revocation** — the public key is compiled into every shipped binary, so a
      rotated key is *rejected* by the installs you were trying to reach. Dangerous
      to leak and dangerous to lose.
- [ ] Set `TAURI_SIGNING_PRIVATE_KEY` + `TAURI_SIGNING_PRIVATE_KEY_PASSWORD` as
      repo secrets.
- [ ] **Add the Vercel rewrite in the website repo** — see below. Nothing in this
      repo can do it, and nothing in this repo will notice it missing.

> ### The endpoint, decided 08-16 — and the one cross-repo dependency
>
> **`https://busterclaw.lol/updates/latest.json`**, rewriting to the `latest`
> GitHub Release. Chosen over pointing at GitHub directly because **the endpoint
> is compiled into every shipped binary and cannot be changed for installs already
> in the wild** (`D5`). There are zero installs today, so this is the only moment
> it is free.
>
> The cost is a dependency on a **separate repo** (busterclaw.lol is its own
> project on Vercel):
>
> ```json
> { "rewrites": [{
>     "source": "/updates/latest.json",
>     "destination": "https://github.com/hightowerbuilds/buster-claw/releases/latest/download/latest.json"
> }] }
> ```
>
> **Nothing in this repo can add that, and nothing here fails without it.** The
> release job therefore ends by fetching the public URL and emitting a CI
> **warning** if it does not return 200 — loud at release time rather than silent
> on every user's machine months later. It is deliberately `continue-on-error`:
> a missing rewrite must not fail a release that is otherwise correct, because the
> artifacts are fine and the fix is one line in another repo.

**Still unexercised.** The workflow runs only on `v*` tags, so none of the above
has been executed — this is a written pipeline, in the sense `APPLE_ROADMAP`'s
written-versus-exercised column means it. The first tag is the test.

*Cost: a day of pipeline work — spent. Plus one notarization wait per arch (F1)
whenever the first tag is cut.*

### Phase 2 — The check · `G-43` **[R2]**

Read-only. The app learns a newer version exists and says so. **It cannot yet
install one**, which makes this phase safe to ship and impossible to get badly
wrong.

- [ ] **`G-43`.** `tauri-plugin-updater` added; a `update_check` IPC command
      registered in **`build.rs`, `capabilities/default.json`, and
      `generate_handler!` together**.

  > Three places, one command. The 07-17 co-presence bug and the 07-21
  > `speak`/`stop_speaking` repeat were both a missing `build.rs` entry that a
  > stale `permissions/autogenerated/*.toml` masked in dev and killed in a clean
  > packaged build. `tests/acl_lockstep.rs` enforces it — the guard exists
  > *because* this was missed twice.

- [ ] Settings → About shows "Up to date" or "0.1.1 is available".
- [ ] **The check fails silently and never blocks boot.** No network, GitHub down,
      rate-limited, feed malformed — all render as "couldn't check", never as an
      error state and never as a delay in front of the app.
- [ ] The check is **manual or once per launch**, never a poller. This app has one
      background poller already and it is a telephony drain with a reason.

*Cost: a day. The ACL lockstep is the only sharp edge.*

### Phase 2b — A tag can build · `G-19a` · `G-46` **[R1]** *(allocated 08-22)*

**Split out of `G-19` on 08-22 because the cycle only needs this half.** A tagged
release needs a valid *updater artifact*; it does not need a working update. Those
turned out to be different amounts of work, and only the first blocks shipping.

- [ ] **`G-19a`.** A `plugins.updater` block exists with the endpoint and the
      compiled-in pubkey, and `build_desktop.sh` produces a signed `.app.tar.gz`
      with the `TAURI_SIGNING_PRIVATE_KEY` secret set. **Done when a
      `workflow_dispatch` with the secret present goes green.**
      > **A one-way door, not a config tweak.** The pubkey compiles into every
      > binary and there is no revocation: the keypair chosen here is permanent for
      > every install that follows it. The pair generated 08-22 (no passphrase) is
      > the candidate. **Confirm it is backed up offline before this block is
      > written**, not after.
      >
      > **Establish first, in ten minutes, with one `workflow_dispatch`:** whether
      > the config block alone satisfies the bundler, or whether
      > `tauri-plugin-updater` must also be a Cargo dependency and registered in
      > `main.rs`. That answer is the difference between an hour and a day, and
      > guessing it wrong costs a notarization round trip.
- [ ] **`G-46`.** **Make the trap loud.** `build_desktop.sh` must refuse early —
      before `mix release`, before Rust, before anything Apple sees — when
      `TAURI_SIGNING_PRIVATE_KEY` is set and `plugins.updater` is absent, with a
      message naming `G-19a`. Today that combination surfaces as
      `failed to get updater configuration: plugins > updater doesn't exist`
      after several minutes of build, and reads as a Tauri bug rather than a
      missing gate.
      > **Worth doing even after `G-19a` lands**, because it is the assertion that
      > would have caught this on day one instead of on the first release attempt.
      > It also survives the reverse mistake: someone deleting the config block
      > later gets a sentence instead of a riddle.

*Cost: `G-46` is an afternoon at most. `G-19a` is unknown until the question above
is answered.*

### Phase 3 — The swap · `G-19b` **[R2]**

The button. Everything above exists to make this small.

> **Renamed from `G-19` to `G-19b` on 08-22** when Phase 2b was split off. The
> number is not reused and nothing is renumbered: `G-19` remains the name of the
> whole update capability, `G-19a` is the half that lets a tag build, and `G-19b`
> is this — the half a user can see. Commits citing plain `G-19` predate the split
> and refer to this phase.

- [ ] **`G-19`.** The BEAM-safe sequence, in this order, **never
      `download_and_install()`**:

  1. `download()` and verify the minisign signature.
  2. **Set `shutting_down`** (F4 — the respawn race; this is the line the map exists for).
  3. **Back up the database** (`D1`).
  4. `shutdown_release()` — already correct (F2, F3).
  5. `install()`.
  6. `restart()`.

- [ ] Refused while a shift is running, with the reason and a route to **Stand
      down** (`G-30`, shipped 08-16). Not a warning that can be clicked through:
      the run is doing real work with real tokens.
- [ ] A failure at any step **leaves the current install running and untouched.**
      A download that half-arrives, a signature that does not verify, a BEAM that
      will not stop — every one of them ends with the app the operator already had.

*Cost: two days, most of it on the failure paths rather than the happy one.*

### Phase 4 — Prove it · `G-20` **[R2]**

- [ ] **`G-20`.** An actual `0.1.0 → 0.1.1` update, end to end, **on hardware that
      did not build either version**, preserving workspace, settings, database, and
      the Google connection. **Tested, not assumed.**
- [ ] Both architectures. `G-4`'s dependency applies here too: **nobody has ever
      launched an Apple Silicon build**, so half of this gate is blocked on a
      machine rather than on code.
- [ ] The negative control: a tampered `.app.tar.gz` is **refused**, and the
      running install survives it. A verification you have never watched fail is a
      verification you have never tested.

*Cost: an afternoon per arch, and it cannot be shortened or simulated.*

### Phase 5 — The rot · `G-44` **[R2]**

**The one that only matters over years, and the reason this map says "durable".**

`maybe_write/2` never overwrites (`skills.ex:305`, `terminal_commands.ex:273`).
That is correct — it is what stops an update from destroying an operator's edits.
Its consequence is that **every shipped default is frozen at install time,
forever**: the six default skills, the terminal command roster, `memory/policy.md`.

Ship v0.5 with a better default skill and a v0.1 user never receives it. Discover a
policy default that is too loose and **you cannot tighten it for anyone who already
installed.** Today that is a design note with nobody affected. The moment updates
exist it is a live divergence that widens with every release, and it is invisible —
the app looks fine, it is just running last year's defaults.

- [x] **`G-44`.** Seeds carry a version. On boot, a seed file whose bytes still
      match the default it shipped with is **unmodified**, so it upgrades. A seed
      the operator has touched is **theirs**, so it does not — and the app says
      what it declined to update and why.

The comparison is bytes, not timestamps, and the previous shipped default is the
thing compared against — which means the app must retain them. That is the whole
design; it is smaller than the problem it solves.

> ### Built 08-18 — `BusterClaw.Seed`, and why it stopped being a [R2] item
>
> **The prediction above came true four months early, and not gently.** This was
> filed as *"the one that only matters over years"* with *"nobody affected"*.
> Then BusterPhone became intake-only, `sms_send` left the command catalog, and
> every workspace in existence was left holding a seeded job brief instructing
> the agent to run **a command that no longer exists**. Not a stale default — a
> broken one, in the file the agent reads to decide what to do.
>
> So the mechanism exists now: `lib/buster_claw/seed.ex`, wired for the four
> `Jobs` seeds (`mail-triage`, `voicemail-triage`, `sms-triage`, the roster).
> Four outcomes — `:created`, `:current`, `:upgraded`, `:kept`.
>
> **One refinement to the design as written.** It retains **digests**, not the
> prior text. That answers the only question being asked — *is this unmodified?*
> — at 64 bytes per version instead of a document. The cost is that the app
> cannot show the operator a diff of what it declined to change, only that it
> declined. Revisit if a surface ever wants the diff.
>
> **The failure mode is asymmetric on purpose.** An unrecognised digest is always
> treated as the operator's, so a forgotten version entry costs an upgrade that
> did not happen — never a file that got destroyed. That safety is also what
> makes the version lists rot *silently*, which is why `SeedTest` pins each
> current digest as a review-forcing snapshot: edit a default without appending
> its digest and the build fails with the digest to add. Both directions were
> verified by reintroducing the defect and watching them fail.
>
> **Historical digests were recovered from git**, by parsing every past revision
> of `jobs.ex` and hashing each `default_*` body — 8 shipped versions of the mail
> brief, 8 of the voicemail brief, 5 of the roster, 2 of `sms-triage`. Installs
> holding *any* of them upgrade.

**What remains of `G-44`:**

- [ ] `Skills.ensure/0` (`skills.ex:305`) and `TerminalCommands.ensure/0`
      (`terminal_commands.ex:273`) still use create-only `maybe_write/2`. Same
      mechanism, same shape — they need version lists recovered the same way.
- [ ] **`memory/policy.md`, the trusted-sender lists, and the agent settings are
      deliberately NOT converted, and should not be by list-append.** `G-44`
      treats every seed as one problem; they are not. Those three are **security
      state**, and silently replacing an operator's policy file on boot — even
      one that looks unmodified — is a different act from replacing a job
      description. It needs its own decision about what an automatic *tightening*
      may do, and to whom it should be visible. Filed here rather than done.

*Cost: two days. **This is the phase most likely to be dropped and most expensive
to add later**, because every release that ships without it widens the set of
installs it has to reason about.* — *and the half that got built cost an
afternoon, because the deletion that forced it had already made the case.*

---

## Durability notes

Things that do not fit a phase but will decide whether this still works in 2029.

**`D1` — migrations are a one-way door.** `Ecto.Migrator` runs at boot for releases
(`application.ex:28`; `skip_migrations?` is false exactly when `RELEASE_NAME` is
set). An update that ships a bad migration leaves a user with a database the old
binary can no longer open, and **no path back**. The mitigation is one line and
belongs in Phase 3: **copy the SQLite file and its `-wal` before the swap**, keyed
by the version being left. Recovery is then a documented file copy rather than a
support incident. Deliberately *not* an in-app rollback button — a downgrade path
is a second update mechanism, with its own failure modes, guarding an event that
should be rare.

**`D2` — skipping versions must stay free.** Full-bundle replacement means
`0.1.0 → 0.4.0` is one hop, not four. That property is worth more than the
bandwidth deltas would save, and it holds **only while migrations stay ordered and
additive.** A migration that assumes the immediately-previous schema breaks every
user who was away for two releases — the ones least likely to be watching.

**`D3` — the pipeline must not become the bottleneck it looks like.** F1 makes a
release cost a working day of wall-clock. Submit in the morning; never schedule
notarization as the last act of a session. This is a property of the artifact,
not of the tooling, and no amount of CI work removes it.

**`D4` — one place decides the version, and it already exists.** `VERSION` →
`sync_version.sh` → `tauri.conf.json` + `Cargo.toml`, with `mix.exs` reading it
directly. **Do not add a second.** The updater compares versions, so a feed that
disagrees with the binary is an update loop or a permanent "up to date" on a stale
install — both silent.

**`D5` — GitHub Releases is a dependency with a lifetime.** It is the right answer
today: free, no server, nothing to breach or renew. If the repo ever goes private
or moves, **the feed URL is compiled into every shipped binary** and old installs
follow it to a 404. Keep the endpoint on a domain we control
(`busterclaw.lol/updates/latest.json`) redirecting to GitHub, so the storage can
move and the installs do not need to.

> `D5` costs nothing now and cannot be retrofitted onto installs already in the
> wild. It is the cheapest durable decision in this map and the easiest to skip.

---

## Exit tests — the definition of "updatable"

Not "it built." On hardware that has never seen the repo.

- [x] Settings → About names the running version and architecture (`G-42`) — **08-16**
- [ ] `latest.json` resolves per-arch and an Intel install is never offered arm64 (`G-18`)
- [ ] The minisign private key exists in offline backup, **confirmed by looking** (`G-18`)
- [ ] `https://busterclaw.lol/updates/latest.json` returns 200 and serves the
      current release — the cross-repo rewrite, which nothing here can verify
      until a release exists (`G-18`, `D5`)
- [ ] An offline app checks, fails, and says so — without blocking boot (`G-43`)
- [ ] `0.1.0 → 0.1.1` preserves workspace, settings, database, Google connection (`G-20`)
- [ ] A tampered bundle is refused and the running install survives (`G-20`)
- [ ] An update is refused while a shift runs, and offers Stand down (`G-19`)
- [ ] `update_test.exs` fails if an update verb ever enters the catalog
- [ ] A v0.1 install that updates receives v0.2's default skills (`G-44`)

---

## The short version

**Phase 0 is an hour and ships now.** Phases 1–4 are roughly a week, gated on
notarization wall-clock rather than effort, and blocked in part on an Apple
Silicon Mac that `G-4` already needs.

**Phase 5 is the one to protect.** The other phases fail loudly on the day you
build them. Phase 5 fails quietly, three years from now, on someone else's machine.
