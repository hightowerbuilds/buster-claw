# iMessage feasibility — first implementation evidence

**2026-09-19 · Phase 0 PARTIAL; local desktop build complete, desktop permission/send gate remains open.**

Scope: iMessage replaces the text channel; Twilio keeps voicemail. No live
Twilio/Supabase settings, text routes, or voicemail code were changed in this
increment. Initially the adapter was downloaded only into ignored
`tmp/imessage-spike/`. The subsequent desktop build now bundles it as described
below; no global helper installation or live channel cutover was performed.

## Candidate pinned

- Upstream: <https://github.com/openclaw/imsg>
- Release: `v0.15.6`, published 2026-09-18.
- Annotated tag: `0d485497383672f27498d4f669bb94601eff6b6f`.
- Source commit: `9cbb8ab62071287c41e4d0dee5ccb8765f0b664d`.
- Asset: `imsg-macos.zip` from that release.
- Published and locally measured SHA-256:
  `a91bf50a568878b4aca68391dcd24368c687261bf6c0c252af82bd8b2eb796b1`.
- Executable has Intel and Apple Silicon slices (`file` inspection).
- `codesign --verify --strict` succeeds outside the execution sandbox. The
  sandboxed invocation reported an invalid signature; the unrestricted check
  resolved that discrepancy. This is signature verification, not a fresh-machine
  Gatekeeper/notarization acceptance walk.
- `imsg --version` returns `0.15.6`; `imsg rpc --help` supports the documented
  stdio RPC and optional database argument.
- The optional injected `imsg-bridge-helper.dylib` was deliberately not extracted.
  Ordinary status runs without it. No private-framework operation was invoked.

The pinned `LICENSE` was read through GitHub: MIT, copyright 2026 Peter
Steinberger; redistribution requires retaining its notice. Upstream documents
macOS 14+ support; the app currently declares a 15.0 floor in `tauri.conf.json`,
so the documented minimum does not require raising it. The subsequent local
build includes pinned dependency notices; actual release-target compatibility
and signed distribution acceptance still need verification.

## What ran

Host: Intel (`x86_64`), macOS 26.6.2, build 25G83. The new Mix task ran from
Tractor Beam's command environment, outside its execution sandbox:

```sh
mix messages.probe --binary tmp/imessage-spike/imsg
```

The task compiles/loads configuration but does not start the Phoenix application,
the Repo, or background pollers. It starts a temporary owned adapter connection,
requests status, prints an allowlisted result, and closes the connection.

Observed result:

```json
{
  "version": "0.15.6",
  "state": "database_unavailable",
  "adapter": "imsg",
  "protocol_version": 1,
  "read_ready": false,
  "send_ready": false,
  "send_state": "not_tested"
}
```

This verifies launch, framing, request/response correlation, version/protocol
validation, and degraded readiness against the real release. It does **not**
prove which macOS grant is missing: absent database, inaccessible database, and
other database-open failures intentionally share the redacted unavailable state.
The default Messages database exists on this Mac (file metadata checked), so
absence is ruled out for this run; permission or another open error remains.
No conversation content was requested, no Apple account was verified, and no
message was sent. Full Disk Access was not changed.

## Implemented foundation

- `BusterClaw.Messages.probe/1`: explicit executable override or existing
  `ShellPath` discovery, no app-boot side effects, temporary connection cleanup.
- `Messages.Connection`: lazy child process, structured arguments, bounded
  framing and pending requests, correlation, deadlines, explicit-request retry
  with backoff, redacted failures, and port cleanup. Only status is exposed.
- `Messages.Status`: accepts the pinned release and protocol, checks ordinary
  read capabilities, discards paths/diagnostics/private-bridge details, and never
  promotes database readability into permission to send or account availability.
- `mix messages.probe`: repeatable developer diagnostic, optionally against a
  synthetic database. This is not a new app command or user-facing setup flow.
- Automated fixtures cover readiness, redaction, protocol mismatch, fragmented
  and out-of-order replies, invalid output, size/pending limits, timeouts,
  child failure/reconnect, and shutdown. They use no real Messages database.

