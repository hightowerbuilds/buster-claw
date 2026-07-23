# :browser_engine tests launch a real Chromium-family browser — opt in with
# `mix test --include browser_engine` on a machine that has one installed.
ExUnit.start(exclude: [:browser_engine])
Ecto.Adapters.SQL.Sandbox.mode(BusterClaw.Repo, :manual)
