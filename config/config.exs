# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :buster_claw,
  ecto_repos: [BusterClaw.Repo],
  generators: [timestamp_type: :utc_datetime],
  workspace_root: Path.expand("../..", __DIR__),
  library_root: Path.expand("../../Library", __DIR__),
  dispatch_projector_enabled: true,
  orchestrator_enabled: true,
  dispatcher_enabled: true,
  dispatcher_tick_ms: 15_000,
  dispatcher_cooldown_ms: 10_000,
  dispatcher_batch: 5,
  # Budget governor: a per-shift run cap (reaching it stops the shift) and a
  # per-run wall-clock cap, so an unattended daemon can't burn tokens unbounded.
  dispatcher_max_runs_per_shift: 50,
  dispatcher_run_timeout_ms: 600_000,
  # Homepage chat backend (headless Claude). Per-message run wall-clock cap;
  # transcript persisted so a conversation survives reload/restart.
  agent_chat_enabled: true,
  agent_chat_timeout_ms: 600_000,
  agent_chat_persist: true,
  # Record each chat run on the Sentinel audit feed (also feeds the Activity
  # "runs" metric). Chat spawns headless Claude, so the run belongs on the trail.
  agent_chat_audit: true,
  orchestrator_tick_ms: 30_000,
  orchestrator_max_concurrent: 3,
  # Crash-loop / rate brakes for the unattended shift.
  orchestrator_max_consecutive_failures: 5,
  orchestrator_max_runs_per_hour: 120,
  orchestrator_alerts_enabled: true,
  orchestrator_morning_report: true,
  # :stub runs dispatched agents as a safe simulation (no API calls); set :real
  # to invoke the actual claude/codex CLIs during a live shift.
  agent_runner_mode: :stub,
  agent_runner_claude: ["claude", "-p"],
  agent_runner_codex: ["codex", "exec"],
  agent_run_timeout_ms: 600_000,
  agent_heartbeat_interval_ms: 30_000,
  agent_heartbeat_stale_ms: 120_000,
  # SEC EDGAR requires a descriptive User-Agent with a contact email. Set this to
  # a real contact before relying on the finance_* commands in production.
  finance_user_agent: "BusterClaw/0.1 (financial research; contact: set finance_user_agent)"

# Configure the endpoint
config :buster_claw, BusterClawWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: BusterClawWeb.ErrorHTML, json: BusterClawWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: BusterClaw.PubSub,
  live_view: [signing_salt: "fbhtxsZ3"]

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  buster_claw: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.1.12",
  buster_claw: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__)
  ]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
