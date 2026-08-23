# 08-22-26 — There was nothing to update

The evening opened with a reasonable-sounding task: **make sure the newest
working version of Buster Claw is on busterclaw.lol.** It took about ten minutes
of measuring to find that the sentence has no referent.

Nothing has ever been published. Not a stale version — *no* version.

| Checked live, 08-22 | Result |
|---|---|
| The download button in the deployed site bundle | `https://DOMAIN-TBD.invalid/BusterClaw-0.1.0-x86_64.dmg` |
| `gh release list` | **empty** |
| `git tag` | one archive tag; **no `v*` tag has ever existed** |
| `busterclaw.lol/updates/latest.json` | 404 |
| The site's command count | **"211 commands"** — the app has 215 |

That last row is its own small finding. `WEBSITE_ROADMAP` records the copy fixes
as *"built clean, not yet deployed"* on 08-16. Six days later the live bundle
still serves the old numbers, so **whatever is in the site repo is not what is
serving.** "Fixed but not deployed" and "not fixed" are the same thing to a
visitor, and only one of them looks done on a checklist.

And the DMG sitting on the build machine — the only artifact in existence — was
never shippable:

```
codesign: code object is not signed at all
spctl:    rejected — source=no usable signature
stapler:  does not have a ticket stapled to it
```

A bare `cargo tauri build` output, eight commits stale, predating the BusterPhone
intake-only cut. Hosting it anywhere would have produced a Gatekeeper refusal
rather than a download.

> ### The reframe that made the evening tractable
>
> The question was never *where do we host it*. A Supabase bucket, GitHub
> Releases, anything with an HTTPS URL — all of them work, and none of them was
> the blocker. **The blocker was that no signed artifact existed to host.**
> Hosting is ten minutes; signing was the part nobody had ever run in CI.

---

## What landed

**`0e38592` — Req 0.5.17 → 0.7.2.**

Found as uncommitted work in a shared tree and initially misread as dependency
tidying. It is not: it drops `tzdata` (and `hackney` with it, plus six more
transitive deps) and rewrites the SSRF guard's redirect handling.

`URLGuard.unpin_step/1` carried a hand-rolled `rearm_guard/1` that pushed
`:ssrf_guard` back onto `current_request_steps` on every hop, because Req 0.5's
redirect step re-entered `run_request/1` without resetting the consumed list —
request steps did not re-run, so without the re-arm a redirect hop was neither
validated nor pinned. Req 0.7 keeps the full step list and reruns it, making the
re-arm redundant.

**Verified rather than accepted.** `url_guard_test.exs` predates the change and
was not touched; its two redirect cases — the per-hop fresh resolution, and *"a
redirect to a blocked host is refused without being contacted"* — pass against
0.7.2 with `rearm_guard` gone. That is what makes the new behaviour a measurement
instead of a changelog reading. `mix precommit` green, exit 0.

The app now carries no dependency that fetches anything on its own schedule.

**`cb7da07` — the fresh-machine walk starts one step earlier.**

`FRESH_MACHINE_WALK` was scoped 08-18 and began at *"DMG mounts."* Every check in
it tests an app already on the machine. How it got there was never anyone's item,
and it decides whether the rest of the walk means anything.

`DL-1` is the load-bearing addition: **Gatekeeper does not run on a file with no
`com.apple.quarantine` attribute.** A DMG that arrived by AirDrop, by USB, or by
`unzip` from a CI artifact is byte-identical to a downloaded one and passes
`FM-2` without Gatekeeper ever being consulted. A false pass on the single check
notarization exists to satisfy. Finder's Archive Utility propagates quarantine;
`unzip` does not.

`DL-3` carries `G-24`'s number into the walk — and is deliberately worded as
*quote what the page told you* rather than *check the number is right*, because a
reader who already knows the answer will find it whether or not a stranger would.

> **`DL-3` was written saying `14.0` and was wrong within three hours**, when CI
> measured the real floor at `15.0`. Corrected the same evening. It is a small,
> perfect demonstration of the thing this file keeps recording: **a number copied
> into prose is a number that will go stale**, and the checklist now says to read
> it from `tauri.conf.json` instead of trusting the line above it.

Written ahead of the artifact and says so: `DL-3`–`DL-5` are not walkable yet,
and the header instructs the walker to record that rather than tick them.

---

