# 08-14-26 — What the tests couldn't see, and what the maps no longer knew

A whole-codebase review, five agents running at once, two integrations deleted,
and eighteen commits. But the two things worth remembering are failures rather
than shipments: **four separate places where the suite could not see the bug it
was supposed to guard**, and **three times I read a stale record as a statement
about the present** — twice sending real work after something that no longer
existed.

| Shipped | Commit |
|---|---|
| Whole-codebase review, filed by section into four LEFTOVERS maps | `4a77c98` |
| **Gmail attachments fenced to the workspace** + MIME header sanitizing | `1728e64` |
| `chat.ex`: a false `:steered` claim and a wrong-namespace model resolution | `20a36a9` |
| Two dead Trading hooks deleted; hook guard made bidirectional | `577085e` |
| Five parallel refactors — gmail, cutup, integrations, web, calendar | `2ac945d`, `22de168`, `a23c702`, `1eee2f8`, `c407ab4` |
| **The core layer enters the size gate** — 65k lines, previously uncapped | `c407ab4` |
| precommit green again after 25 commits red | `a02cebe` |
| Sentry and Umami removed; GitHub is the only adapter | `14afd0b`, `3bab4fd` |
| Image-shader Phase 3 landed; the migration annex extracted | `4c664cf`, `ceb7943` |
| Map corrections: Studio → Mix, image shaders, V.4b | `61ce5e2`, `d3e8832`, `e98db6b` |

---

## The review, and the one finding with teeth

Six reviewers over six clusters, each briefed with the prior rulings so it argued
*with* the history rather than rediscovering it. Twenty-one ranked findings; the
top four landed the same day.

The sharp one: **`google/gmail.ex` attached any absolute path to outbound email
with no fence at all**, while every peer file-reaching surface in the app fences
through the workspace. Email is the exfiltration channel; being the exception
there is the worst place to be it.

> The proof was better than the fix. Removing the `within?` check made a test
> fail on `flunk()` rather than an assertion — the `/tmp` file containing
> *"private key material"* was read, base64'd into a MIME part, and handed to the
> HTTP layer. **The exfiltration itself, observed.**

Two structural conclusions came out of the review and both were acted on: the
size gate covered **no** core, JS or Rust file — 65,003 lines of core with not
one capped — and `commands/sound.ex` at 2,514 lines is the single file where the
08-08 "commands/ is correct as it stands" ruling no longer holds. Its own
sibling's moduledoc concedes it: `SoundCapture` was split out *"to stop the Sound
module, already the largest file in lib/, from absorbing a second concern."*

---

## Break the guard, four times, four gaps

Five agents ran in parallel on disjoint file scopes with their own
`MIX_TEST_PARTITION` lanes. Every one was told to reintroduce the defect and
watch a test fail. **Three of five found the suite could not see it**, and a
fourth found a hole older than the refactor:

- **`features_test.exs` accepted a weakened traversal gate.** Its assertion was
  `reason in [:invalid_source, :unsafe_source]`, so the traversal names fell
  through to the looser reason and passed. Features' path-safety check really
  was weaker than Index's — the two were byte-identical copies, and only one was
  properly tested.
- **The webhook-failure path recorded `last_status` with nothing asserting it.**
  A deliberately wrong status passed all 30 tests, because the webhook tests
  assert the run and never reload the integration.
- **Nothing asserted the browser bridge payload.** A dropped click/fill target
  was invisible: the return value and the Sentinel audit event both look
  perfect while the desktop receives nothing. Two tests use `index: 0` and both
  discard the payload.
- **The hook registry test was one-directional by design**, so 436 lines of
  deleted-Trading-stack hooks shipped in `app.js` on every page load for five
  days. It checks both directions now — verified by injection, failing on
  exactly those two hooks before the deletion.

> A test written in the same sitting as its code inherits its blind spot. That
> was already the rule here. What today added: **an assertion loose enough to
> accept two answers is an assertion that cannot detect the wrong one.**

---

## Three stale records, read as current fact

The day's real failure mode, and it was mine three times.

1. **A `head -10` truncated a verifying grep** and I read the truncation as the
   whole answer — so the Sentry removal missed the README, the Supermap row, and
   the privacy claim in both `TRUST_AND_SUPPORT` and `APPLE` that read *"the only
   Sentry code is the integration that reads the user's own project."*
2. **A 05-25 summary was cited as present tense.** It named three hand-rolled
   `secure_compare/2` copies, so I reported `webhooks.ex` as holding the last
   one and we set out to fix it. **That file was deleted 2026-06-14**, three
   weeks after the summary was written. There was no work to do.
