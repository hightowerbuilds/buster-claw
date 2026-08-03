import Config

# Configure your database
#
# `MIX_TEST_PARTITION` gives each run its own database FILE. Unset — the normal
# case, and CI — the path is exactly what it has always been, so this is inert.
#
# It is not really about partitioning here. The single-connection design below
# only serializes writers *within one BEAM*; two `mix test` processes in the same
# checkout open two connections to the same file and defeat it entirely, and the
# symptom is a flood of "Database busy" in tests that have nothing to do with
# each other or with whatever is being changed. That is not hypothetical: this
# repo is routinely worked by more than one agent session at once, and a suite
# run against a contended file reports failure counts that swing by 100 between
# runs of identical code — a signal worth nothing at all. Set the variable to
# anything (`MIX_TEST_PARTITION=b mix test`) to get an isolated lane.
config :buster_claw, BusterClaw.Repo,
  database: Path.expand("../buster_claw_test#{System.get_env("MIX_TEST_PARTITION")}.db", __DIR__),
  # SQLite is single-writer at the file level, so multiple pooled connections only
  # race each other: a read-then-write transaction (common via *_seeded/0 helpers)
  # upgrades from a shared to a write lock and, if another connection holds it, gets
  # an immediate SQLITE_BUSY that `busy_timeout` cannot wait out. One connection
  # makes the sandbox serialize writers, so that collision can't happen. Async tests
  # still run — they just queue on DB checkout rather than holding rival connections.
  pool_size: 1,
  busy_timeout: 5_000,
  # With pool_size: 1, queuing on checkout is BY DESIGN (see above) — but
  # DBConnection's default load-shedding (queue_target: 50ms, queue_interval:
  # 1000ms) drops a queued checkout after ~200ms, so under bursty async load —
  # especially while a crash-path test's disconnect/reconnect briefly frees the
  # lone connection — a bystander test fails in `setup_sandbox/1` with a
  # :queue_timeout before it ever runs. Widen the window so contended checkouts
  # WAIT (up to the ownership timeout) instead of being shed. This makes the
  # single-connection design behave as its own comment promises.
  queue_target: 5_000,
  queue_interval: 5_000,
  pool: Ecto.Adapters.SQL.Sandbox

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :buster_claw, BusterClawWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "4b9dJlwt909xaIFH1I1ZBTm3Ge4dBRtl7vhsFySqmKhhmXQt1RElz4HjimLpy/95",
  server: false

# Same values under our own keys, for BusterClaw.RuntimeConfig — core modules
# read these rather than reaching through the endpoint's config.
config :buster_claw,
  secret_key_base: "4b9dJlwt909xaIFH1I1ZBTm3Ge4dBRtl7vhsFySqmKhhmXQt1RElz4HjimLpy/95",
  local_port: 4002

config :buster_claw, :search_req_options, plug: {Req.Test, BusterClaw.SearchHTTP}
config :buster_claw, :browser_req_options, plug: {Req.Test, BusterClaw.BrowserHTTP}

config :buster_claw, :favicons,
  req_options: [plug: {Req.Test, BusterClaw.FaviconHTTP}],
  cache_dir: Path.join(System.tmp_dir!(), "buster_claw_test_favicons")

config :buster_claw, :api_token, "test-token-loopback-only"
config :buster_claw, :mcp_api_token, "test-mcp-token-safe-tier-only"
config :buster_claw, :agent_api_token, "test-agent-token-untrusted-provenance"
config :buster_claw, :orchestrator_enabled, false
# The unattended work pump is off in tests; the Dispatcher suite starts its own
# instance with a stub runner and drives it via tick_now/1.
config :buster_claw, :dispatcher_enabled, false
# Boot chime off: its once-per-BEAM :persistent_term flag would make the
# first root-layout test of every run special. The chime path itself is
# tested explicitly with the flag reset and this config overridden.
config :buster_claw, boot_chime_enabled: false
# The self-improvement scanner is off in tests; the Analyzer suite drives scan/1
# directly with seeded audit events.
config :buster_claw, :analyzer_enabled, false
# The BusterPhone relay drain is off in tests; the Drain suite starts its own
# instance with Req.Test stubs and drives it via drain/1 directly.
config :buster_claw, :telephony_drain_enabled, false
# The Notify scheduler is off in tests; the Scheduler suite starts its own
# instance and drives it via tick_now/1, and the context suite calls fire_due/1.
config :buster_claw, :notifications_scheduler_enabled, false
# The portfolio recorder is off in tests: an autostarting instance would fire a
# REAL stage-1 agent run on boot. The Recorder suite starts its own with a
# stubbed fetcher and drives it via tick_now/1.
config :buster_claw, :portfolio_recorder_enabled, false
config :buster_claw, :telephony_relay_url, "http://relay.test"
config :buster_claw, :telephony_relay_key, "test-service-role-key"
# Call-rate limiting is off in tests so command-heavy suites aren't throttled; the
# RateLimiter suite flips it on with a low limit to exercise enforcement.
config :buster_claw, :rate_limit_enabled, false
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

# No desktop shell in tests: never let Browser.fetch wait on the live-render
# bridge. The fallback path is covered explicitly in browser_test.exs with the
# flag flipped on and a manually fulfilled Bridge request.
config :buster_claw, :browser_live_render_enabled, false

# Likewise never launch a real Chromium from a unit test: the CDP-engine
# render fallback is off by default here; tests that exercise it inject an
# :engine_render fun instead.
config :buster_claw, :browser_engine_render_enabled, false

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

# Post-connect Google self-test: disabled by default in tests (the async task
# would race the Ecto sandbox and the Req.Test ownership); tests that exercise
# it set :sync explicitly.
config :buster_claw, :google_self_test, :disabled
