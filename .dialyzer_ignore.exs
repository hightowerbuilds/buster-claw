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
  # 2. Real findings — BURN THESE DOWN. Not accepted, just not yet fixed.
  # -------------------------------------------------------------------------
  #
  # Four are confirmed defects, diagnosed 08-02:
  #
  #   * cli.ex :call + :no_return — `System.trap_signal(:sigint, ...)`. OTP
  #     reserves SIGINT for the BREAK handler and will not trap it; the call
  #     raises and the `rescue _ -> :ok` below swallows it. Ctrl-C during
  #     `on-duty` has therefore NEVER stopped the shift, contrary to the promise
  #     at cli.ex:161.
  #   * cli.ex :pattern_match — the `{:failed_connect, _}` clause is dead
  #     httpc-era shape. Under Req, connection-refused falls through to the
  #     generic message, so "is `mix phx.server` running?" never renders.
  #   * finance_api_controller.ex :pattern_match — `:missing_symbol` can never
  #     match, so "Enter a ticker symbol." is unreachable.
  #   * integrations/service.ex :unknown_type — three specs reference
  #     `Integration.t/0`, which the schema never defines. Those specs check
  #     nothing.
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
  {"lib/buster_claw/cli.ex", :call},
  {"lib/buster_claw/cli.ex", :no_return},
  {"lib/buster_claw/cli.ex", :pattern_match},
  {"lib/buster_claw/google/client.ex", :pattern_match_cov},
  {"lib/buster_claw/integrations/github.ex", :pattern_match_cov},
  {"lib/buster_claw/integrations/service.ex", :unknown_type},
  {"lib/buster_claw/system_browser.ex", :pattern_match_cov},
  {"lib/buster_claw/terminal_commands.ex", :pattern_match_cov},
  {"lib/buster_claw_web/controllers/browser_home_controller.ex", :pattern_match},
  {"lib/buster_claw_web/controllers/finance_api_controller.ex", :pattern_match},
  {"lib/buster_claw_web/live/sound_studio_component.ex", :pattern_match_cov},
  {"lib/buster_claw_web/live/trading_live.ex", :pattern_match_cov}
]
