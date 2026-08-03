defmodule BusterClaw.RuntimeConfig do
  @moduledoc """
  Runtime facts the desktop shell decides — the master key and the port this app
  actually bound to — read **without touching the web layer**.

  ## Why this module exists

  `Vault`, `Google.Vault`, `Recovery` and `Dispatcher` used to read these out of
  the endpoint's own config: `Application.get_env(:buster_claw,
  BusterClawWeb.Endpoint, [])`. That is only a config KEY, not a call — but the
  alias is still a module reference, so `mix xref` recorded an edge from core
  into `BusterClawWeb.Endpoint`, and through it the router, the layouts and
  every LiveView.

  It was the return path that closed the codebase's 110-file compile-connected
  cycle: `Integration --compile--> Encrypted --> Vault --> Endpoint --> web -->
  … --> Integrations --> Integration`. Measured 2026-08-02 — removing just these
  reads took the compile-connected cycle count from 1 to 0 and the largest cycle
  from 110 nodes to 98 export-only ones. Everything in that cycle recompiled
  whenever anything it depended on changed.

  So: core reads its own keys. `config/runtime.exs` sets them from the same
  values it hands the endpoint, and dev/test set them alongside theirs. The
  endpoint keeps its config; core just stops reaching through it.

  `SECRET_KEY_BASE` in the environment always wins — that is what the packaged
  shell injects, sourced from the macOS Keychain.
  """

  @default_port 4000

  @doc """
  The master key, or `nil` when unset.

  `nil` is a real answer here: `Recovery` shows the user a "no key yet" state
  rather than failing.
  """
  def secret_key_base do
    System.get_env("SECRET_KEY_BASE") ||
      Application.get_env(:buster_claw, :secret_key_base)
  end

  @doc """
  The master key, raising when unset.

  `context` names the caller in the message, because "missing secret_key_base"
  alone does not tell you which vault refused to open.
  """
  def secret_key_base!(context) when is_binary(context) do
    secret_key_base() || raise "missing secret_key_base for #{context}"
  end

  @doc """
  The port this app is actually serving on — random in the packaged release,
  which is why it cannot be assumed to be #{@default_port}.
  """
  def local_port do
    Application.get_env(:buster_claw, :local_port, @default_port)
  end

  @doc "Loopback base URL for this app's own HTTP surface."
  def local_url, do: "http://127.0.0.1:#{local_port()}"
end
