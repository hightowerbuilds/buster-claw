# Dialyzer baseline — 2026-08-02.
#
# This file exists so the Dialyzer job can GATE merges today rather than after a
# burn-down that would never finish. Every finding below was already present the
# moment the gate was switched on. Anything NEW fails the build.
#
# Entries are `{file, warning_type}` rather than line-pinned on purpose: line
# numbers churn under refactoring, and a filter that silently stops matching
# produces a build failure that teaches nobody anything. The trade is that a
# second finding of the SAME type in an already-listed file slips through — an
# acceptable price for section 1, and the reason section 2 should shrink to
# nothing.
#
# The rule for changing this file: entries come OUT as findings are fixed. The
# only reason to add one is a deliberate, commented decision.
#
# ---------------------------------------------------------------------------
# 1. Accepted noise — :unmatched_return (232 of the original 252 findings)
# ---------------------------------------------------------------------------
#
# Deliberately ignored best-effort calls: broadcasts, telemetry, cache warms,
# File.rm on a temp path. Rewriting 232 call sites to `_ = ...` across 76 files
# is a wide, no-behaviour-change sweep with a green suite the whole way — the
# exact shape that has bitten this repo before. These stay.
#
# A new `unmatched_return` in a file NOT listed here still fails the build.
[
  {"lib/buster_claw/agent/chat.ex", :unmatched_return},
  {"lib/buster_claw/agent_runner.ex", :unmatched_return},
  {"lib/buster_claw/analyzer/server.ex", :unmatched_return},
  {"lib/buster_claw/appearance.ex", :unmatched_return},
  {"lib/buster_claw/bookmarks.ex", :unmatched_return},
  {"lib/buster_claw/browser.ex", :unmatched_return},
  {"lib/buster_claw/browser/bridge.ex", :unmatched_return},
  {"lib/buster_claw/browser/capture.ex", :unmatched_return},
  {"lib/buster_claw/browser_control.ex", :unmatched_return},
  {"lib/buster_claw/browser_control/agent_mode.ex", :unmatched_return},
  {"lib/buster_claw/browser_control/cdp.ex", :unmatched_return},
  {"lib/buster_claw/browser_control/scope.ex", :unmatched_return},
  {"lib/buster_claw/browser_control/screencast.ex", :unmatched_return},
  {"lib/buster_claw/browser_control/session.ex", :unmatched_return},
  {"lib/buster_claw/cli.ex", :unmatched_return},
  {"lib/buster_claw/commands.ex", :unmatched_return},
  {"lib/buster_claw/commands/dispatch.ex", :unmatched_return},
  {"lib/buster_claw/commands/web.ex", :unmatched_return},
  {"lib/buster_claw/contacts.ex", :unmatched_return},
  {"lib/buster_claw/dispatch.ex", :unmatched_return},
  {"lib/buster_claw/dispatch_projector.ex", :unmatched_return},
  {"lib/buster_claw/dispatcher.ex", :unmatched_return},
  {"lib/buster_claw/favicons.ex", :unmatched_return},
  {"lib/buster_claw/google.ex", :unmatched_return},
  {"lib/buster_claw/google/bundled_client.ex", :unmatched_return},
  {"lib/buster_claw/google/self_test.ex", :unmatched_return},
  {"lib/buster_claw/integrations.ex", :unmatched_return},
  {"lib/buster_claw/jobs.ex", :unmatched_return},
  {"lib/buster_claw/journal.ex", :unmatched_return},
  {"lib/buster_claw/music.ex", :unmatched_return},
  {"lib/buster_claw/music/player.ex", :unmatched_return},
  {"lib/buster_claw/notifications.ex", :unmatched_return},
  {"lib/buster_claw/notifications/scheduler.ex", :unmatched_return},
  {"lib/buster_claw/notifications/sound.ex", :unmatched_return},
  {"lib/buster_claw/notifications/sound_studio.ex", :unmatched_return},
  {"lib/buster_claw/notifications/studio_mix.ex", :unmatched_return},
  {"lib/buster_claw/orchestration.ex", :unmatched_return},
  {"lib/buster_claw/orchestration/uptime.ex", :unmatched_return},
  {"lib/buster_claw/orchestrator.ex", :unmatched_return},
  {"lib/buster_claw/pages.ex", :unmatched_return},
  {"lib/buster_claw/rate_limiter.ex", :unmatched_return},
  {"lib/buster_claw/sentinel.ex", :unmatched_return},
  {"lib/buster_claw/sentinel/pending.ex", :unmatched_return},
  {"lib/buster_claw/shaders.ex", :unmatched_return},
  {"lib/buster_claw/skills.ex", :unmatched_return},
  {"lib/buster_claw/swarm.ex", :unmatched_return},
  {"lib/buster_claw/telephony.ex", :unmatched_return},
  {"lib/buster_claw/terminal_commands.ex", :unmatched_return},
  {"lib/buster_claw/terminal_workspace.ex", :unmatched_return},
  {"lib/buster_claw/workspace.ex", :unmatched_return},
  {"lib/buster_claw_web/browser_capture_hook.ex", :unmatched_return},
  {"lib/buster_claw_web/controllers/agent_view_controller.ex", :unmatched_return},
  {"lib/buster_claw_web/controllers/browser_bookmark_controller.ex", :unmatched_return},
  {"lib/buster_claw_web/controllers/browser_download_controller.ex", :unmatched_return},
  {"lib/buster_claw_web/controllers/browser_history_controller.ex", :unmatched_return},
  {"lib/buster_claw_web/controllers/google_oauth_controller.ex", :unmatched_return},
  {"lib/buster_claw_web/live/appearance_live.ex", :unmatched_return},
  {"lib/buster_claw_web/live/browse_live.ex", :unmatched_return},
  {"lib/buster_claw_web/live/cmd_list_live.ex", :unmatched_return},
  {"lib/buster_claw_web/live/dock_live.ex", :unmatched_return},
  {"lib/buster_claw_web/live/integrations_live.ex", :unmatched_return},
  {"lib/buster_claw_web/live/music_component.ex", :unmatched_return},
  {"lib/buster_claw_web/live/music_player_live.ex", :unmatched_return},
  {"lib/buster_claw_web/live/notify_live.ex", :unmatched_return},
  {"lib/buster_claw_web/live/notify_settings_live.ex", :unmatched_return},
  {"lib/buster_claw_web/live/phone_live.ex", :unmatched_return},
  {"lib/buster_claw_web/live/security_live.ex", :unmatched_return},
  {"lib/buster_claw_web/live/settings_live.ex", :unmatched_return},
  {"lib/buster_claw_web/live/setup_live.ex", :unmatched_return},
  {"lib/buster_claw_web/live/sound_board_live.ex", :unmatched_return},
  {"lib/buster_claw_web/live/sound_studio_component.ex", :unmatched_return},
  {"lib/buster_claw_web/live/split_live.ex", :unmatched_return},
  {"lib/buster_claw_web/live/status_live.ex", :unmatched_return},
  {"lib/buster_claw_web/live/terminal_live.ex", :unmatched_return},
  {"lib/buster_claw_web/live/trading_live.ex", :unmatched_return},
  {"lib/buster_claw_web/terminal_workspace_hook.ex", :unmatched_return},

  # -------------------------------------------------------------------------
  # 2. Everything that is not `unmatched_return` — 16 entries on 08-02, 12 now.
  # -------------------------------------------------------------------------
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
  # What is LEFT here has not been diagnosed, only classified. Eight
  # `:pattern_match_cov`, three `:pattern_match`, one `:no_return`. Each
  # deserves the same treatment the four above got: read the code, decide
  # whether Dialyzer is right, fix or justify. None has been shown to be a
  # defect, and none has been shown not to be.
  #
  # The `:pattern_match_cov` entries are over-covered clauses. Mostly harmless,
  # but each is a clause someone believed was reachable — read before deleting.
  # A defensive branch against untrusted input can land here when the upstream
  # guard is simply narrower than the author assumed. (The one that WAS safe to
  # delete, sound_studio.ex's `frame == 0`, is already gone: `parse_fmt/1`
  # guards `channels > 0` and `bits in [8, 16, 24, 32]`, so the product is
  # always at least 1. Removing it also cleared the `:exact_compare` warning
  # that was crashing every non-default formatter, including this file's own
  # generator.)
  {"lib/buster_claw/appearance.ex", :pattern_match_cov},
  {"lib/buster_claw/browser.ex", :pattern_match_cov},
  {"lib/buster_claw/browser.ex", :pattern_match},
  {"lib/buster_claw/browser_control.ex", :pattern_match},
  {"lib/buster_claw/cli.ex", :no_return},
  {"lib/buster_claw/google/client.ex", :pattern_match_cov},
  {"lib/buster_claw/integrations/github.ex", :pattern_match_cov},
  {"lib/buster_claw/system_browser.ex", :pattern_match_cov},
  {"lib/buster_claw/terminal_commands.ex", :pattern_match_cov},
  {"lib/buster_claw_web/controllers/browser_home_controller.ex", :pattern_match},
  {"lib/buster_claw_web/live/sound_studio_component.ex", :pattern_match_cov},
  {"lib/buster_claw_web/live/trading_live.ex", :pattern_match_cov}
]
