import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/buster_claw start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :buster_claw, BusterClawWeb.Endpoint, server: true
end

config :buster_claw, BusterClawWeb.Endpoint,
  http: [port: String.to_integer(System.get_env("PORT", "4000"))]

config :buster_claw,
  library_root:
    System.get_env("BUSTER_CLAW_LIBRARY_ROOT") ||
      Application.get_env(:buster_claw, :library_root)

if config_env() == :prod do
  database_path =
    System.get_env("DATABASE_PATH") ||
      raise """
      environment variable DATABASE_PATH is missing.
      The Tauri desktop shell sets this automatically;
      when running the release manually, point it at a local SQLite file.
      """

  config :buster_claw, BusterClaw.Repo,
    database: database_path,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "5")

  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      The Tauri desktop shell generates and persists this on first launch.
      Generate one manually with: mix phx.gen.secret
      """

  port = String.to_integer(System.get_env("PORT") || "4000")

  config :buster_claw, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  config :buster_claw, BusterClawWeb.Endpoint,
    url: [host: "127.0.0.1", port: port, scheme: "http"],
    http: [ip: {127, 0, 0, 1}, port: port],
    check_origin: ["//127.0.0.1", "//localhost"],
    secret_key_base: secret_key_base
end
