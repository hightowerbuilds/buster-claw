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

# In test we don't send emails
config :buster_claw, BusterClaw.Mailer, adapter: Swoosh.Adapters.Test

# Disable swoosh api client as it is only required for production adapters
config :swoosh, :api_client, false

config :buster_claw, :provider_req_options, plug: {Req.Test, BusterClaw.ProviderHTTP}
config :buster_claw, :search_req_options, plug: {Req.Test, BusterClaw.SearchHTTP}
config :buster_claw, :browser_req_options, plug: {Req.Test, BusterClaw.BrowserHTTP}

config :buster_claw, :api_token, "test-token-loopback-only"
config :buster_claw, :mcp_api_token, "test-mcp-token-safe-tier-only"
config :buster_claw, :scheduler_enabled, false
config :buster_claw, :orchestrator_enabled, false

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
