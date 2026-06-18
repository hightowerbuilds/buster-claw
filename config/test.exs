import Config

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :buster_claw, BusterClaw.Repo,
  database: Path.expand("../buster_claw_test.db", __DIR__),
  pool_size: 5,
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
config :buster_claw, :orchestrator_enabled, false
# The unattended work pump is off in tests; the Dispatcher suite starts its own
# instance with a stub runner and drives it via tick_now/1.
config :buster_claw, :dispatcher_enabled, false
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
