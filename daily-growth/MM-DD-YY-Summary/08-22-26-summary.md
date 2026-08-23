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

`DL-3` carries `G-24`'s number into the walk — the page must say **14.0**, not
`10.15` — and is deliberately worded as *quote what the page told you* rather
than *check the number is right*, because a reader who already knows the answer
will find it whether or not a stranger would.

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

## Where it stands at the time of writing

- `main` at `cb7da07`, `mix precommit` green.
- Run **`32616468652`** in flight — both architectures, signing and notarization
  enabled, updater artifacts off. First time this pipeline has ever built
  `aarch64` or notarized anything from CI.
- If green: download the `x86_64` DMG artifact and walk `FRESH_MACHINE_WALK`,
  starting at `DL-1`, extracting in Finder rather than `unzip`.

**Still open, unchanged by tonight:**

- busterclaw.lol serves a dead download URL and a stale command count; separate
  repo, nothing here can reach it.
- `G-19` — now blocking tagged releases, not just the update button.
- The Developer ID private key and its plaintext password live in
  `~/Desktop/apple-dev-skills/`, which is iCloud-synced.
