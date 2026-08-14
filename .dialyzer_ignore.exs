# Dialyzer baseline — 2026-08-02, restructured 2026-08-13.
#
# ## What changed on 08-13, and why
#
# Section 1 used to be a hand-written list of 76 files whose `unmatched_return`
# findings were accepted. **That list rotted the moment anyone added a file.**
# By 08-13 the gate was red with 67 findings, 51 of them `unmatched_return` in
# files written after 08-02 — `notes.ex`, `pockets/`, `terminal_theme.ex`,
# `chat_skin.ex`, `clinch.ex`, the `live/status/` split. None were problems. The
# gate was not catching new defects; it was catching **new files**, and it had
# been red long enough that nobody read it.
#
# A gate that reports 67 things and confirms none of them teaches people to
# ignore it. So section 1 is now a **rule** rather than a list:
#
#   `unmatched_return` is ignored everywhere EXCEPT the gated paths below.
#
# A new file outside those paths no longer breaks the build. A new discarded
# return *inside* them still does — which is the only place the finding ever
# carried signal.
#
# ## Why these paths and not others
#
# The question is not "is this code important" — it is **"could a silently
# discarded return lose a security record or persisted data?"** Everywhere else,
# an unmatched return is a broadcast, a telemetry call, a cache warm or a
# `File.rm` on a temp path, and demanding `_ =` on all of them is a 232-site
# no-behaviour-change sweep with a green suite the whole way — the exact shape
# that has bitten this repo before.
#
# **This gate has already paid for itself retroactively.** Two Clinch revocation
# categories once recorded nothing while the whole suite stayed green, because
# `Sentinel.Event` whitelists categories and `observe/4` is best-effort. The
# discarded return was the tell. `SentinelCategoryTest` covers that specific
# case now; this covers the shape of it.
#
# Adding a path here is cheap and good. Removing one needs a reason in writing.
#
# **One limitation, found by trying to break this gate on 08-13.** Dialyzer does
# not analyse unreachable code, so a discarded return inside an uncalled private
# function does NOT trip the gate — the first attempt to prove this thing works
# was a false negative for exactly that reason. It fires on reachable code, which
# is the code that can lose something. Do not read a green gate as "no discarded
# returns exist in these paths".
gated = [
  # Credentials. The audit trail is the only record that a credential was used
  # or revoked, and a dropped write is invisible by construction.
  "lib/buster_claw/clinch.ex",
  "lib/buster_claw/clinch/",

  # The audit layer itself. If Sentinel drops a return, nothing else will notice.
  "lib/buster_claw/sentinel.ex",
  "lib/buster_claw/sentinel/",

  # Encryption at rest.
  "lib/buster_claw/vault.ex",

  # Persist-then-ack. A dropped return here is a message acknowledged and lost.
  "lib/buster_claw/telephony/",

  # The operator's Markdown vault — atomic writes, conflict detection.
  "lib/buster_claw/notes.ex",
  "lib/buster_claw/notes/",

  # The tier system, and the token the tiers are read from.
  "lib/buster_claw/policy_engine.ex",
  "lib/buster_claw/api_token.ex"
]

# Everything NOT gated has its `unmatched_return` findings accepted. Computed
# from the tree rather than typed out, so adding a file cannot rot this.
#
# `BusterClaw.DialyzerBaselineTest` asserts the two things that would quietly
# undo it: that this rejection actually removes files (a bad prefix would
# silently gate nothing), and that no gated path appears in the accepted list.
accepted_unmatched_return =
  "lib/**/*.ex"
  |> Path.wildcard()
  |> Enum.reject(fn file -> Enum.any?(gated, &String.starts_with?(file, &1)) end)
  |> Enum.map(&{&1, :unmatched_return})

