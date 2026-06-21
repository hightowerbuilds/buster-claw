defmodule BusterClaw.Analyzer.Server do
  @moduledoc """
  Periodic driver for `BusterClaw.Analyzer` (Phase 3 self-improvement). On a slow
  interval it scans recent command history for repeated sequences and files skill
  *suggestions* — it never enables anything, so this is safe to run unattended.

  Modeled on `BusterClaw.WalletPoller`: self-rescheduling tick, crash-safe body,
  `tick_now/1` for tests/manual nudge. Off in tests (`:analyzer_enabled`); the
  Analyzer suite drives `BusterClaw.Analyzer.scan/1` directly.
  """
  use GenServer

  require Logger

  alias BusterClaw.Analyzer

  # Hourly by default — repeated-sequence patterns emerge over many runs, not
  # within one tick, so there's no value scanning more often.
  @default_interval_ms 3_600_000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "Force an immediate scan (tests / manual nudge)."
  def tick_now(server \\ __MODULE__), do: send(server, :tick)

  @impl true
  def init(opts) do
    state = %{
      interval_ms:
        Keyword.get(opts, :interval_ms, configured(:analyzer_tick_ms, @default_interval_ms)),
      scan_opts: Keyword.get(opts, :scan_opts, [])
    }

    if Keyword.get(opts, :autostart, true), do: send(self(), :tick)
    {:ok, state}
  end

  @impl true
  def handle_info(:tick, state) do
    safe_scan(state.scan_opts)
    Process.send_after(self(), :tick, state.interval_ms)
    {:noreply, state}
  end

  defp safe_scan(opts) do
    result = Analyzer.scan(opts)

    if result.filed != [],
      do: Logger.info("Analyzer filed #{length(result.filed)} skill suggestion(s)")

    result
  rescue
    error -> Logger.warning("Analyzer scan failed: #{inspect(error)}")
  end

  defp configured(key, default), do: Application.get_env(:buster_claw, key, default)
end
