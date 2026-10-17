defmodule BusterClawWeb.Browser.AgentWatch do
  @moduledoc """
  The Browse tab's projection of an Agent Mode run: the hazard banner with the
  human controls (take the wheel / resume / done / stop / dismiss) and the rail
  that shows the trajectory and, at a payment handoff, the cart card with the
  confirm-purchase form.

  Extracted from `BrowseLive.render/1` on 10-16 (CODE_QUALITY_SWEEP Phase 7).
  Pure projection, as before: every `agent_*` event still lands in `BrowseLive`,
  which is where `AgentMode` is called. Nothing here adds authority.
  """
  use BusterClawWeb, :html

  alias BusterClaw.BrowserControl.AgentMode.Mode

  attr :agent_run, :map, required: true, doc: "the live run; the caller gates on nil"

  def agent_banner(assigns) do
    ~H"""
    <div
      id="agent-mode-banner"
      class="flex items-center gap-3 border-b-2 border-primary bg-base-200 px-3 py-1.5"
    >
      <span class="ic-scanlines font-display text-sm font-black uppercase tracking-tight text-primary">
        Agent Mode
      </span>
      <span class={[
        "rounded-xs px-2 py-0.5 font-mono text-[11px] font-bold uppercase tracking-wide",
        mode_class(@agent_run.mode)
      ]}>
        {mode_label(@agent_run.mode)}
      </span>
      <span class="truncate font-mono text-xs text-base-content/60">{@agent_run.run_id}</span>

      <div class="ml-auto flex items-center gap-1.5">
        <%!-- The mirror is viewport-only and payment is deliberately not
             doable through it, so the real window must always be one click
             away. This is that click. --%>
        <button
          type="button"
          phx-click="agent_show_window"
          class="rounded-xs border-2 border-base-content/30 px-2 py-0.5 font-mono text-[11px] font-bold uppercase transition hover:border-primary"
        >
          Real window
        </button>
        <button
          :if={@agent_run.mode == :agent_working}
          type="button"
          phx-click="agent_take_wheel"
          class="rounded-xs border-2 border-base-content/30 px-2 py-0.5 font-mono text-[11px] font-bold uppercase transition hover:border-primary"
        >
          Take the wheel
        </button>
        <button
          :if={@agent_run.mode == :awaiting_human}
          type="button"
          phx-click="agent_resume"
          class="rounded-xs border-2 border-base-content/30 px-2 py-0.5 font-mono text-[11px] font-bold uppercase transition hover:border-primary"
        >
          Resume agent
        </button>
        <%!-- The human's "that's finished" — the handoff was the last step.
             Without it, Stop was the only way out of a handoff, and a
             completed errand got recorded as halted. --%>
        <button
          :if={@agent_run.mode == :awaiting_human}
          type="button"
          phx-click="agent_finish"
          class="rounded-xs border-2 border-success/50 px-2 py-0.5 font-mono text-[11px] font-bold uppercase text-success transition hover:border-success"
        >
          Done
        </button>
        <button
          :if={@agent_run.mode in [:idle, :agent_working, :awaiting_human]}
          type="button"
          phx-click="agent_stop"
          class="rounded-xs border-2 border-error/50 px-2 py-0.5 font-mono text-[11px] font-bold uppercase text-error transition hover:border-error"
        >
          Stop
        </button>
        <%!-- A terminal run has no controls left, so without this the banner
             is a dead end that holds the tab in Agent Mode. --%>
        <button
          :if={Mode.terminal?(@agent_run.mode)}
          type="button"
          phx-click="agent_dismiss"
          class="rounded-xs border-2 border-base-content/30 px-2 py-0.5 font-mono text-[11px] font-bold uppercase transition hover:border-primary"
        >
          Dismiss
        </button>
      </div>
    </div>
    """
  end

  attr :agent_run, :map, required: true
  attr :agent_cart, :any, required: true, doc: "the handoff cart, or nil"
  attr :agent_steps, :list, required: true
  attr :confirmation, :string, required: true

  def agent_rail(assigns) do
    ~H"""
    <aside
      id="agent-mode-rail"
      class="flex w-80 shrink-0 flex-col gap-2 overflow-hidden border-l-2 border-base-content/20 bg-base-200 p-2"
    >
      <div
        :if={@agent_run.mode == :awaiting_human and @agent_cart}
        id="agent-handoff-card"
        class="ic-panel space-y-2 border-2 border-warning p-3"
      >
        <p class="font-display text-sm font-black uppercase tracking-tight text-warning">
          Payment handoff
        </p>
        <p class="font-mono text-xs leading-relaxed">{@agent_cart.lines}</p>
        <p class="font-mono text-sm font-bold">Total {@agent_cart.total}</p>
        <p class="font-mono text-[11px] text-base-content/60">
          Pay in the agent's browser window, then confirm here to capture
          the confirmation page and finish this run.
        </p>

        <form
          id="agent-confirm-purchase-form"
          phx-submit="agent_confirm_purchase"
          class="space-y-2"
        >
          <input
            type="text"
            name="confirmation"
            value={@confirmation}
            placeholder="Order id / confirmation (optional)"
            autocomplete="off"
            class="w-full rounded-xs border-2 border-base-content/25 bg-base-100 px-2 py-1 font-mono text-xs"
          />
          <button
            type="submit"
            class="w-full rounded-xs bg-warning px-2 py-1.5 font-mono text-xs font-bold uppercase text-warning-content transition hover:opacity-85"
          >
            I've paid — finish handoff
          </button>
        </form>
      </div>

      <p class="px-1 font-mono text-[11px] font-bold uppercase tracking-wide text-base-content/60">
        Trajectory · {length(@agent_steps)} steps
      </p>
      <ol class="min-h-0 flex-1 space-y-1 overflow-y-auto">
        <li :if={@agent_steps == []} class="px-1 font-mono text-xs text-base-content/50">
          No steps yet.
        </li>
        <li
          :for={step <- @agent_steps}
          class="border-b border-base-content/10 px-1 py-1 font-mono text-[11px] leading-snug"
        >
          <span class="font-bold uppercase text-base-content/80">{step.type}</span>
          <span class={["ml-1", outcome_class(step.outcome)]}>{step.summary}</span>
        </li>
      </ol>
    </aside>
    """
  end

  defp mode_label(mode), do: mode |> to_string() |> String.replace("_", " ") |> String.upcase()

  defp mode_class(:agent_working), do: "bg-primary text-primary-content"
  defp mode_class(:awaiting_human), do: "bg-warning text-warning-content"
  defp mode_class(:done), do: "bg-success text-success-content"
  defp mode_class(_halted_stopped), do: "bg-error text-error-content"

  defp outcome_class(:ok), do: "text-base-content/70"
  defp outcome_class(:awaiting_human), do: "text-warning"
  defp outcome_class(_halted_error), do: "text-error"
end
