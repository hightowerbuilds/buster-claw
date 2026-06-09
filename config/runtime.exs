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

# Resolve the workspace root for every environment so the linked workspace is
# honored even outside the packaged app:
#   1. BUSTER_CLAW_WORKSPACE_ROOT env var (set by the Tauri shell in release), else
#   2. the persisted choice in the Buster Claw data dir (so `mix phx.server` dev
#      uses the workspace you assigned in-app), else
#   3. the compile-time config default.
# The library lives at <workspace>/library, with sources/analysis/memory siblings.
# Test is never bound to the persisted/on-disk workspace (it uses config defaults
# and per-test overrides).
workspace_root_env =
  if config_env() == :test do
    nil
  else
    with nil <- System.get_env("BUSTER_CLAW_WORKSPACE_ROOT") do
      data_dir =
        case :os.type() do
          {:unix, :darwin} ->
            Path.expand("~/Library/Application Support/BusterClaw")

          {:unix, _} ->
            Path.join(
              System.get_env("XDG_DATA_HOME") || Path.expand("~/.local/share"),
              "BusterClaw"
            )

          _ ->
            Path.expand("~/.buster_claw")
        end

      case File.read(Path.join(data_dir, "workspace_root")) do
        {:ok, contents} ->
          trimmed = String.trim(contents)
          if trimmed == "", do: nil, else: trimmed

        _ ->
          nil
      end
    end
  end

config :buster_claw,
  workspace_root: workspace_root_env || Application.get_env(:buster_claw, :workspace_root),
  library_root:
    System.get_env("BUSTER_CLAW_LIBRARY_ROOT") ||
      if(workspace_root_env, do: Path.join(workspace_root_env, "library")) ||
      Application.get_env(:buster_claw, :library_root)

browser_sidecar_enabled =
  case System.get_env("BUSTER_CLAW_BROWSER_SIDECAR") do
    nil -> config_env() == :dev
    value -> value in ["1", "true", "TRUE", "yes", "YES"]
  end

config :buster_claw,
  browser_sidecar_enabled: browser_sidecar_enabled,
  browser_sidecar_command: System.get_env("BUSTER_CLAW_BROWSER_SIDECAR_COMMAND", "node")

if browser_sidecar_url = System.get_env("BUSTER_CLAW_BROWSER_SIDECAR_URL") do
  config :buster_claw, :browser_sidecar_url, browser_sidecar_url
end

if config_env() == :prod do
  cli_eval? = System.get_env("BUSTER_CLAW_CLI_EVAL") in ["1", "true", "TRUE", "yes", "YES"]

  database_path =
    System.get_env("DATABASE_PATH") ||
      if cli_eval? do
        Path.join(System.tmp_dir!(), "buster_claw_cli_eval.db")
      else
        raise """
        environment variable DATABASE_PATH is missing.
        The Tauri desktop shell sets this automatically;
        when running the release manually, point it at a local SQLite file.
        """
      end

  config :buster_claw, BusterClaw.Repo,
    database: database_path,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "5")

  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      if cli_eval? do
        String.duplicate("a", 64)
      else
        raise """
        environment variable SECRET_KEY_BASE is missing.
        The Tauri desktop shell generates and persists this on first launch.
        Generate one manually with: mix phx.gen.secret
        """
      end

  port = String.to_integer(System.get_env("PORT") || "4000")

  config :buster_claw, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  config :buster_claw, BusterClawWeb.Endpoint,
    url: [host: "127.0.0.1", port: port, scheme: "http"],
    http: [ip: {127, 0, 0, 1}, port: port],
    check_origin: ["//127.0.0.1", "//localhost"],
    secret_key_base: secret_key_base
end