3. **V.4b was recommended as unbuilt and shipped weeks ago.** `Cutup.Gaps` cites
   *"STUDIO_ROADMAP V.4b"* in its own moduledoc.

> Summaries under `MM-DD-YY-Summary/` are a record of what was true on their
> date, and are deliberately never edited — which is exactly what makes citing
> one as current fact a mistake. **Check the tree, then the map; never the log.**
> Written into `LEFTOVERS_PLATFORM` next to the finding it spoiled.

---

## Maps that disagreed with themselves

Three, and each was a document contradicting its own body rather than the code:

- **`IMAGE_SHADER`'s header said "Phase 3 next"** directly above a Phase 3
  section marked SHIPPED.
- **`STUDIO` V.4b's section said "and built by neither"** while the verb table
  further down the same document listed `sound_gaps` as *"V.4b's report."*
- **The Supermap's Studio → Mix row cited a leftover about "no `sound_*` CLI
  verbs"** that no longer exists. The catalog carries 29 of them.

The Supermap's third rule is *status has one home, and this is it.* All three
breaks were inside a single file, which is the failure mode that rule cannot
catch on its own.

---

## Two integrations deleted, and what the scaffolding costs

Sentry (601 lines) and Umami (404) removed on the operator's call — ideated,
never essential, and Sentry was never a dependency at all. Nothing ever reported
errors *to* Sentry; it was an adapter that polled the issues API into Library
snapshots.

**GitHub is now the only adapter**, and the `Service` behaviour, `Snapshot`
renderer, whitelist and picker list were kept rather than collapsed into it. The
picker keeps its list shape for a specific reason: it, the `@service_types`
whitelist, and `adapter_for/1` are **three lists that must agree** — the
rail-and-guard shape this repo has been bitten by three times. Collapsing any of
them to a constant hides the next disagreement instead of preventing it.

Free side effect: two of the three `secure_compare/2` copies died today, one
with the Sentry adapter and one swapped for `Plug.Crypto`'s.

---

## Smaller things that mattered

**`mix precommit` had been red on `main` for 25 commits** — five credo findings
in two test files nobody had touched since. A red shared gate means the next
person's precommit fails for reasons that aren't theirs, which is how a gate
stops being run at all.

One of those five did **not** take credo's advice. Swapping `String.to_atom` for
`to_existing_atom` in the sentinel category test turned it red: a whitelisted
category has no atom anywhere in the compiled tree, which is precisely the case
the catch-all exists for. Taking the suggestion would have converted an
assertion into a raise and quietly narrowed what the test proved. It carries a
disable comment with the measurement.

**The `appearance.ex` migration extraction was not the "textbook" one the review
called it.** A straight `defdelegate` closes `Appearance ↔ Appearance.Migration`
— a third dependency cycle, which `check_cycles.sh` fails on by design — and
rebuilding the key formats inside `Migration` puts two copies of a Settings key
string in the tree. So `ensure/0` stayed as the orchestrator and passes the key
names down. The ordering constraint now spans a module boundary and is stated on
both sides; reversing it fails `appearance_test.exs:419` with the homepage image
in the wrong slot.

---

## Where Studio → Voice actually stands

V.4b turned out to be shipped, so the useful output was running it against the
live corpus rather than building it:

| | |
|---|---:|
| indexed sources | 10 |
| distinct words | **237** |
| total takes | 655 |
| cuttable (≥2 takes) | 93 |
| single-take, quotable only | **144** |
| origins | `aligned` 655 · everything else **0** |

Three things fall out. The "144 of 237" this roadmap leads with **comes from this
report**. **Every take is `aligned`** — a proportional guess capped at 0.9, with
not one `manual` or `recognizer` take in the corpus, so quality is a boundary
problem (VI.2) before it is a recording problem. And the curve is top-heavy
enough (`to` 35, `the` 29, then most cuttable words at exactly 2) that reading
more of the same material buys almost nothing.

> **The half that shipped is the wrong half.** V.4a — the `getUserMedia` spike
> that can invalidate the entire design — has not been attempted, because it
> needs a signed build and a permission dialog while V.4b needed neither. An
> agent did the part an agent could do; that is not the order this section
> argues for.

---

## Where the build is, honestly

Eighteen commits, and **none of them advanced any of the five items the Supermap
calls the build.** Three of those five are blocked on the operator or on
hardware — the Clinch tunnel needs two machines, Apple needs an Apple Silicon
Mac, Studio → Voice needs a person at a microphone — and BusterPhone needs a
Twilio upgrade. The review was the only thing on the list an agent could push
alone, which is why the day went where it went. Worth naming rather than
discovering again next week.

**Gates at close:** precommit exit 0 — 3,908 tests, credo clean, 2 accepted
cycles, file-size inventory holds, bun and Rust suites green.
