# :browser_engine tests launch a real Chromium-family browser — opt in with
# `mix test --include browser_engine` on a machine that has one installed.
#
# :macos tests need tools that ship only with macOS (`/usr/bin/afinfo` behind
# `SoundStudio.probe/1`, `plutil` behind the Info.plist lint). They are the
# shipping platform, so they run here and are skipped on a Linux runner rather
# than failing there forever.
#
# **The point is that a red gate stops being read.** CI failed on every run from
# 09-03 to 09-19 on exactly these tests, accepted as "macOS-only, by choice" —
# and a real Dialyzer break then sat inside that redness for a week before anyone
# noticed, because the run was already red. Skipping is not the same as excusing:
# `mix test` on a Mac still runs every one of them, and `--include macos` forces
# them anywhere.
macos_only = if :os.type() == {:unix, :darwin}, do: [], else: [:macos]

ExUnit.start(exclude: [:browser_engine] ++ macos_only)
Ecto.Adapters.SQL.Sandbox.mode(BusterClaw.Repo, :manual)
