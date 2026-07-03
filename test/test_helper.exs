# :browserbase_live tags hit the real Browserbase API and spend browser-minutes.
# Excluded by default so CI never spends money; opt in with
# `mix test --include browserbase_live` (needs BROWSERBASE_API_KEY in the env).
ExUnit.start(exclude: [:browserbase_live])
Ecto.Adapters.SQL.Sandbox.mode(BusterClaw.Repo, :manual)
