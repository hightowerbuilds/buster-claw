defmodule BusterClaw.Commands.Web.Checks do
  @moduledoc "Saved checks and flows — `browser_flow`, `browser_check_*`, and the step redaction they share."
  # Split out of `BusterClaw.Commands.Web` on 10-16 (CODE_QUALITY_SWEEP Phase
  # 6); that module is the facade and the catalog's door.

  alias BusterClaw.Commands.Web.Tab

  alias BusterClaw.Browser.{Bridge, Checks, FlowRunner}

  @flow_engines ~w(tab background)

  @doc """
  Run an ordered browser flow — the multi-step composition of
  navigate/wait/click/fill/extract/assert/find_elements, halting at the first
  failing step with a per-step report (`BusterClaw.Browser.FlowRunner`). The
  flow-level Sentinel event reduces fill values to lengths; the individual
  steps still fire their own events as they run.

  `engine` picks where the steps execute (Phase 6): `"tab"` (default) drives
  the user's live tab via co-presence; `"background"` runs on a pooled
  headless CDP session (`BusterClaw.BrowserControl.BackgroundFlow`) — scope
  frozen from the flow's own navigate hosts — so checks run without the
  desktop shell and without touching the tab the user is looking at.
  """
  def browser_flow(%{"steps" => steps} = args) when is_list(steps) do
    engine = Map.get(args, "engine", "tab")

    with :ok <- validate_engine(engine),
         {:ok, report} <- run_flow(engine, steps) do
      BusterClaw.Sentinel.observe(
        :outbound_send,
        "Ran a #{length(steps)}-step browser flow (#{report.status}, #{engine})",
        %{
          via: "browser_flow",
          engine: engine,
          status: report.status,
          failed_step: report.failed_step,
          steps: redact_flow_steps(steps)
        }
      )

      {:ok, Map.put(report, :engine, engine)}
    end
  end

  def browser_flow(_args), do: {:error, :missing_steps}

  defp validate_engine(engine) when engine in @flow_engines, do: :ok
  defp validate_engine(_engine), do: {:error, :unknown_engine}

  # The live-tab executor is injected here rather than defaulted inside
  # FlowRunner — this module owning the mapping is what keeps FlowRunner from
  # depending back on it (the 08-02 cycle break). Local function calls, never
  # Commands.call/3: the flow was policy-checked and audited once at the choke
  # point, and re-entering per step would re-audit and double rate-limit. The
  # primitives' own Sentinel events still fire per step.
  defp run_flow("tab", steps),
    do: FlowRunner.run(steps, exec: &tab_step/2, screenshot: &tab_failure_screenshot/0)

  defp run_flow("background", steps), do: background_flow_runner().(steps)

  defp tab_step("navigate", args), do: Tab.browser_navigate(args)
  defp tab_step("wait", args), do: Tab.browser_wait(args)
  defp tab_step("click", args), do: Tab.browser_click(args)
  defp tab_step("fill", args), do: Tab.browser_fill(args)
  defp tab_step("extract", args), do: Tab.browser_extract(args)
  defp tab_step("assert", args), do: Tab.browser_assert(args)
  defp tab_step("find_elements", args), do: Tab.browser_find_elements(args)

  # Only worth attempting when a desktop shell is attached — without one the
  # capture would just burn its timeout on an already-failed flow.
  defp tab_failure_screenshot do
    with true <- Bridge.available?(),
         {:ok, shot} <- Tab.browser_screenshot() do
      Map.take(shot, [:path, :url])
    else
      _ -> nil
    end
  end

  # Test seam: unit tests must never launch a real Chromium.
  defp background_flow_runner do
    Application.get_env(
      :buster_claw,
      :background_flow_runner,
      &BusterClaw.BrowserControl.BackgroundFlow.run/1
    )
  end

  @doc """
  Reduce a flow's `fill` steps to value *lengths* — the `browser_fill`
  precedent. Public because the dispatch choke point applies it to
  `browser_flow`'s audited args as well (`BusterClaw.Commands.audit_invoke/4`):
  Sentinel redacts by key name, and `"value"` nested inside a steps array is
  too generic a key to redact globally, so a credential typed by a flow would
  otherwise persist plaintext in `security_events`.
  """
  def redact_flow_steps(steps) when is_list(steps) do
    Enum.map(steps, fn
      %{"action" => "fill"} = step ->
        value = step |> Map.get("value", "") |> to_string()

        step
        |> Map.delete("value")
        |> Map.put("value_length", String.length(value))

      step ->
        step
    end)
  end

  @doc """
  Save a named, re-runnable site check — a flow definition stored as markdown
  in `<workspace>/checks/` with an append-only run history
  (`BusterClaw.Browser.Checks`). Overwriting keeps the history.
  """
  def browser_check_save(%{"name" => name, "steps" => steps} = args) when is_list(steps) do
    Checks.save(name, steps, Map.get(args, "description"), Map.get(args, "engine", "tab"))
  end

  def browser_check_save(_args), do: {:error, :missing_name_or_steps}

  def browser_check_list(_args \\ %{}), do: {:ok, %{checks: Checks.list()}}

  @doc """
  Run a saved check as a browser flow on its saved engine (live tab or the
  background CDP engine; an `"engine"` arg overrides for this run) and append
  the pass/fail result to its run history. The history append is best-effort
  (logged, never fatal); the flow report itself is the return value.
  """
  def browser_check_run(%{"name" => name} = args) when is_binary(name) and name != "" do
    with {:ok, %{steps: steps, engine: saved_engine}} <- Checks.load(name) do
      started = System.monotonic_time(:millisecond)

      with {:ok, report} <-
             browser_flow(%{"steps" => steps, "engine" => Map.get(args, "engine", saved_engine)}) do
        total_ms = System.monotonic_time(:millisecond) - started
        _ = Checks.record_run(name, report, total_ms)
        {:ok, Map.put(report, :check, name)}
      end
    end
  end

  def browser_check_run(_args), do: {:error, :missing_name}
end