## Open acceptance work

Validation for this increment: `MIX_TEST_PARTITION=imessage ERL_FLAGS='+S 2:2'
mix precommit` exited 0. All gates passed: 3,509 Elixir tests (22 excluded),
362 JavaScript tests, Rust format/Clippy/tests (52 tests), dependency checks,
Credo, formatting, dependency-cycle and file-size checks. The reduced scheduler
count kept async test concurrency compatible with the single-connection SQLite
sandbox; the isolated database avoided sharing another run's test file. The
new Messages suites contain 16 tests. Full output is in the ignored local file
`tmp/imessage-spike/precommit.log`.

1. Run the About-page check from the new desktop window. The local app now
   includes the adapter and UI; the release-eval test below verifies packaging
   but does not reproduce Tauri's launch/permission attribution. A signed
   distribution build still needs its own acceptance walk.
2. Establish the responsible process and the operator-granted Full Disk Access
   setup. Test denial, grant, revocation, and recovery with a synthetic or
   operator-selected conversation. Do not claim a specific permission cause
   solely from the redacted result above.
3. Agree on the text account/address. It is separate from the retained Twilio
   voicemail number. Confirm the self-message/remote-task identity behavior.
4. Prepare one exact recipient/body for an operator-authorized test send and
   test Automation permission in the packaged chain. No send path exists in
   this increment, and an accessible database would not prove it works.
5. Exercise sleep/wake, source replacement/WAL replay, account unavailable,
   unsupported macOS, and a fresh install. Confirm helper ownership for signed
   distribution from those measurements before expanding into Phone Texts.

The release floor, automatic reply policy, and Twilio SMS cutover remain as
specified in [the roadmap](../roadmaps/integrations/IMESSAGE_ROADMAP.md).

## Desktop build increment

Built with `scripts/build_desktop.sh`, exit 0:

- App: `desktop/tauri/target/release/bundle/macos/Buster Claw.app`.
- DMG: `desktop/tauri/target/release/bundle/dmg/Buster Claw_0.1.1_x64.dmg`
  (approximately 41 MB).
- Local unsigned Intel build; no distribution signing or notarization credentials
  were configured. The adapter itself retains its verified upstream signature.
- `scripts/stage_messages_adapter.sh` verifies the pinned archive and stages
  only `imsg` plus its two Swift resource bundles under `priv/messages/`.
  License notices ship in `priv/third_party/imsg/`. The private injected helper
  is excluded. The desktop build asserts the final app contains the executable.
- `Messages.probe/1` prefers the app's bundled adapter after an explicit override,
  before consulting the operator's PATH. A byte comparison confirmed the final
  bundle's adapter matches the verified staged executable.
- Settings → Configuration → About now provides **Check iMessage access**. It
  probes asynchronously only on click, displays redacted readiness, and does not
  fetch conversations or send. Missing-adapter and ready responses are covered
  by LiveView tests; corrupt-archive rejection is covered by a script test.

`scripts/smoke_release_boot.sh` passed against the final app: isolated temporary
database/workspace, healthy Phoenix, command catalog, bad-token rejection, and
the first-run setup page. No installed app or production data was replaced.

The final bundle's release executable was also run in CLI-eval mode. It resolved
`.../Buster Claw.app/Contents/Resources/release/lib/buster_claw-0.1.1/priv/messages/imsg`
and returned version `0.15.6`, `database_unavailable`, and `send_state: not_tested`.
That is evidence the packaged dependency runs; it is not evidence of Full Disk
Access from a Tauri-launched window. Open the built app and use the About-page
check for that next measurement.

Local logs: `tmp/imessage-spike/desktop-build.log`, `packaged-smoke.log`, and
`packaging-precommit.log` in that same directory.

Packaging/UI validation: the full isolated `mix precommit` run exited 0 with
3,513 Elixir tests (22 excluded), 362 JavaScript tests, and 52 Rust tests; all
other precommit gates passed. The initial LiveView fixture used the default
100 ms async wait, which was too short for a child process; the test now waits
up to two seconds using `render_async/2`, and both targeted and full runs pass.
