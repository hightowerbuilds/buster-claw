# 07-18-26 — Playwright's funeral, and the automation build that replaced it

The densest shipping day on record: seven arcs, all pushed to main.

## 1. Browser fixes from the overnight review (`723f60c`, `dd97932`)
The Tauri 2 main-thread deadlock: sync commands run ON the main thread, so
`eval_with_result`'s completion (delivered by the main run loop) could never
arrive — every webview command timed out. Seven commands went `async fn`; the
threading contract is documented on `eval_with_result`/`capture_webview`.
And the live-render upgrade only replaces a thin HTTP result when it actually
yields more text (`pick_thicker` — app.element.io's loading screen no longer
wins).

## 2. Roadmap consolidation (`a0e1958`)
Archived the executed code-quality roadmap, the verified voicemail-cost
roadmap, and the redundant customer first-look review (all as dated archive
files with stamps). Ported the two live decisions out before archiving.
Annotated five resolved browser findings in the critical review. Landed the
operator's `phone-maps/` regroup.

## 3. Supabase security chores (`c87ed4d`)
Old shared project (`gbnizxzurmbzeelacztr`): `voice` function deleted + both
Twilio secrets unset — the trial number is dead, and a Twilio credential no
longer lives in a project full of Stripe keys. BusterClaw project DB password
rotated to a random 32-char value (in the operator's password manager, nowhere
else). LEFTOVERS emptied of both items.

## 4. The paid number recorded (`dc03401`)
+1 (360) 364-6763 (`+13603646763`) — now in `phone-maps/BUSTERPHONE_ROADMAP.md`
and `supabase/SETUP.md`; stale "trial number" claims fixed in README/GTM;
QA findings #29/#50/#51 annotated resolved.

## 5. `auth_status` decoy column dropped (`de1297f`)
The grep confirmed it: written only as its `"unverified"` default, read by
nothing (the provenance gate is `trusted`), and lying on PIN-verified
voicemail rows. Dropped via migration — the same treatment as the
`telephony_contacts.trusted` decoy (ed048c1). Browser-walk leftover checked
off by operator. LEFTOVERS is now EMPTY.

## 6. Playwright deleted; the automation roadmap built same-day
Operator decisions: **lose Playwright, build our own agent web automation on
the native WKWebView** (app-E2E self-testing explicitly declined).

- **Prune** (`f6e21b8`): sidecar module + 17MB priv tree + config + tests +
  docs, −890 lines. `Browser.fetch/2` = HTTP + live-render upgrade only.
- **Round 1 — primitives** (`46ba418`, multi-agent: map workflow → contract →
  Rust ∥ Elixir builders → integrator): `browser_wait` (in-Rust 250ms condition
  polling — navigation/selector/visible/text — with the bridge timeout riding
  above the budget), selector/text targeting for click/fill (act-time
  re-resolution + scroll-into-view; index path byte-compatible),
  `browser_extract`, `browser_assert` (composed; no new desktop surface).
  Both new Tauri commands ACL-registered at all three points.
- **Round 2 — flows** (`fd7abd1`, inline): `FlowRunner` + `browser_flow` —
  1–25 declarative steps, halt-at-first-failure, per-step report, best-effort
  failure screenshot, fill values length-redacted on the flow audit event,
  policy checked once at the choke point.
- **Round 3 — saved checks** (`777bcaa`, inline): `Browser.Checks` —
  skills-style markdown files in `<workspace>/checks/` (frontmatter definition
  + append-only `## Runs` history), `browser_check_save/list/run`. "Test my
  signup flow" now exists end to end. Catalog at 157.
- **Round 4 — review** (inline): read all agent-written Rust. Clean —
  injection-tight, the navigation re-confirm and fixed-element visibility
  heuristics are genuinely good. Two footnotes recorded in the roadmap.

Token lesson learned live: the multi-agent fan-out (map + round 1) cost ~10×
what inline rounds 2–4 did; the hybrid — agents for the parallelizable
contract build, inline for everything composable — is the right default.

## 7. The cold-boot excavation (no commit — environment)
The smoke test found "the browser is broken" — it wasn't the new code. The
dev Phoenix had been running since **Fri 11:53 AM** (dev.sh reuses a healthy
server), with three feature commits hot-reloaded onto it, plus: an orphaned
Playwright sidecar node from the deleted tree, **two packaged-app BEAMs from
June 14/18 still running out of /Applications** (the single-instance hazard,
observed in the wild), and — the real boot-blocker — **the orphaned
`deps/dns_cluster` dir kept feeding Mix's dep cache**, so every regenerated
app manifest still demanded `dns_cluster` at boot (Thursday's deletion removed
it from mix.exs but not from deps/). Killed all six stragglers, pruned the
orphan from `deps/` + both `_build` envs, regenerated manifests. Cold boot
clean; browser confirmed working by operator.

**Lesson for the wrap-up file:** after deleting a dep, prune `deps/<name>` and
`_build/*/lib/<name>` too — and any "it broke after my change" report deserves
a `ps -eo lstart` before a `git diff`.

## 8. The broke-but-building distribution sprint (evening)

Operator constraint: no $99 until payday. Turned out the fee gates exactly two
steps (enrollment, sign+notarize); everything else was free engineering:

- **Automation roadmap archived** the same day it shipped (`7f6020e`) — a
  first for that folder; its three open operator calls ported to LEFTOVERS.
- **Bundle trim at the root cause** (`471c467`): Dialyzer PLT caches moved
  out of `priv/` (everything in priv/ ships), gitignore/CI cache paths
  updated. With yesterday's sidecar deletion, the bundle dropped from the
  88MB era to a **26MB DMG / 64MB app**.
- **`build_desktop.sh` run end-to-end for the first time ever** — the
  roadmap predicted surprises; there were none. Ran clean twice.
- **The bundle-ID one-way door closed** (`471c467`): operator ratified
  `lol.busterclaw.desktop` (and with it R5 — busterclaw.lol is the name).
  Keychain + Application Support use literal names, so nothing was orphaned;
  only stale webview caches remain under the old id. Verified in the built
  Info.plist.
- **Two-arch CI shipped** (`97eff60`): `release-desktop.yml` — the Livebook
  pattern verbatim (macos-15 aarch64 + macos-15-intel x86_64, native ERTS
  per runner, no lipo ever), unsigned DMG artifacts, the entire payday
  signing path documented at a `TODO(payday)` marker gated on the cert
  secret. Free minutes (public repo). Also fixed ci.yml's dialyzer cache
  for the `_plts` move.
- **The first arm64 build of Buster Claw ever attempted** was in flight at
  write time (run 29661337583, both arches) — result recorded below when it
  lands.

## State at close
- Tests: 1,133, zero failures; cargo 8/8; catalog 157 commands.
- LEFTOVERS: three items, all operator-only (primitive walk, wait-tier +
  flow-audit ratifications, password-manager bookkeeping).
- Distribution: steps 2–5 + 7 of the roadmap done for $0; blocked list is
  exactly {enrollment, sign+notarize} = payday.
- Next: payday → cert into CI secrets; meanwhile the free GTM queue
  (busterclaw.lol site + privacy policy, Google verification paperwork) is
  the remaining no-cost critical path.
