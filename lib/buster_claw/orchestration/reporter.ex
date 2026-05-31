defmodule BusterClaw.Orchestration.Reporter do
  @moduledoc """
  Passive listener that turns shift lifecycle events into operator-facing
  signals: a **shift-stopped alert** (sent immediately via the Delivery layer)
  and a **morning report** (a markdown summary written to the workspace, plus an
  optional completion alert) when a shift finishes its window.

  It subscribes to the `"orchestration"` PubSub topic and reacts to
  `:shift_stopped` / `:shift_completed`. Everything outbound is best-effort and
  wrapped in `try/rescue` — a Delivery or filesystem failure must never crash the
  reporter or wedge the shift. Alerts are guarded behind
  `:orchestrator_alerts_enabled` (default on) and the morning report behind
  `:orchestrator_morning_report` (default on).
  """

  use GenServer

  require Logger

  alias BusterClaw.Delivery
  alias BusterClaw.Library.Artifact
  alias BusterClaw.Orchestration
  alias BusterClaw.Sentinel

  # ---------------------------------------------------------------------------
  # Lifecycle
  # ---------------------------------------------------------------------------

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    Orchestration.subscribe()
    {:ok, %{}}
  end

  # ---------------------------------------------------------------------------
  # Events
  # ---------------------------------------------------------------------------

  @impl true
  def handle_info({:orchestration, :shift_stopped}, state) do
    if alerts_enabled?(), do: alert_shift_stopped(Orchestration.latest_shift())
    {:noreply, state}
  end

  def handle_info({:orchestration, :shift_completed}, state) do
    shift = Orchestration.latest_shift()

    if morning_report_enabled?(), do: write_morning_report(shift)
    if alerts_enabled?(), do: alert_shift_completed(shift)

    {:noreply, state}
  end

  def handle_info(_other, state), do: {:noreply, state}

  # ---------------------------------------------------------------------------
  # Shift-stopped alert
  # ---------------------------------------------------------------------------

  defp alert_shift_stopped(nil), do: :ok

  defp alert_shift_stopped(shift) do
    reason = shift.stopped_reason || "unknown"

    body =
      "Shift stopped (#{reason}). " <>
        "Dispatched #{shift.dispatched_count}, done #{shift.done_count}, failed #{shift.failed_count}."

    try do
      Delivery.dispatch_all(%{title: "Shift stopped", body: body})

      Sentinel.observe(:outbound_send, "Shift-stopped alert", %{
        reason: reason,
        dispatched: shift.dispatched_count,
        done: shift.done_count,
        failed: shift.failed_count
      })
    rescue
      error ->
        Logger.warning("Reporter shift-stopped alert failed: #{inspect(error)}")
        :error
    end
  end

  # ---------------------------------------------------------------------------
  # Shift-completed: morning report + completion alert
  # ---------------------------------------------------------------------------

  defp alert_shift_completed(nil), do: :ok

  defp alert_shift_completed(shift) do
    body =
      "Shift complete. Ran #{duration_label(shift)}. " <>
        "Dispatched #{shift.dispatched_count}, done #{shift.done_count}, failed #{shift.failed_count}."

    try do
      Delivery.dispatch_all(%{title: "Shift complete", body: body})

      Sentinel.observe(:outbound_send, "Shift-completed alert", %{
        dispatched: shift.dispatched_count,
        done: shift.done_count,
        failed: shift.failed_count
      })
    rescue
      error ->
        Logger.warning("Reporter shift-completed alert failed: #{inspect(error)}")
        :error
    end
  end

  defp write_morning_report(nil), do: :ok

  defp write_morning_report(shift) do
    try do
      runs = Orchestration.list_recent_runs(20)
      tasks = Orchestration.list_tasks()

      markdown = render_report(shift, runs, tasks)
      path = report_path(shift)

      :ok = File.mkdir_p(Path.dirname(path))
      File.write(path, markdown)
      {:ok, path}
    rescue
      error ->
        Logger.warning("Reporter morning report failed: #{inspect(error)}")
        :error
    end
  end

  # ---------------------------------------------------------------------------
  # Rendering
  # ---------------------------------------------------------------------------

  defp report_path(shift) do
    date = report_date(shift)
    Path.join([Artifact.workspace_root(), "shift", Date.to_iso8601(date), "morning-report.md"])
  end

  defp report_date(%{ends_at: %DateTime{} = ends_at}), do: DateTime.to_date(ends_at)
  defp report_date(%{started_at: %DateTime{} = started_at}), do: DateTime.to_date(started_at)
  defp report_date(_shift), do: Date.utc_today()

  defp render_report(shift, runs, tasks) do
    """
    # Morning Report — #{Date.to_iso8601(report_date(shift))}

    - **Status:** #{shift.status}#{reason_suffix(shift)}
    - **Window:** #{format_dt(shift.started_at)} → #{format_dt(shift.ends_at)} (#{duration_label(shift)})
    - **Dispatched:** #{shift.dispatched_count}
    - **Done:** #{shift.done_count}
    - **Failed:** #{shift.failed_count}

    ## Recent runs

    #{render_runs(runs)}

    ## Notable tasks

    #{render_tasks(tasks)}
    """
  end

  defp reason_suffix(%{stopped_reason: reason}) when is_binary(reason) and reason != "",
    do: " (#{reason})"

  defp reason_suffix(_shift), do: ""

  defp render_runs([]), do: "_No runs recorded._"

  defp render_runs(runs) do
    runs
    |> Enum.map_join("\n", fn run ->
      "- #{run.engine} — **#{run.status}**" <>
        exit_suffix(run) <>
        started_suffix(run) <>
        error_suffix(run)
    end)
  end

  defp exit_suffix(%{exit_code: code}) when is_integer(code), do: " (exit #{code})"
  defp exit_suffix(_run), do: ""

  defp started_suffix(%{started_at: %DateTime{} = at}), do: " — started #{format_dt(at)}"
  defp started_suffix(_run), do: ""

  defp error_suffix(%{error: error}) when is_binary(error) and error != "",
    do: " — #{String.slice(error, 0, 200)}"

  defp error_suffix(_run), do: ""

  defp render_tasks([]), do: "_No tasks._"

  defp render_tasks(tasks) do
    tasks
    |> Enum.filter(&(&1.state in ["failed", "done", "running", "claimed"]))
    |> case do
      [] -> "_No notable tasks._"
      notable -> Enum.map_join(notable, "\n", &"- #{&1.name} — **#{&1.state}** (#{&1.type})")
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp duration_label(%{started_at: %DateTime{} = started, ends_at: %DateTime{} = ends}) do
    seconds = max(DateTime.diff(ends, started, :second), 0)
    hours = div(seconds, 3600)
    minutes = div(rem(seconds, 3600), 60)
    "#{hours}h #{minutes}m"
  end

  defp duration_label(_shift), do: "unknown duration"

  defp format_dt(%DateTime{} = dt), do: dt |> DateTime.truncate(:second) |> DateTime.to_string()
  defp format_dt(_other), do: "—"

  defp alerts_enabled?, do: Application.get_env(:buster_claw, :orchestrator_alerts_enabled, true)

  defp morning_report_enabled?,
    do: Application.get_env(:buster_claw, :orchestrator_morning_report, true)
end
