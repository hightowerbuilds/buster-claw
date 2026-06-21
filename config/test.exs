import Config

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :buster_claw, BusterClaw.Repo,
  database: Path.expand("../buster_claw_test.db", __DIR__),
  # SQLite is single-writer at the file level, so multiple pooled connections only
  # race each other: a read-then-write transaction (common via *_seeded/0 helpers)
  # upgrades from a shared to a write lock and, if another connection holds it, gets
  # an immediate SQLITE_BUSY that `busy_timeout` cannot wait out. One connection
  # makes the sandbox serialize writers, so that collision can't happen. Async tests
  # still run — they just queue on DB checkout rather than holding rival connections.
  pool_size: 1,
  busy_timeout: 5_000,
  pool: Ecto.Adapters.SQL.Sandbox

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :buster_claw, BusterClawWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "4b9dJlwt909xaIFH1I1ZBTm3Ge4dBRtl7vhsFySqmKhhmXQt1RElz4HjimLpy/95",
  server: false

config :buster_claw, :search_req_options, plug: {Req.Test, BusterClaw.SearchHTTP}
config :buster_claw, :browser_req_options, plug: {Req.Test, BusterClaw.BrowserHTTP}

config :buster_claw, :api_token, "test-token-loopback-only"
config :buster_claw, :mcp_api_token, "test-mcp-token-safe-tier-only"
config :buster_claw, :agent_api_token, "test-agent-token-untrusted-provenance"
config :buster_claw, :orchestrator_enabled, false
# The unattended work pump is off in tests; the Dispatcher suite starts its own
# instance with a stub runner and drives it via tick_now/1.
config :buster_claw, :dispatcher_enabled, false
# The wallet feed poller is off in tests; the WalletPoller suite starts its own
# instance with injected fetchers and drives it via tick_now/1.
config :buster_claw, :wallet_poller_enabled, false
# Call-rate limiting is off in tests so command-heavy suites aren't throttled; the
# RateLimiter suite flips it on with a low limit to exercise enforcement.
config :buster_claw, :rate_limit_enabled, false
# The homepage chat backend is off in tests; the Chat suite starts its own
# instance with an injected spawner so no real `claude` is launched.
config :buster_claw, :agent_chat_enabled, false
# Persistence is off by default in tests so the Chat suite stays DB-free; the
# transcript suite drives `Transcript` directly and the persistence test starts a
# Chat with `persist: true` under the SQL sandbox.
config :buster_claw, :agent_chat_persist, false
# Chat run auditing is off in tests (it writes to Sentinel/DB); the persistence
# suite flips it on under the sandbox to assert the audit event is written.
config :buster_claw, :agent_chat_audit, false
# The projector writes into the workspace on every dispatch event; off by default
# in tests so unrelated dispatch tests don't write files. Projector tests start it
# explicitly against a tmp workspace.
config :buster_claw, :dispatch_projector_enabled, false

# First-run onboarding gate off by default so the LiveView suite isn't forced
# through /setup. The first-run tests flip it on explicitly.
config :buster_claw, :onboarding_gate, false

# Skip live DNS resolution in the SSRF guard during tests; literal-IP and
# hostname checks still run. URLGuard's resolution path is covered directly in
# its unit test.
config :buster_claw, :ssrf_resolve_dns, false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true