# ---------------------------------------------------------------------------
# 2. Everything that is not `unmatched_return` — 16 entries on 08-02, 9 now.
# ---------------------------------------------------------------------------
#
# Entries are `{file, warning_type}` rather than line-pinned on purpose: line
# numbers churn under refactoring, and a filter that silently stops matching
# produces a build failure that teaches nobody anything.
#
# The rule for changing this section: entries come OUT as findings are fixed.
# The only reason to add one is a deliberate, commented decision.
#
# All four confirmed defects diagnosed on 08-02 are now FIXED, and their
# entries came out of this file the same day. That is the whole difference
# between a baseline and a suppression, so the record stays:
#
#   * ~~cli.ex :call~~ — `System.trap_signal(:sigint, ...)` raised on every
#     `on-duty` and the rescue swallowed it, so Ctrl-C left the shift running
#     server-side while the banner said otherwise. SIGINT is reserved by the
#     BEAM's break handler and cannot be trapped at all; the fix was to trap
#     SIGTERM/SIGHUP instead and stop claiming Ctrl-C stands down.
#     `{cli.ex, :no_return}` below is still required and honest:
#     `stand_down/2` and its closure end in `System.halt/1`, and so does
#     `die/2`.
#   * ~~cli.ex :pattern_match~~ — the `{:failed_connect, _}` clause was
#     httpc-era shape left behind by the move to Req, so the most common
#     failure the CLI has (the app isn't running) never rendered its one
#     useful line. Now matches `%Req.TransportError{reason: :econnrefused}`,
#     verified against a real refused connection.
#   * ~~finance_api_controller.ex :pattern_match~~ — `:missing_symbol` was
#     unreachable: `lookup/2` answers an empty query before any section runs.
#     Clause deleted; the atom is still live on the command surface, which
#     does not come through that controller.
#   * ~~integrations/service.ex :unknown_type~~ — `Integration.t/0` did not
#     exist, so three callback specs checked nothing. Ecto does not generate
#     it; the schema declares it now.
#
# ALL TWELVE DIAGNOSED 08-02 (second pass). Three were dead code and are now
# deleted from source — their entries are pruned (the browser.ex :pattern_match entry remains LIVE —
# its :1 macro-artifact finding shares the {file, type} key with the deleted :148):
#
#   * browser_control.ex :pattern_match — probe_steps' else carried an
#     {:error, :launch, _} clause, but run_probe launches and handles that
#     error itself before calling probe_steps. Leftover from before the split.
#   * browser.ex :pattern_match (the :148 half) — a tuple-list header_value
#     clause for pre-0.5 Req; Req now always normalizes headers to a map.
#   * google/client.ex :pattern_match_cov — retry_after_seconds' fallback
#     returned nil for a non-response, which would silently SKIP the rate-limit
#     backoff; the only caller passes the response it just received, so an
#     upstream bug should crash loudly instead.
#
# The other NINE were deliberate. EIGHT still are and stay, each for a stated
# reason below; the ninth (trading_live.ex :pattern_match_cov) left with its
# file when the trading stack was deleted on 08-08 — a deletion is the most
# complete kind of fix, and its entry came out the same way a fixed one does.
#
#   * appearance.ex, terminal_commands.ex, browser_home_controller.ex —
#     corrupt-persisted-data degradation. Each catch-all turns a corrupt
#     stored value (background mode, catalog field, bookmark tags) into a
#     harmless default instead of a crash, matching each module's documented
#     posture. Dialyzer sees only today's callers, not tomorrow's bad row.
#   * integrations/github.ex — secure_compare's non-binary fallback returns
#     false: FAIL-CLOSED signature verification. Never delete a fail-closed
#     clause in webhook auth to please a linter.
#   * system_browser.ex — unknown :os.type() returns {:error, :unsupported_os}
#     rather than a FunctionClauseError in a function that shells out.
#   * browser.ex :pattern_match (the :1 half) — a line-1-attributed macro
#     artifact: `is_binary(html) and ...` inside thin_page?, where Dialyzer
#     proves html is currently always binary. The guard is defense against a
#     malformed page map; the finding is noise from the `and` expansion.
#   * sound_studio_component.ex — a LiveView catch-all. A new error atom from
#     StudioMix renders a generic message instead of crashing the whole page.
#   * cli.ex :no_return — simply true: stand_down/2, its trap closure, and
#     die/2 all end in System.halt/1.
#
# ---------------------------------------------------------------------------
# 3. Findings surveyed 08-13 and left standing, with the reasoning
# ---------------------------------------------------------------------------
#
# The 08-13 run had 16 non-`unmatched_return` findings. Twelve were traced.
# **None was a defect** — they are defensive clauses whose defensiveness
# Dialyzer has now disproved, which is a different thing from a bug:
#
#   * chat_attachments.ex (5) — `normalize_stage/1` and friends accept both the
#     bare-value and tagged-tuple conventions because `Agent.Attachment` is
#     types-only and never pinned the store's return shapes. The comment above
#     them names this as the seam to tighten once the store lands, so the
#     clauses are deliberate-for-now rather than dead.
#   * commands/terminal_theme.ex (4) — `paint_refusal/1` and `format_ratio/1`
#     carry fallbacks for reason and ratio types that provably never arrive.
#   * codex_app_server.ex (2) — `request/3` really does return
#     `{:error, :app_server_down, state}`, but only for `%{port: nil}`, and
#     `ensure_connected/1` runs first and guarantees a live port.
#   * commands/sound.ex :no_return — `import_index/4` is reported as unable to
#     return. **It returns fine**: `sound_test.exs` round-trips it and asserts
#     `{:ok, imported}`. Three hypotheses were checked and all were wrong —
#     `index.ex`'s `origin/1` is total, `build/3`'s map satisfies
#     `Types.index()` including the nilable fields, and `error()` already
#     includes `:file.posix()`. It is a type-chain artifact, not a crash, and
#     chasing the exact inference path costs more than it is worth.
#
#   * commands/orchestration.ex — `write_backend/3`'s generic `{:error, reason}`
#     arm, after the three specific ones. Same corrupt/unexpected-shape
#     degradation as the section 2 entries.
#   * model_policy.ex — `is_nil(backend)` in `put_backend/2`. The docstring
#     documents `nil` as "clears back to auto-detection" and **no current caller
#     passes nil**, so Dialyzer proves the guard dead. The function is public;
#     the clause is API completeness, not dead code.
#   * pockets_panel.ex — `write_error_text/1`'s catch-all, so a new error atom
#     renders a sentence instead of crashing the panel.
#   * commands/sound.ex :pattern_match_cov — `under_library/1`'s non-binary
#     fallback. A path-containment function's fail-closed clause; the same rule
#     as the github.ex entry above applies — do not delete one to please a
#     linter.
#
# They are listed below so the gate can be GREEN and therefore mean something.
# A baseline that stays red blocks nothing and trains people to skip the output,
# which is precisely the state this restructure found. Each is still worth
# deleting when someone is in the file anyway.
other_findings = [
  # Surveyed 08-13 — see the notes above. None is a defect.
  {"lib/buster_claw_web/live/status/chat_attachments.ex", :pattern_match_cov},
  {"lib/buster_claw_web/live/status/chat_attachments.ex", :guard_fail},
  {"lib/buster_claw_web/live/status/chat_attachments.ex", :pattern_match},
  {"lib/buster_claw/commands/terminal_theme.ex", :guard_fail},
  {"lib/buster_claw/commands/terminal_theme.ex", :pattern_match_cov},
  {"lib/buster_claw/agent/codex_app_server.ex", :pattern_match},
  {"lib/buster_claw/commands/sound.ex", :no_return},
  {"lib/buster_claw/commands/sound.ex", :pattern_match_cov},
  {"lib/buster_claw/commands/orchestration.ex", :pattern_match_cov},
  {"lib/buster_claw/model_policy.ex", :guard_fail},
  {"lib/buster_claw_web/components/pockets_panel.ex", :pattern_match_cov},

  # Surveyed 08-02 — see the notes above.
  {"lib/buster_claw/appearance.ex", :pattern_match_cov},
  {"lib/buster_claw/browser.ex", :pattern_match_cov},
  {"lib/buster_claw/browser.ex", :pattern_match},
  {"lib/buster_claw/cli.ex", :no_return},
  {"lib/buster_claw/integrations/github.ex", :pattern_match_cov},
  {"lib/buster_claw/system_browser.ex", :pattern_match_cov},
  {"lib/buster_claw/terminal_commands.ex", :pattern_match_cov},
  {"lib/buster_claw_web/controllers/browser_home_controller.ex", :pattern_match},
  {"lib/buster_claw_web/live/sound_studio_component.ex", :pattern_match_cov}
]

accepted_unmatched_return ++ other_findings
