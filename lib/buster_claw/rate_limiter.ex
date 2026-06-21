defmodule BusterClaw.RateLimiter do
  @moduledoc """
  Per-caller / per-command call-rate limiting (Phase 1C).

  Closes the threat-model gap where a non-gated command (e.g. `gmail_search`) can
  be spammed in a loop: policy authorizes *what* a caller may run, this bounds
  *how often*. A fixed-window counter keyed by `{caller, command, window}` lives in
  a public ETS table; `check/2` does an atomic `:ets.update_counter`, so it stays
  off the GenServer's mailbox and adds ~no latency to the dispatch path. The
  GenServer owns the table and sweeps stale windows on an interval.

  Limits are config-driven and apply to every caller (an autonomous headless run
  is `:trusted`, so exempting trusted would miss the very runaway loops we guard
  against):

  - `:rate_limit_enabled` — master switch (default `true`; `false` in test).
  - `:rate_limit_window_ms` — window length (default 60_000).
  - `:rate_limit_default` — max calls per window per `{caller, command}` (default 120).
  - `:rate_limit_overrides` — `%{command_name => max}` for specific commands.

  Disabled, or before the table exists, `check/2` returns `:ok` (fail-open: rate
  limiting must never take the surface down).
  """
  use GenServer

  require Logger

  @table :buster_claw_rate_limits

  # --- public API --------------------------------------------------------

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  Count one call for `{caller, command}` in the current window. Returns `:ok` while
  under the limit, `{:error, :rate_limited}` once it is exceeded.
  """
  @spec check(atom(), String.t()) :: :ok | {:error, :rate_limited}
  def check(caller, command) do
    if enabled?() and ready?() do
      bucket = div(System.system_time(:millisecond), window_ms())
      key = {caller, command, bucket}
      count = :ets.update_counter(@table, key, {2, 1}, {key, 0})

      if count > limit_for(command), do: {:error, :rate_limited}, else: :ok
    else
      :ok
    end
  end

  @doc "Drop all counters (test/operator reset)."
  def reset do
    if ready?(), do: :ets.delete_all_objects(@table)
    :ok
  end

  # --- config ------------------------------------------------------------

  defp enabled?, do: Application.get_env(:buster_claw, :rate_limit_enabled, true)
  defp window_ms, do: Application.get_env(:buster_claw, :rate_limit_window_ms, 60_000)
  defp default_limit, do: Application.get_env(:buster_claw, :rate_limit_default, 120)

  defp limit_for(command) do
    Application.get_env(:buster_claw, :rate_limit_overrides, %{})
    |> Map.get(command, default_limit())
  end

  defp ready?, do: :ets.whereis(@table) != :undefined

  # --- GenServer ---------------------------------------------------------

  @impl true
  def init(_opts) do
    :ets.new(@table, [
      :named_table,
      :public,
      :set,
      read_concurrency: true,
      write_concurrency: true
    ])

    schedule_sweep()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:sweep, state) do
    sweep()
    schedule_sweep()
    {:noreply, state}
  end

  # Drop windows older than the current one (counts are only read within their own
  # window, so anything before `current - 1` is dead weight). Best-effort.
  defp sweep do
    current = div(System.system_time(:millisecond), window_ms())
    threshold = current - 1
    :ets.select_delete(@table, [{{{:_, :_, :"$1"}, :_}, [{:<, :"$1", threshold}], [true]}])
  rescue
    error -> Logger.warning("RateLimiter sweep failed: #{inspect(error)}")
  end

  defp schedule_sweep, do: Process.send_after(self(), :sweep, window_ms())
end