## The release path had never been run, and it is broken

The pipeline is complete on paper: two native runners, sign, notarize, staple,
boot-test the artifact, verify the macOS floor, `gh release create`. All five
Apple secrets have been set since 08-10. The minisign key was generated tonight.
Setting the last secret and firing `workflow_dispatch` should have been
mechanical.

It failed:

```
Error failed to build bundler settings: failed to get updater configuration:
      plugins > updater doesn't exist
```

`build_desktop.sh:146` switches to `createUpdaterArtifacts: true` whenever
`TAURI_SIGNING_PRIVATE_KEY` is present. That flag requires a `plugins.updater`
block in `tauri.conf.json`. There isn't one — **`G-18` shipped the feed ahead of
`G-19`, the plugin that consumes it.**

> ### The gate that made it safe is what kept it untested
>
> The branch is secret-gated, and the comment above it explains the design:
> *"with no key the path is skipped."* Correct, and it worked — which means the
> **ON branch had never executed once** in the history of this repository. Every
> CI run and every local build took the OFF branch. Setting the secret did not
> enable a feature; it enabled a build failure that had been sitting there since
> the day the script was written.
>
> Same shape as the vacuously-green guards this codebase keeps finding. The new
> instance: **a conditional whose true-branch has no coverage is not gated, it is
> unwritten** — and secret-gating hides that better than a feature flag does,
> because there is no flag anywhere to notice.

Resolution for tonight: drop the secret, build without updater artifacts. Nothing
is lost — there is no updater in the app to consume a feed. That is precisely
what R1 is, a manually-installed DMG. The key goes in a drawer until `G-19`.

**Consequence to carry forward:** with the secret absent, a `v*` tag will fail the
*"A tagged release must be updatable"* gate. That gate is correct — it refuses to
publish a release nobody can ever update to — but it means **`G-19` is now on the
critical path to a tagged release**, not merely to a working update button.

**What the failed run did prove.** The Developer ID certificate imported into a
clean CI keychain and the notarization credentials staged, both first try, on a
runner that had never seen either. The keychain tore itself down after the
failure. That is the half of the pipeline with the most ways to go wrong, and it
went right.

---

## An operational mistake worth recording

While checking whether the minisign key carried a passphrase, the agent ran
`head -1` on `~/.buster-claw/updater.key`, expecting a descriptive comment line.

**That file is a single line, and it is the key.** The private key was printed
into the session transcript, and the keypair had to be regenerated.

Three things worth keeping:

1. **The check that followed was also wrong, and more quietly.** The KDF field
   was read to conclude *"the key IS password-protected"* — but `rsign2` applies
   scrypt even to an empty password, so that field is identical either way. The
   conclusion was stated as a finding when it was a guess, and the operator acted
   on it. The actual failure had nothing to do with passphrases.
2. **Timing was the whole difference.** A leaked updater key is catastrophic
   *because the public key is compiled into shipped binaries and cannot be
   revoked.* Nothing had shipped: no plugin, no pubkey in the config, no release,
   zero installs. Installed base zero, rotation cost ninety seconds. The same
   mistake two releases later is unfixable.
3. **The generalisable rule:** before printing any part of a credential file to
   inspect it, establish its structure — a file whose entire content is one line
   makes `head -1` and `cat` the same command.

---

## The rehearsal, and what it cost to find three defects

Five dispatches, two cancelled before they could fail the same way twice, three
that reported. **Every one failed one step later than the last**, which is the
shape you want from a pipeline nobody has ever run.

| Run | Died at | Finding |
|---|---|---|
| `32615493428` | `Build DMG` | `plugins > updater doesn't exist` — the updater branch had never executed |
| `32616468652` | `Verify the advertised macOS floor` | both arches: `highest requirement is macOS 15.0 (inet_gethost)` |
| `32618232509` | `Verify signature, notarization, and staple` | both arches: *"the .dmg does not have a ticket stapled to it"* |
| **`32619301080`** | **— green —** | signed, notarized, stapled, booted, both architectures |

**All three would have shipped.** Not one is a CI quirk:

1. Setting the signing secret produces a **build failure**, not a feature.
2. The advertised floor was wrong, so the app would install, pass Gatekeeper,
   and **never start** on macOS 14.
3. The disk image was never notarized, so it would **fail on any downloader's
   machine without network** — the plane case stapling exists for.

