defmodule BusterClaw.BrowserControl.SessionSupervisor do
  @moduledoc """
  DynamicSupervisor for `BusterClaw.BrowserControl.Session` processes
  (BROWSER_ENGINE_ROADMAP Phase 2).

  Crash-isolated, one-for-one: a session that dies — engine crash, idle reap, a
  wedged page — takes only its own browser process with it. Sessions are
  `restart: :temporary`; the `Pool` decides whether a fresh one is wanted, never
  the supervisor (a headless read that failed should not silently respawn).
  """
  use DynamicSupervisor

  alias BusterClaw.BrowserControl.Session

  def start_link(opts), do: DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts), do: DynamicSupervisor.init(strategy: :one_for_one)

  @doc "Start one supervised session; returns `{:ok, pid}` or an error."
  def start_session(opts), do: DynamicSupervisor.start_child(__MODULE__, {Session, opts})
end