The first two were caught by guards this repository already had. `G-16`'s floor
check and `G-5`'s boot smoke were both written *before* there was anything to
run them against, and both fired on first contact. The third was caught by the
III.J staple assertion, which had also never run.

> ### The lesson is about the guards, not the bugs
>
> Every one of these was found by an assertion written months ago by someone who
> could not yet test it. The defects are ordinary; **the guards catching them on
> the first real run is the actual result.**
>
> And the counter-lesson, filed in III.H and in SUPERMAP: `G-3` recorded *"both
> artifacts are stapled"* on 08-10, truthfully, because the operator ran
> `notarytool` and `stapler` by hand. **A manual step taken during a successful
> milestone gets written down as a property of the system.** SUPERMAP had been
> repeating it since — *"all eight III.J exit tests pass"* — and it was a claim
> about one afternoon. Corrected today. That is the second time this file has
> found that exact pattern, which is why it is now written as a rule rather than
> a fix.

---

## The artifact

**`Buster Claw_0.1.0_x64.dmg`** — 25.6 MB, `sha256
018f21fee3a5cfda6d895cab2f939744355615ad2b025dfa43ada5f1744011e2`.

```
stapler: The validate action worked!
spctl:   accepted
         source=Notarized Developer ID
         origin=Developer ID Application: Luke Hightower (KD977J8NF6)
```

**And an `aarch64` DMG, 25.9 MB — the first arm64 build in this project's
history.** It passed the same eight assertions, including `lipo -archs`
confirming the bundled VM is genuinely arm64 rather than a universal shell
wrapping an Intel ERTS. It still needs `G-4`, which needs a machine nobody here
has. **The build was never the blocker for arm64; the walk is.**

Neither is published. Both are `workflow_dispatch` artifacts, because a tagged
release is blocked by the `G-19` cycle below.

---

## What the evening actually changed

**Four commits, three of them fixes to things that were broken in production
terms:**

- `0e38592` — Req 0.5.17 → 0.7.2, tzdata and hackney gone, SSRF guard simplified
- `e0b7e3b` — the macOS floor is 15.0; **Buster Claw no longer supports macOS 14**
- `44e8bd6` — the DMG is notarized and stapled by the pipeline, not by a person
- `cb7da07` — the fresh-machine walk starts at the download (`DL-1`–`DL-5`)

**And the roadmap caught up with reality** (`e05378e`, `9f6aa15`): `G-16b` closed
at a number it did not propose, III.H re-measured (the 5½-hour notarization was
queue time — three runs today took minutes), `G-19` split into `G-19a`/`G-19b`,
`G-46` and `G-47` allocated, and **"The R1 path"** added to SUPERMAP as the
ordered list from artifact to stranger.

> ### The finding that outranks the three defects
>
> **`G-19` blocks every tagged release.** A `v*` tag fails closed without the
> minisign key; setting the key flips `build_desktop.sh` to
> `createUpdaterArtifacts`; that needs a `plugins.updater` block; that block is
> `G-19`. It was tracked as an R2 button — a product feature for later — and it
> is a prerequisite for shipping anything at all.
>
> Split into `G-19a` (a tag can build) and `G-19b` (the button) precisely because
> only the first blocks R1, and it may be an hour rather than a day. **The
> estimate is deliberately not given**: whether the config block alone satisfies
> the bundler is written down as the thing to establish first, with one
> `workflow_dispatch`, before anyone commits to a number.

---

## Where it stands

- `main` at `9f6aa15`, `mix precommit` green.
- **Step 1 of the R1 path is done** — a signed, notarized, stapled artifact
  exists on both architectures, produced end to end by CI for the first time.
- **Step 2 is next**: walk the Intel DMG on a machine that has never seen it.
  Start at `DL-1`. The copy downloaded with `gh run download` carries **no
  quarantine flag** and is therefore useless for `FM-2` — the trap written into
  the walk this afternoon, met the same evening.

**Unblocked and needing nobody:** `G-46` (make the trap loud), `G-19a` (make a
tag possible), `G-47` (get the Developer ID key out of iCloud).

**Still waiting on the world:** `G-4` needs an Apple Silicon Mac; busterclaw.lol
needs a separate repository to be edited, and still serves a dead download URL,
a stale command count, and a macOS floor that was nine versions wrong this
morning and is ten versions wrong tonight.
